import Foundation

/// Append-only engine log at ~/Library/Logs/DJ Queue/engine.log, rotated at 5 MB (keeps 3).
public final class Log: @unchecked Sendable {
  public static let shared = Log()
  private let lock = NSLock()
  private var url: URL?
  public var echo = false
  private let fmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f
  }()

  public func configure(_ paths: Paths) {
    lock.withLock {
      try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
      url = paths.engineLog
    }
  }

  public func info(_ s: String) { write("INFO", s) }
  public func warn(_ s: String) { write("WARN", s) }
  public func error(_ s: String) { write("ERROR", s) }

  private func write(_ level: String, _ s: String) {
    lock.withLock {
      let line = "\(fmt.string(from: Date())) \(level) \(s)\n"
      if echo { FileHandle.standardError.write(Data(line.utf8)) }
      guard let url else { return }
      rotateIfNeeded(url)
      if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
      } else {
        try? Data(line.utf8).write(to: url)
      }
    }
  }

  private func rotateIfNeeded(_ url: URL) {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 else { return }
    for i in stride(from: 2, through: 1, by: -1) {
      let a = url.appendingPathExtension("\(i)"), b = url.appendingPathExtension("\(i + 1)")
      try? fm.removeItem(at: b)
      try? fm.moveItem(at: a, to: b)
    }
    try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
  }
}
