// DEBUG only, so an app that links ScriperKit ships none of it in a Release build.
#if DEBUG
import Foundation

/// A fixed, finished app state for one screenshot, chosen per launch by the runner in `Scripts/`.
///
/// An app declares its scenes as a `String` enum and reads the scene of the launch once:
///
/// ```swift
/// enum ScreenshotScene: String, LaunchScene {
///     case list
///     case editor
///
///     static let current = launchScene()
/// }
/// ```
///
/// The raw value of a case is the scene's name in the app's `screenshots.conf`. The app knows
/// nothing about devices, languages, or the export; the runner sets those in the simulator.
public protocol LaunchScene: RawRepresentable where RawValue == String {}

public extension LaunchScene {
    /// The scene the runner launched the app with, or `nil` for a normal launch and for a name
    /// that is no case of the app's scenes.
    ///
    /// The launch argument lands in the argument domain of `UserDefaults`, which lives only as
    /// long as the process, so the next normal launch is unaffected.
    static func launchScene(in defaults: UserDefaults = .standard) -> Self? {
        defaults.string(forKey: launchSceneArgument).flatMap(Self.init(rawValue:))
    }
}

/// Name of the launch argument, without the leading dash. `Scripts/screenshots.sh` passes the
/// same name; change both together.
let launchSceneArgument = "ScreenshotScene"
#endif
