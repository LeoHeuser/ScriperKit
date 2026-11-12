# ScriperKit

App Store screenshots from the real app in the Simulator, for every device, store language, and scene, in one run.

- **Real:** the images come from the running app, not from mockups or Previews.
- **Consistent:** the same status bar, a visible text cursor, and the keyboard of each language in every image.
- **Hands-off:** one command fills a dated folder in Downloads.

**Platform Support**: iOS/iPadOS 17.0+
**Toolchain**: Swift 6.2 or newer, the stable Xcode in `/Applications/Xcode.app`

## How it works

A scene is one fixed state of the app, such as "editor with keyboard". The runner builds the app once, then launches it once per device, store language, and scene, and tells it which scene to show. The app only has to draw that scene; devices, languages, the status bar, and the export are the runner's job.

Every run covers three devices (iPhone, iPad, iPhone Duo) in every store language the app is localized in.

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

### 2. Declare the scenes

One file in the app, DEBUG only:

```swift
#if DEBUG
import ScriperKit

enum ScreenshotScene: String, LaunchScene {
    case list
    case editor

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

Three rules keep the images identical from run to run:

- A scene is drawn, never played: no timers, no network, no camera or microphone.
- Anything that depends on timing or on first launch is switched off in a screenshot launch, such as tips, permission prompts, and a paywall.
- Scene code stays behind `#if DEBUG`, like the library.

### 4. Add the configuration

A file named `screenshots.conf` in the app, with three values:

```sh
# Relative to the project root, where the runner is started.
WORKSPACE="MyApp.xcworkspace"
SCHEME="MyApp"

# Scenes, in the order they are captured. Each name is a case of ScreenshotScene.
SCENES=(list editor)
```

Exclude the file from the app target, so it does not land in the app bundle.

### 5. Run it

From the app's project root:

```sh
../ScriperKit/Scripts/screenshots.sh --config path/to/screenshots.conf
```

Narrow a run while working on one scene:

```sh
../ScriperKit/Scripts/screenshots.sh --config path/to/screenshots.conf \
  --devices iPhone --locales "de-DE,en-US" --scenes editor
```

Keep Simulator.app closed during a run. The images land in:

```
~/Downloads/MyApp-SS-Export 2026-01-09/
  iPhone/de-DE/editor.png
  iPad/de-DE/editor.png
```

The run ends with the number of screenshots and of images to check. It exits with an error when an image needs a look.

## Adding a scene later

1. Add the case to `ScreenshotScene`.
2. Draw its state in the app.
3. Add its name to `SCENES` in `screenshots.conf`.

## Good to know

- **Simulators:** the runner creates its own, named `ScriperKit <device>`, and shares them between apps. It never touches other simulators or the Mac's settings.
- **Runtime:** a new simulator gets the newest installed runtime that supports the device. A device that no installed runtime supports is skipped and reported.
- **Languages:** a language the app is not localized in is never exported.
- **Time:** roughly a minute per device and language.

Details, the list of devices and store languages, and the decisions behind the design are in [Documentation/ScriperKit.md](Documentation/ScriperKit.md).
