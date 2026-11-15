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
public protocol LaunchScene: RawRepresentable where RawValue == String {
    /// The scene of this launch, or `nil` for a normal launch. Declare it as
    /// `static let current = launchScene()`, so the launch argument is read once.
    static var current: Self? { get }
}

public extension LaunchScene {
    /// Whether this launch shows a screenshot scene, for code that behaves the same in every scene,
    /// such as hiding tips.
    static var isActive: Bool {
        current != nil
    }

    /// The scene the runner launched the app with, or `nil` for a normal launch.
    ///
    /// A name that is no case of the app's scenes stops the app: it is a typo in `screenshots.conf`
    /// or a missing case, and a normal launch would export the wrong screen without a word. The
    /// runner reports the scene as failed instead.
    ///
    /// The launch argument lands in the argument domain of `UserDefaults`, which lives only as
    /// long as the process, so the next normal launch is unaffected.
    static func launchScene(in defaults: UserDefaults = .standard) -> Self? {
        guard let name = defaults.string(forKey: launchSceneArgument) else { return nil }
        guard let scene = Self(rawValue: name) else {
            preconditionFailure("Unknown screenshot scene \"\(name)\": add it as a case of \(Self.self) or fix SCENES in screenshots.conf.")
        }
        return scene
    }
}

/// Name of the launch argument, without the leading dash. `Scripts/screenshots.sh` passes the
/// same name; change both together.
let launchSceneArgument = "ScreenshotScene"
#endif
