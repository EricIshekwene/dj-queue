import Foundation

/// Where the Postiz public API key lives (docs/postiz.md §7): the login Keychain, service "DJ Queue Postiz",
/// account "postiz". The value is read only at call time and never logged, printed, stored in the database, events,
/// Doctor output or `djq` JSON. `hasKey` never reveals it.
public protocol PostizKeyStore: AnyObject, Sendable {
  /// The key, or nil when none is saved. Only the Postiz client calls this.
  func read() throws -> String?
  func save(_ key: String) throws
  func delete() throws
  func hasKey() -> Bool
}

public struct PostizKeyError: LocalizedError, CustomStringConvertible, Equatable {
  public let message: String
  public init(_ m: String) { message = m }
  public var errorDescription: String? { message }
  public var description: String { message }
}

/// The Keychain through `/usr/bin/security`.
///
/// Why the command-line tool instead of the Security framework: DJ Queue is ad-hoc signed and rebuilt on every
/// update, so an item whose access list trusts the app would prompt after each install. An item created by
/// `/usr/bin/security` trusts `/usr/bin/security`, so reads through it never prompt. Saving goes through
/// `security -i` with the command on **stdin**, so the key never appears in a process argument list (`ps`).
/// Reads capture stdout in memory and never log it.
public final class KeychainPostizKeyStore: PostizKeyStore, @unchecked Sendable {
  public static let service = "DJ Queue Postiz"
  public static let account = "postiz"
  public static let tool = "/usr/bin/security"

  /// Runs `tool` with `args`, feeding `stdin`; returns (exit status, stdout). Injectable so tests check the commands
  /// without touching the real Keychain.
  public typealias Runner = (_ tool: String, _ args: [String], _ stdin: Data?) throws -> (status: Int32, stdout: Data)
  let run: Runner
  /// Obeys `PostizLive.disabled` (always true for the real `/usr/bin/security` runner; tests pass a recording runner
  /// with `obeysKillSwitch: true` to check the switch without ever holding a store wired to the real tool).
  let obeysKillSwitch: Bool

  public init(runner: Runner? = nil, obeysKillSwitch: Bool? = nil) {
    run = runner ?? Self.process
    self.obeysKillSwitch = runner == nil ? true : (obeysKillSwitch ?? false)
  }

  var off: Bool { obeysKillSwitch && PostizLive.disabled }

  public func read() throws -> String? {
    guard !off else { return nil }
    let (status, out) = try run(Self.tool, Self.readArgs, nil)
    if status == 44 { return nil }  // not found
    guard status == 0 else { throw PostizKeyError("The Keychain is locked or refused access (security exit \(status))") }
    let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
  }

  public func hasKey() -> Bool {
    guard !off else { return false }
    return ((try? run(Self.tool, Self.findArgs, nil))?.status ?? 1) == 0
  }

  public func save(_ key: String) throws {
    guard !off else { throw PostizKeyError("Keychain access is turned off in this process") }
    let script = try Self.saveScript(key)
    let (status, _) = try run(Self.tool, ["-i"], Data(script.utf8))
    guard status == 0 else { throw PostizKeyError("Couldn't save the key in the Keychain (security exit \(status))") }
    guard hasKey() else { throw PostizKeyError("The Keychain didn't keep the key") }
  }

  public func delete() throws {
    guard !off else { throw PostizKeyError("Keychain access is turned off in this process") }
    let (status, _) = try run(Self.tool, Self.deleteArgs, nil)
    guard status == 0 || status == 44 else { throw PostizKeyError("Couldn't remove the key (security exit \(status))") }
  }

  static let readArgs = ["find-generic-password", "-s", service, "-a", account, "-w"]
  /// Without `-w` the tool prints only the item's attributes; its output is discarded.
  static let findArgs = ["find-generic-password", "-s", service, "-a", account]
  static let deleteArgs = ["delete-generic-password", "-s", service, "-a", account]

  /// A Postiz key is one token: letters, digits and `-_.:+/=`. Anything else (spaces, quotes, newlines) is refused,
  /// which also keeps the `security -i` line unambiguous.
  public static func validate(_ key: String) throws -> String {
    let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !k.isEmpty else { throw PostizKeyError("Paste the Postiz API key") }
    guard k.count <= 512 else { throw PostizKeyError("That's too long to be a Postiz API key") }
    let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:+/="))
    guard k.unicodeScalars.allSatisfy({ ok.contains($0) && $0.isASCII }) else {
      throw PostizKeyError("That doesn't look like a Postiz API key (letters and digits only)")
    }
    return k
  }

  /// The `security -i` command that adds or updates (`-U`) the item.
  static func saveScript(_ key: String) throws -> String {
    let k = try validate(key)
    return "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -l \"\(service)\" -w \"\(k)\"\n"
  }

  static func process(_ tool: String, _ args: [String], _ stdin: Data?) throws -> (status: Int32, stdout: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let input = Pipe()
    p.standardInput = input
    try p.run()
    if let stdin { input.fileHandleForWriting.write(stdin) }
    try? input.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    _ = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
  }
}

/// In-memory key store for tests and previews.
public final class MemoryPostizKeyStore: PostizKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String?
  public private(set) var reads = 0
  public init(key: String? = nil) { self.key = key }
  public func read() throws -> String? { lock.withLock { reads += 1; return key } }
  public func save(_ k: String) throws { let v = try KeychainPostizKeyStore.validate(k); lock.withLock { key = v } }
  public func delete() throws { lock.withLock { key = nil } }
  public func hasKey() -> Bool { lock.withLock { key != nil } }
}
