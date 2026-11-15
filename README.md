# ScriperKit

App Store screenshots from the real app in the Simulator, for every device, store language, and scene, in one run.

- **Real:** the images come from the running app, not from mockups or Previews.
- **Consistent:** the same status bar, a visible text cursor, and the keyboard of each language in every image.
- **Hands-off:** one command fills a dated folder in Downloads.

**Platform Support**: iOS/iPadOS 17.0+
**Toolchain**: Swift 6.2 or newer, the stable Xcode in `/Applications/Xcode.app`

## How it works

A scene is one fixed state of the app, such as "editor with keyboard". The runner builds the app once, then launches it once per device, store language, and scene, and tells it which scene to show. The app only has to draw that scene; devices, languages, the status bar, and the export are the runner's job.

Nothing about languages or devices is configured. The runner reads both from the built app: every language Xcode localized it in, named like the store locales in App Store Connect, on every device family it supports (iPhone, iPad, iPhone Duo).

## Adding it to an app

### 1. Add the package

Keep the checkout next to the app, because the runner is started from it:

```
Xcode/
  MyApp/
  ScriperKit/
```

In Xcode: **File** → **Add Package Dependencies…**, enter `https://github.com/LeoHeuser/ScriperKit`, and link the `ScriperKit` library to the app target.

Everything in the library is DEBUG only. A Release build of the app links an empty module.

### 2. Set it up

From the app's project root:

```sh
../ScriperKit/Scripts/screenshots.sh --init
```

It finds the workspace and scheme and writes two files:

- `screenshots.conf` in the project root, outside every target, so it never lands in the app bundle.
- `ScreenshotScene.swift` in the app's source folder, with one scene to start from:

```swift
#if DEBUG
import ScriperKit

enum ScreenshotScene: String, LaunchScene {
    case home

    /// The scene of this launch, or `nil` for a normal launch.
    static let current = launchScene()
}
#endif
```

### 3. Draw the scenes

Where the app decides what to show, ask for the scene and put the app into its state:

```swift
#if DEBUG
.onAppear {
    if ScreenshotScene.current == .editor {
        isEditorFocused = true
    }
}
#endif
```

For what every scene shares, such as hiding tips, ask `ScreenshotScene.isActive`.

Three rules keep the images identical from run to run:

- A scene is drawn, never played: no timers, no network, no camera, microphone, or on-device model. Where the app would show their result, it shows a fixed one.
- Anything that depends on timing, an account, or an earlier launch is switched off in a screenshot launch, such as onboarding, tips, review and permission prompts, and a paywall.
- Scene code stays behind `#if DEBUG`, like the library.

Most apps also need demo content: an in-memory store filled on every screenshot launch, with texts from a String Catalog in "Preview Content", so they are translated but never ship. The [integration guide](Documentation/ScriperKit.md#integrating-an-app) covers this, navigation, sheets, fixed service results, and code shared with app extensions.

### 4. Run it

From the app's project root:

```sh
../ScriperKit/Scripts/screenshots.sh
```

Narrow a run while working on one scene:

```sh
../ScriperKit/Scripts/screenshots.sh --devices iPhone --locales "de-DE,en-US" --scenes editor
```

Keep Simulator.app closed during a run. The images land in one folder per day; a later run of the same day replaces the images it captures again and keeps the rest:

```
~/Downloads/MyApp-SS-Export 2026-01-09/
  iPhone/de-DE/editor.png
  iPad/de-DE/editor.png
```

The run ends with the number of screenshots and of images to check. It exits with an error when an image needs a look.

### Mistakes it catches

- **Scene code outside `#if DEBUG`:** before the first screenshot, the runner builds Release too and stops if that fails, so the mistake never reaches the App Store build.
- **A scene name the app does not know:** a typo in `SCENES` or a missing case stops the app instead of exporting the normal launch screen, and the runner reports that scene.

## Adding a scene later

1. Add the case to `ScreenshotScene`.
2. Draw its state in the app.
3. Add its name to `SCENES` in `screenshots.conf`.

## Configuration

`screenshots.conf` sets the workspace, the scheme, and the scenes. Any value of `Scripts/defaults.conf` can be overridden there too, such as `APPEARANCE="light"`. A configuration somewhere else runs with `--config path/to/screenshots.conf`.

## Good to know

- **Simulators:** the runner creates its own, named `ScriperKit <device>`, and shares them between apps. It never touches other simulators or the Mac's settings.
- **Runtime:** a new simulator gets the newest installed runtime that supports the device. A device that no installed runtime supports is skipped and reported.
- **Languages:** every `.lproj` of the built app runs, so a language added in Xcode is in the next run. "en" fills en-US, en-GB, en-AU, and en-CA; a regional localization such as pt-PT fills only its own store. Region and keyboard come from the simulator runtime.
- **Devices:** a device family the app does not support, such as iPad for an iPhone-only app, is skipped.
- **Time:** roughly a minute per device and language.
- **Crash dialogs:** macOS may show "quit unexpectedly" dialogs for processes inside the simulator, such as PosterBoard or system daemons. They come from the simulator runtime itself while it boots and shuts down, which a run does once per language, and do not affect the screenshots.

Details, the list of devices and store languages, and the decisions behind the design are in [Documentation/ScriperKit.md](Documentation/ScriperKit.md).
