import Foundation

/// One engine per database: an exclusive `flock` on `<appSupport>/engine.lock` (the same file the app's
/// EngineHost uses). Held for as long as the object lives; released on `release()` or deinit.
public final class EngineLock: @unchecked Sendable {
  public static func url(_ paths: Paths) -> URL { paths.appSupport.appendingPathComponent("engine.lock") }

  private var fd: Int32

  private init(fd: Int32) { self.fd = fd }

  /// The lock, or nil when another process holds it (or the file can't be opened).
  public static func acquire(_ paths: Paths) -> EngineLock? {
    try? FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
    let fd = open(url(paths).path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return nil
    }
    return EngineLock(fd: fd)
  }

  /// True when some process currently holds the lock (checked without keeping it).
  public static func isHeld(_ paths: Paths) -> Bool {
    guard let l = acquire(paths) else { return true }
    l.release()
    return false
  }

  public func release() {
    guard fd >= 0 else { return }
    flock(fd, LOCK_UN)
    close(fd)
    fd = -1
  }

  deinit { release() }
}
