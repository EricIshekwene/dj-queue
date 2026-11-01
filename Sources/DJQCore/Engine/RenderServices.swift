import Foundation

/// Lets executables pick up the real renderer without the engine depending on it.
/// The app and the CLI set `factory = { Renderer(store: $0) }` once at launch.
public enum RenderServices {
  nonisolated(unsafe) public static var factory: ((Store) -> RenderService)?
  public static func make(_ store: Store) -> RenderService? { factory?(store) }
}
