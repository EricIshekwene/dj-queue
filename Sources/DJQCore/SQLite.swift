import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
  public let code: Int32
  public let message: String
  public let sql: String?
  public var description: String { "SQLite \(code): \(message)\(sql.map { " [\($0)]" } ?? "")" }
}

public enum SQLValue: Sendable, Hashable {
  case null, int(Int64), double(Double), text(String)
}

public protocol SQLBindable { var sqlValue: SQLValue { get } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
  public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

public struct Row: Sendable {
  public let values: [String: SQLValue]

  public func string(_ k: String) -> String? {
    switch values[k] {
    case .text(let s): s
    case .int(let i): String(i)
    case .double(let d): String(d)
    default: nil
    }
  }
  public func int(_ k: String) -> Int? {
    switch values[k] {
    case .int(let i): Int(i)
    case .double(let d): Int(d)
    case .text(let s): Int(s)
    default: nil
    }
  }
  public func int64(_ k: String) -> Int64? { int(k).map(Int64.init) }
  public func double(_ k: String) -> Double? {
    switch values[k] {
    case .double(let d): d
    case .int(let i): Double(i)
    case .text(let s): Double(s)
    default: nil
    }
  }
  public func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
  public func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
  public func json<T: Decodable>(_ k: String, as: T.Type = T.self) -> T? {
    guard let s = string(k), let d = s.data(using: .utf8) else { return nil }
    return try? JSONCoding.decoder.decode(T.self, from: d)
  }
}

public enum JSONCoding {
  public static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .secondsSince1970
    return e
  }()
  public static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    return d
  }()
  /// A list of absolute paths as stored JSON, with its slashes as written ("/a/b", never "\/a\/b"). A dev copy
  /// of the database has every stored path pointed at the dev root by plain text replacement (`scripts/live-checks.sh`),
  /// and an escaped path would slip through it and still name the real file.
  public static func pathList(_ paths: [String]) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? e.encode(paths)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
  }

  /// Decodes `data` over the encoded `defaults`, so keys missing from older stored JSON keep their defaults
  /// instead of failing the whole decode (top-level keys; nested values are replaced whole).
  public static func decodeLenient<T: Codable>(_ data: Data, defaults: T) throws -> T {
    let defObj = (try JSONSerialization.jsonObject(with: encoder.encode(defaults))) as? [String: Any] ?? [:]
    guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Stored JSON is not an object"))
    }
    let merged = defObj.merging(stored) { _, s in s }
    return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
  }

  public static func string<T: Encodable>(_ v: T) -> String {
    String(data: (try? encoder.encode(v)) ?? Data("null".utf8), encoding: .utf8)!
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe SQLite connection (serialised by a lock; WAL so the app and CLI can share the file).
public final class SQLite: @unchecked Sendable {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()
  private var txDepth = 0
  public let path: String

  public init(path: String) throws {
    self.path = path
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(path, &db, flags, nil)
    guard rc == SQLITE_OK else {
      throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: nil)
    }
    sqlite3_busy_timeout(db, 5000)
    try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
  }

  deinit { sqlite3_close_v2(db) }

  public func exec(_ sql: String) throws {
    try lock.withLock {
      var err: UnsafeMutablePointer<CChar>?
      let rc = sqlite3_exec(db, sql, nil, nil, &err)
      if rc != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(err)
        throw SQLiteError(code: rc, message: msg, sql: sql)
      }
    }
  }

  @discardableResult
  public func run(_ sql: String, _ binds: [SQLBindable?] = []) throws -> Int {
    try lock.withLock {
      let stmt = try prepare(sql, binds)
      defer { sqlite3_finalize(stmt) }
      let rc = sqlite3_step(stmt)
      guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
      return Int(sqlite3_changes(db))
    }
  }

  public func query(_ sql: String, _ binds: [SQLBindable?] = []) throws -> [Row] {
    try lock.withLock {
      let stmt = try prepare(sql, binds)
      defer { sqlite3_finalize(stmt) }
      var rows: [Row] = []
      while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else { throw error(rc, sql) }
        var vals: [String: SQLValue] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
          let name = String(cString: sqlite3_column_name(stmt, i))
          switch sqlite3_column_type(stmt, i) {
          case SQLITE_INTEGER: vals[name] = .int(sqlite3_column_int64(stmt, i))
          case SQLITE_FLOAT: vals[name] = .double(sqlite3_column_double(stmt, i))
          case SQLITE_TEXT: vals[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
          default: vals[name] = .null
          }
        }
        rows.append(Row(values: vals))
      }
      return rows
    }
  }

  public func one(_ sql: String, _ binds: [SQLBindable?] = []) throws -> Row? { try query(sql, binds).first }

  public var lastInsertId: Int64 { lock.withLock { sqlite3_last_insert_rowid(db) } }

  /// Atomic block. Nested calls use savepoints, so helpers can wrap their own work safely.
  public func transaction<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      let depth = txDepth
      let sp = "sp\(depth)"
      try exec(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(sp)")
      txDepth += 1
      defer { txDepth -= 1 }
      do {
        let r = try body()
        try exec(depth == 0 ? "COMMIT" : "RELEASE \(sp)")
        return r
      } catch {
        try? exec(depth == 0 ? "ROLLBACK" : "ROLLBACK TO \(sp); RELEASE \(sp)")
        throw error
      }
    }
  }

  /// Online backup to another file (used for the daily rotating backup).
  public func backup(to dest: String) throws {
    try lock.withLock {
      var out: OpaquePointer?
      guard sqlite3_open(dest, &out) == SQLITE_OK else { throw SQLiteError(code: -1, message: "open backup", sql: dest) }
      defer { sqlite3_close(out) }
      guard let b = sqlite3_backup_init(out, "main", db, "main") else {
        throw SQLiteError(code: -1, message: String(cString: sqlite3_errmsg(out)), sql: nil)
      }
      let step = sqlite3_backup_step(b, -1)
      let fin = sqlite3_backup_finish(b)
      guard step == SQLITE_DONE, fin == SQLITE_OK else {
        throw SQLiteError(code: step == SQLITE_DONE ? fin : step, message: String(cString: sqlite3_errmsg(out)), sql: "backup")
      }
    }
  }

  public func integrityCheck() throws -> String {
    try query("PRAGMA integrity_check").first?.string("integrity_check") ?? "unknown"
  }

  private func prepare(_ sql: String, _ binds: [SQLBindable?]) throws -> OpaquePointer? {
    var stmt: OpaquePointer?
    let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard rc == SQLITE_OK else { throw error(rc, sql) }
    for (i, b) in binds.enumerated() {
      let idx = Int32(i + 1)
      switch b?.sqlValue ?? .null {
      case .null: sqlite3_bind_null(stmt, idx)
      case .int(let v): sqlite3_bind_int64(stmt, idx, v)
      case .double(let v): sqlite3_bind_double(stmt, idx, v)
      case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
      }
    }
    return stmt
  }

  private func error(_ rc: Int32, _ sql: String) -> SQLiteError {
    SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
  }
}
