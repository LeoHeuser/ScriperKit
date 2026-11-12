# ScriperKit

How ScriperKit produces App Store screenshots from the real app in the Simulator, for every device class, store language, and scene, in one run.

## Objective

Screenshots come from the real app, look identical across languages and runs, and need no manual work. One command fills a dated export folder. Editing the images and uploading them to App Store Connect are out of scope.

## Parts

| Part | Where | Responsibility |
|---|---|---|
| Library | `Sources/ScriperKit`, DEBUG only | `LaunchScene`: the app reads which scene the runner launched it with |
| Runner | `Scripts/screenshots.sh` | Builds once, drives its own simulators, captures, exports |
| Defaults | `Scripts/defaults.conf` | Devices, store languages, status bar, timing: the same for every app |
| App configuration | `screenshots.conf` in the app | Workspace, scheme, and scenes |

The app knows nothing about devices, languages, or the export. The runner knows nothing about what a scene shows.

## Setting up an app

1. Add the package and link the `ScriperKit` library to the app target.
2. Declare the scenes and read the scene of the launch once:

   ```swift
   #if DEBUG
   import ScriperKit

   enum ScreenshotScene: String, LaunchScene {
       case list
       case editor

       static let current = launchScene()
   }
   #endif
   ```

3. Where `ScreenshotScene.current` is not `nil`, put the app into that scene's fixed state. A scene is drawn, never played: no timers, no network, no hardware, so two runs give the same image.
4. Add a `screenshots.conf` to the app, outside the app target:

   ```sh
   WORKSPACE="MyApp.xcworkspace"
   SCHEME="MyApp"
   SCENES=(list editor)
   ```

   `WORKSPACE` is relative to the folder the runner is started from. Each name in `SCENES` is the raw value of a case. Devices and store languages are not configured per app: a run covers every device, in every store language the app is localized in.

Everything of the library is DEBUG only, so a Release build of the app contains none of it. The app's own scene code belongs behind `#if DEBUG` too.

## Running it

From the app's project root:

```sh
../ScriperKit/Scripts/screenshots.sh --config <path>/screenshots.conf
../ScriperKit/Scripts/screenshots.sh --config <path>/screenshots.conf --devices iPhone --locales "de-DE,en-US" --scenes editor
```

Without filters, all devices, store languages, and scenes run, one device after the other. Expect roughly a minute per device and language: the restart and fresh install take half of it, the scenes the other half.

The run ends with the number of screenshots and of images to check, and exits with an error when any image needs a look. Counted as an image to check: a screen that never settled or stayed blank, a scene that failed to launch, and a device that no installed runtime supports, which is skipped. A filter that matches nothing ends the run with an error, and so does `--locales` with a language the app is not localized in.

Simulator.app should stay closed during a run: an attached Simulator window can connect the Mac keyboard and hide the software keyboard.

## What every screenshot gets

- **Settled screen:** the runner shoots until an image repeats the attempt before it and is not blank, so no launch in progress and no sheet mid-animation is exported.
- **Status bar:** 9:41 local time on Tuesday, January 9 (Apple convention), Wi-Fi with 3 bars, cellular with 4 bars, no carrier name, battery at 100 % and not charging, localized by the system.
- **System language:** the simulator's own language, region, and keyboard change per store language, not only the app's, because the system draws the status bar and the keyboard.
- **Visible text cursor:** the system's accessibility setting "Prefer Non-Blinking Cursor" is on, so the cursor stays on wherever a text field is active. If the setting ever stopped working, such a scene would be reported as never settled instead of exported without a cursor.
- **No keyboard introductions:** the keyboard's first-use introductions, such as swipe typing and typing two scripts on one keyboard, are set as already shown.
- **Fresh app:** the app is installed fresh per store language, so first-launch content is seeded in that language.

## Devices

| Device | Simulator | Output |
|---|---|---|
| iPhone | iPhone 17 Pro Max | 1320×2868 (6.9") |
| iPad | iPad Pro 13-inch (M5), portrait | 2064×2752 (13") |
| iPhone Duo | iPhone Duo | outer 1398×2034, inner 2007×2853 |

- No runtime is configured. A new simulator gets the newest installed runtime that supports its device type, so the next lower one is used when the newest does not. An existing simulator keeps its runtime for as long as that runtime is installed, so images stay the same from run to run; when it is removed, the runner creates a new simulator.
- A device that no installed runtime supports is skipped and counted as an image to check.
- iPhone Duo boots folded and cannot be unfolded from the command line, so only its outer screen is configured. Its inner screen is one configuration entry away once unfolding is possible; a display that stays blank is never exported.

## Store languages

The defaults cover 16 store languages: en-US, en-GB, de-DE, fr-FR, fr-CA, es-ES, es-MX, pt-BR, zh-Hans, zh-Hant, ja, ko, hi, ru, id, ms. Each maps to a system language, a region, and a keyboard. Regional variants share an app's text but differ in date, time, and keyboard, so each gets its own folder.

A run covers the store languages the built app is localized in, read from the app bundle: its own localization, or that of its base language, such as `en` for en-GB. A language the app does not speak is never exported, because its images would show another language.

For each store language the runner shuts the simulator down, writes language, region, and keyboard into that simulator's preferences file, boots it, and installs the app.

Keyboard identifiers follow the system's naming and are checked by looking at a scene with a keyboard in each language.

## Export

```
~/Downloads/<app>-SS-Export <YYYY-MM-DD>/
  iPhone/<store language>/<scene>.png
  iPad/<store language>/<scene>.png
  iPhone Duo/<store language>/<scene>-outer.png
```

`<app>` is the bundle name of the built app. A second run on the same day gets a new folder with a counter; an earlier export is never overwritten. The images keep the alpha channel the Simulator writes.

## Safety

- The runner only touches its own simulators, named `ScriperKit <device>`, and never the user's simulators or the Mac's settings. All apps share them.
- Simulator settings are written with `plutil` to that simulator's own files or with `simctl spawn` inside it. `defaults write` on a path is never used: for a path ending in `.GlobalPreferences` it writes the Mac's own global settings.
- The runner is not part of any package target, so it never lands in an app bundle.

## Decisions

- Launch arguments over UI tests, fastlane, or tapping through the app: deterministic, fast, and no external tool.
- Real Simulator output over rendered Previews: Previews lack the status bar, real app state, and guaranteed store resolutions.
- A restart per store language over one boot per device: slower, but the only way to get a localized status bar and keyboard.
- Devices one after the other over in parallel: parallel simulators slowed each other down so much that a run took no less time, and late frames reached the export.
- A fresh app install per language over erasing the simulator: same clean app state, one boot per language instead of two.
- A shell script run from the package checkout over a package plugin: Xcode cannot run a command plugin for an app project from the command line.
- Simulators shared by all apps over one set per app: the app is installed fresh anyway, and each further set costs several gigabytes.
