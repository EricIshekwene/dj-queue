import DJQCore
import SwiftUI

/// DJQCore.Settings collides with SwiftUI's Settings scene; always use this name in the app.
typealias AppSettings = DJQCore.Settings

/// Design tokens (design/DESIGN.md → Tokens).
enum DS {
  enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
  }

  enum Radius {
    static let thumb: CGFloat = 4
    static let control: CGFloat = 6
    static let card: CGFloat = 10
  }

  enum Row {
    static let list: CGFloat = 32
    static let queue: CGFloat = 56
    static let today: CGFloat = 64
  }

  static let queueThumb = CGSize(width: 28, height: 50)
  static let sidebarWidth: CGFloat = 220
  static let inspectorWidth: CGFloat = 300

  enum Font {
    static let largeTitle = SwiftUI.Font.system(size: 22, weight: .semibold)
    static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
    static let runway = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    static let runwaySmall = SwiftUI.Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    static let score = SwiftUI.Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    static let body = SwiftUI.Font.system(size: 13)
    static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .semibold)
    static let secondary = SwiftUI.Font.system(size: 11)
    static let secondaryStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
    static let mono = SwiftUI.Font.system(size: 11, design: .monospaced)
    static let eyebrow = SwiftUI.Font.system(size: 11, weight: .semibold)
  }

  /// Semantic status colours — colour is never decorative.
  enum Status {
    static let posted = Color.green
    static let planned = Color.blue
    static let warn = Color.orange
    static let error = Color.red
    static let off = Color.secondary
  }
}

extension PostState {
  var tint: Color {
    switch self {
    case .posted: DS.Status.posted
    case .planned, .rendering, .rendered: DS.Status.planned
    case .due: .accentColor
    case .overdue: DS.Status.warn
    case .failed, .copyrightBlocked, .copyrightMuted, .removed: DS.Status.error
    case .skipped: DS.Status.off
    }
  }

  var symbol: String? {
    switch self {
    case .posted: "checkmark"
    case .rendering: "gearshape"
    case .failed: "exclamationmark.triangle.fill"
    case .copyrightBlocked, .copyrightMuted, .removed: "c.circle.fill"
    case .overdue: "clock.badge.exclamationmark"
    default: nil
    }
  }
}

extension VideoState {
  var tint: Color {
    switch self {
    case .needsEdit: DS.Status.warn
    case .ready: DS.Status.planned
    case .planned, .posting: .accentColor
    case .posted: DS.Status.posted
    case .partial: DS.Status.warn
    case .excluded: DS.Status.off
    case .missingFile: DS.Status.error
    }
  }
}

extension Severity {
  var tint: Color {
    switch self {
    case .info: DS.Status.planned
    case .warning: DS.Status.warn
    case .error: DS.Status.error
    }
  }

  var symbol: String {
    switch self {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }
}

/// Short time like "7:00p" (DESIGN W.S2.b chips).
enum Fmt {
  static func shortTime(_ d: Date, tz: TimeZone) -> String {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    let h = c.component(.hour, from: d), m = c.component(.minute, from: d)
    let h12 = h % 12 == 0 ? 12 : h % 12
    return String(format: "%d:%02d%@", h12, m, h < 12 ? "a" : "p")
  }

  /// "7p" / "12:30p" for dense chips.
  static func compactTime(_ d: Date, tz: TimeZone) -> String {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return compactMinutes(c.component(.hour, from: d) * 60 + c.component(.minute, from: d))
  }

  static func compactMinutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    let h12 = h % 12 == 0 ? 12 : h % 12
    return mm == 0 ? "\(h12)\(h < 12 ? "a" : "p")" : String(format: "%d:%02d%@", h12, mm, h < 12 ? "a" : "p")
  }

  /// Wall-clock time on a given day (DST-safe: sets hour/minute instead of adding minutes to midnight).
  static func wallClock(_ day: Date, minutes: Int, calendar: Calendar) -> Date {
    calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
  }

  static func minutesOfDay(_ d: Date, calendar: Calendar) -> Int {
    let c = calendar.dateComponents([.hour, .minute], from: d)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
  }

  static func minutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    let h12 = h % 12 == 0 ? 12 : h % 12
    return String(format: "%d:%02d%@", h12, mm, h < 12 ? "a" : "p")
  }

  static func day(_ d: Date, tz: TimeZone, style: String = "EEE d MMM") -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = style
    return f.string(from: d)
  }

  static func relative(_ d: Date, now: Date) -> String {
    let s = Int(now.timeIntervalSince(d))
    if s < 0 {
      let f = -s
      if f < 3600 { return "in \(max(1, f / 60))m" }
      if f < 86400 { return "in \(f / 3600)h" }
      return "in \(f / 86400)d"
    }
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
  }

  static func duration(_ s: Double) -> String { Validation.fmt(s) }

  static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
