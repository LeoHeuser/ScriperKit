# ScriperKit

How ScriperKit produces App Store screenshots from the real app in the Simulator, for every device class, store language, and scene, in one run.

## Objective

Screenshots come from the real app, look identical across languages and runs, and need no manual work. One command fills a dated export folder. For an app that keeps renders of its devices, the same command also sets each screenshot into its render with a headline, so the folder holds finished App Store images (see Store images). Uploading them to App Store Connect is out of scope.

## Parts

| Part | Where | Responsibility |
|---|---|---|
| Library | `Sources/ScriperKit`, DEBUG only | `LaunchScene`: the app reads which scene the runner launched it with |
| Runner | `Scripts/screenshots.sh` | Builds once, drives its own simulators, captures, exports |
| Simulator info | `Scripts/simulator-info.swift` | Reads languages and device families from the built app, keyboards from the runtime |
| Store image | `Scripts/store-image.swift` | Sets one screenshot and one headline into a render |
| Defaults | `Scripts/defaults.conf` | Devices, store locale names, status bar, timing: the same for every app |
| App configuration | `screenshots.conf` in the app's project root | Workspace, scheme, scenes, and any default the app overrides |

The app knows nothing about devices, languages, or the export. The runner knows nothing about what a scene shows. Nothing about an app's languages or devices is configured: both come from the built app.

## Running it

From the app's project root:

```sh
../ScriperKit/Scripts/screenshots.sh --init
../ScriperKit/Scripts/screenshots.sh
../ScriperKit/Scripts/screenshots.sh --devices iPhone --locales "de-DE,en-US" --scenes editor
```

`--init` writes a starting `screenshots.conf` into the project root and `ScreenshotScene.swift` into the app's source folder, the folder named like the project. It finds the workspace, or the project's own workspace, and picks the scheme named like the project. It never overwrites a file. A run reads `./screenshots.conf`; `--config` points to one elsewhere.

Without filters, every supported device, store language, and scene runs, one device after the other. Expect roughly a minute per device and language: the restart and fresh install take half of it, the scenes the other half. Narrow the run while a scene is being built, then run everything once.

Before the first screenshot, the runner builds the app for Release as well and stops if that fails: a reference to scene code outside `#if DEBUG` fails only there, and would otherwise first show up in the App Store build.

The run ends with the number of screenshots and of images to check, and exits with an error when any image needs a look. Counted as an image to check: a screen that never settled or stayed blank, a scene that failed to launch, an app that stopped after launch, and a device that no installed runtime supports, which is skipped. The app stops on a scene name it does not know, so a typo in `SCENES` is reported instead of exporting the normal launch screen. A filter that matches nothing ends the run with an error, and so does `--locales` with a language the app is not localized in; that error lists the app's store languages.

Simulator.app should stay closed during a run: an attached Simulator window can connect the Mac keyboard and hide the software keyboard.

## What every screenshot gets

- **Settled screen:** the runner shoots until an image repeats the attempt before it and is not blank, so no launch in progress and no sheet mid-animation is exported.
- **Status bar:** 9:41 local time on Tuesday, January 9 (Apple convention), Wi-Fi with 3 bars, cellular with 4 bars, no carrier name, battery at 100 % and not charging, localized by the system.
- **System language:** the simulator's own language, region, and keyboard change per store language, not only the app's, because the system draws the status bar, dates, numbers, and the keyboard.
- **Visible text cursor:** the system's accessibility setting "Prefer Non-Blinking Cursor" is on, so the cursor stays on wherever a text field is active. If the setting ever stopped working, such a scene would be reported as never settled instead of exported without a cursor.
- **No keyboard introductions:** the keyboard's first-use introductions, such as swipe typing and typing two scripts on one keyboard, are set as already shown.
- **Fresh app:** the app is installed fresh per store language, so first-launch content is created in that language. All scenes of one language share that install, one launch after the other.

## Devices

| Device | Simulator | Output |
|---|---|---|
| iPhone | iPhone 17 Pro Max | 1320×2868 (6.9") |
| iPad | iPad Pro 13-inch (M5), portrait | 2064×2752 (13") |
| iPhone Duo | iPhone Duo | outer 1398×2034, inner 2007×2853 |

- A device whose family the app does not support natively is skipped: the runner reads `UIDeviceFamily` from the built app, so an iPhone-only app gets no iPad images. An app without the key runs on every device.
- No runtime is configured. A new simulator gets the newest installed runtime that supports its device type, so the next lower one is used when the newest does not. An existing simulator keeps its runtime for as long as that runtime is installed, so images stay the same from run to run; when it is removed, the runner creates a new simulator.
- A device that no installed runtime supports is skipped and counted as an image to check.
- Each boot and shutdown, once per language, can make system processes inside the simulator crash, such as PosterBoard, or exceed their shutdown time. These are faults of the simulator runtime, not of the app or the runner, and never reach a screenshot: the runner waits for a settled screen. macOS shows some of them as crash dialogs on the Mac.
- iPhone Duo boots folded and cannot be unfolded from the command line, so only its outer screen is configured. Its inner screen is one configuration entry away once unfolding is possible; a display that stays blank is never exported.

## Store languages

There is no list of supported languages. A run covers every language the built app is localized in:

1. **App languages:** every `.lproj` folder of the app bundle except `Base`, plus the development language. Xcode writes these from the app's String Catalogs and localizations, so adding a language in Xcode adds it to the next run.
2. **Export folders:** each app language is named by the App Store Connect locales it serves, from `STORE_LOCALES` in `defaults.conf`. An app language matches every store locale of that language its own region and script allow: "en" fills en-US, en-GB, en-AU, and en-CA; "pt-PT" fills only pt-PT; "zh-Hans" only zh-Hans. Xcode's "nb" fills the store's "no". A language with no store locale keeps its own code as the folder name. `STORE_LOCALES` names folders only; it never decides what runs.
3. **System settings:** per store locale, the runner derives the simulator's language, region, and keyboard. The region comes from the store locale, otherwise from the language's most likely region (Italian → Italy, Simplified Chinese → China). The keyboard is the default typing keyboard of that language and region in the simulator's own runtime, so a new iOS release brings its own keyboard names along.

Regional variants of one app language share its text but differ in date, number, and keyboard format, so each gets its own folder.

For each store language the runner shuts the simulator down, writes language, region, and keyboard into that simulator's preferences file, boots it, and installs the app.

## Export

```
~/Downloads/<app>-SS-Export <YYYY-MM-DD>/
  iPhone/<store language>/<scene>.png
  iPad/<store language>/<scene>.png
  iPhone Duo/<store language>/<scene>-outer.png
  App Store/<device>/<store language>/<nn>-<scene>.jpg   only with renders, see Store images
```

`<app>` is the bundle name of the built app. There is one folder per app and day: a later run of the same day adds its images and replaces those of the same device, language, and scene, so the latest state is always in one place. Images no later run captured again stay, and a screen that stays blank never replaces an earlier image. The run's count covers its own images only. The images keep the alpha channel the Simulator writes.

## Store images

A screenshot alone is not a product page image. A store image shows the device in a designed 3D scene with a headline above it. ScriperKit builds it from three parts, so only the screenshot and the headline change per language and the scene is exported once:

| Part | Made by | Changes with |
|---|---|---|
| Render | Spline, exported once per scene and device | The design of the scene |
| Screenshot | The runner, from the real app | Every run and language |
| Headline | A text file per store language | The language |

An app opts in by keeping renders. Without them the run is exactly the one described above.

### How it works

In the render the screen of the device is one flat magenta surface, the key. `store-image` finds that surface, measures its four edges, bends the screenshot onto it, and draws the headline. It needs no coordinates and knows nothing about the scene:

- **Nothing to layer:** whatever stands in front of the screen in the 3D scene, the Dynamic Island or an object floating before the device, already covers the key in the render. The screenshot only replaces the key that is left, so it lands behind those objects by itself.
- **Edges, not corners:** the lines are fitted to the straight middle of each edge and ignore the points an object in front pushed out of place, so rounded corners and a covered corner do not matter.
- **The screen in the middle:** a neighboring device may reach into the frame with a strip of its own screen. Only the key nearest the middle is used; the strip stays as rendered.
- **Any script:** the headline is set with Core Text, so Arabic and Hebrew are shaped and right-aligned, and a script the headline font does not cover gets a system font. A headline too long for its box in one language is set smaller instead of running into the device.

The store image has the size of the render, so export the render at a size the store accepts. It is written as a JPEG, which is smaller to upload and cannot carry the alpha channel App Store Connect rejects, and its file name starts with the scene's place in `SCENES`, because the store shows a set in the order of its file names. A language folder can be uploaded as it is.

### The scene in Spline

Renders come from Spline. The tool only relies on the key, so these rules are all a scene has to follow:

- **Screen:** a material of one flat color, `#ff00ff`, with no light, texture, or reflection on it. Any shading turns part of the screen into something that is no longer key.
- **One camera per scene**, framed on one device, named after the scene.
- **No text:** headlines are added per language. Text in the render would be the same in every language.
- **Export:** one PNG per camera at the store size of the device, such as 1320×2868 for the 6.9" iPhone, named like the scene.
- Objects before and behind the device, shadows, and a neighboring device at the edge of the frame are all fine.

Only Spline is supported. A render from another tool works when it follows the same rules, but nothing here is built or tested for it.

### Adding store images to an app

1. Build the scene in Spline with the rules above and export one PNG per scene.
2. Put the exports into the app's project root as `Screenshots/Renders/<device>/<scene>.png`, with `<device>` as in the export folder (`iPhone`) and `<scene>` as in `SCENES`. The folder is outside every target, so nothing of it ships. Commit it: the renders are part of the app like its icon.
3. Write the headlines as `metadata/screenshots/<store language>.json`, one entry per scene, a line break as `\n`:

   ```json
   { "today": "Six todos a day.\nNothing more.", "plan": "Plan tomorrow\nin a minute." }
   ```

   A file serves every region of its language: `en-US.json` is also used for en-GB, en-AU, and en-CA unless they have a file of their own. An app without the folder gets store images without text.
4. Optionally set the headline's typeface in `screenshots.conf`:

   ```sh
   HEADLINE_FONT="App/Assets/Fonts/MyFont.ttf"   # relative to the project root; empty: the system's bold face
   HEADLINE_WEIGHT="700"                         # for a variable font
   HEADLINE_COLOR="111316"
   ```

5. Run `screenshots.sh` as before. The store images land in `App Store/` inside the export folder.

A changed design means exporting the renders again and replacing the files. A new language needs only its headlines file.

### When something is missing

A problem with store images never stops the run, and the screenshots are always exported as before. What happens depends on how far the app is set up:

| State | Result |
|---|---|
| No `Screenshots/Renders` folder | Not set up: screenshots only, no message |
| No folder for a device in it | That device is not set up: screenshots only, no message |
| Headline font does not exist | No store images in this run, reported once |
| No render for a scene | No store image for that scene, reported |
| No headlines file for a language, or no headline for a scene | No store images for that language or scene, reported |
| Render without a key-colored screen | No store image for that scene, reported |

Everything reported counts as an image to check, so a run with a gap ends with an error like any other: an incomplete set must not reach the store unnoticed.

Devices with several displays, such as iPhone Duo, get no store images.

## Integrating an app

The steps in the README set the package up. What follows is what scenes need in a real app, beyond reading their name.

### Rules for every scene

- **Drawn, never played.** A scene shows a fixed state: no timers, network, camera, microphone, biometrics, or on-device model run. Where the app shows the result of such work, it shows a fixed result instead.
- **The same in every language and run.** Anything that depends on the device, an account, timing, or an earlier launch is set to a fixed value in a screenshot launch.
- **DEBUG only.** All scene code sits behind `#if DEBUG`, like the library. The runner checks that the Release build still succeeds.
- **One check for all scenes.** Where something applies to every scene, such as hiding tips, ask `ScreenshotScene.isActive`; ask `ScreenshotScene.current` only where scenes differ.
- **A real user's view.** A scene shows what a set-up user sees: permissions granted, onboarding done, paid features available, an account signed in. The app code that decides these states stays as it is; the scene only answers its questions.

### Demo content

- **A store of its own.** Open an in-memory store in a screenshot launch and fill it on every launch. Each scene relaunches the app, so the content is identical for every scene, and the real store, its migrations, and any cloud sync are never touched.
- **Finished content.** Create records in their processed state, so no background work, such as text recognition, runs while a scene is captured.
- **Fixed anchors.** Give the records a scene opens fixed identifiers, so the scene finds them after seeding.
- **Fresh dates.** Date content relative to the launch, so date groups such as "Last 30 days" look current in every run.
- **Localized.** Put the demo texts into a String Catalog of their own and read them with `String(localized:table:)`. Placed in the folder of `DEVELOPMENT_ASSET_PATHS` (Xcode's "Preview Content"), it builds into DEBUG apps and is left out of archives, so demo texts never ship. Translate it into every app language; a language without a translation shows the development language in its screenshots.
- **Generated files.** Content that is a file, such as a PDF or an image, can be rendered at launch from a SwiftUI view with `ImageRenderer`, so it carries the localized text too.

### Switching off what varies

| What | Why | How |
|---|---|---|
| Onboarding and first-launch flows | Hide the app's content | Write the app's own completion flags into `UserDefaults` before the first view reads them |
| Tips | Depend on timing and earlier launches | `Tips.hideAllTipsForTesting()` before `Tips.configure` |
| Review prompts | Demo content can trip a trigger | Make the prompt's guard return `false` |
| Permission prompts | The Simulator cannot grant some permissions | Report the permission as granted to the app's own checks |
| Paywalls and limits | Cover features; StoreKit answers vary | A fixed entitlement that never asks StoreKit, such as a preview initializer of the paywall service |
| Account and hardware state | The Simulator has no iCloud account, passcode, NFC, or camera | Report the state the screenshot shows to the view that reads it |
| On-device model availability | Differs per Mac and per language | Treat the feature as available and show a fixed result |

### Putting the app into a scene

- **Navigation:** append the scene's destination to the `NavigationStack` path on launch. A destination that the stack does not resolve yet gets its own small route type with its own `navigationDestination(for:)`, both DEBUG only.
- **Sheets:** start the sheet's presentation state with the scene's value. A page inside a sheet opens with `navigationDestination(isPresented:)`, its state also started from the scene.
- **Search and text fields:** set the field's text on launch; a field that should show the keyboard gets its focus from the scene.
- **Results of services:** a service's state is usually `private(set)`, so give the service a DEBUG method in its own file that sets a fixed result. It needs no knowledge of the scenes; the caller passes the content.
- **Scroll positions:** iOS 18's `ScrollPosition` scrolls to an offset; on iOS 17, keep the start position behind an `#available` check.

### Code shared with extensions

An app extension that compiles some of the app's files does not link ScriperKit and has no scene type. Keep scene checks out of those files: give them a neutral DEBUG method, such as one that opens an in-memory store, and make the scene decision in an app-only file or view.

### Checking the result

1. Run one device in two languages with very different text lengths and formats, such as German and Japanese, and look at every image.
2. Run everything.

## Safety

- The runner only touches its own simulators, named `ScriperKit <device>`, and never the user's simulators or the Mac's settings. All apps share them.
- Simulator settings are written with `plutil` to that simulator's own files or with `simctl spawn` inside it. `defaults write` on a path is never used: for a path ending in `.GlobalPreferences` it writes the Mac's own global settings.
- The runner and its helper are not part of any package target, so they never land in an app bundle. The helper is compiled into the runner's work folder in the temporary directory.

## Decisions

- Launch arguments over UI tests, fastlane, or tapping through the app: deterministic, fast, and no external tool.
- Real Simulator output over rendered Previews: Previews lack the status bar, real app state, and guaranteed store resolutions.
- Languages and device families read from the built app over a list per app or in ScriperKit: Xcode already knows them, so a new language or device family needs no change anywhere else, and no screenshot is ever exported in a language the app does not speak.
- Keyboards read from the simulator runtime over a fixed table: the runtime is the source of truth for its own keyboard names, which change between iOS releases.
- A Swift helper for reading plists, JSON, and locale data over shell parsing: Foundation knows likely regions and canonical language codes, and the shell stays a plain sequence of steps.
- A restart per store language over one boot per device: slower, but the only way to get a localized status bar and keyboard.
- Devices one after the other over in parallel: parallel simulators slowed each other down so much that a run took no less time, and late frames reached the export.
- One export folder per day, updated by every run, over a new folder per run: a narrowed run to fix one scene lands next to the rest, so the day's complete set is always in one folder.
- A fresh app install per language over erasing the simulator: same clean app state, one boot per language instead of two.
- The configuration in the project root over one inside the app's folders: outside every target, it needs no exclusion, and the runner finds it without a path.
- A Release build before every run over a note in the documentation: the one integration mistake that breaks the App Store build is caught where it happens.
- An unknown scene name stops the app over a normal launch: a silent fallback exported the wrong screen with no warning.
- A shell script run from the package checkout over a package plugin: Xcode cannot run a command plugin for an app project from the command line.
- Simulators shared by all apps over one set per app: the app is installed fresh anyway, and each further set costs several gigabytes.
- A key color in the render over a list of screen coordinates per scene: the render itself says where the screen is and what covers it, so a changed camera or a new scene needs no number changed anywhere.
- The screenshot and the headline set into an exported render over placing them in Spline: an image cannot be put into a Spline file from the command line, so every language would mean opening the file, replacing five images, and exporting again.
- Renders and headlines in the app's repository over the package or a shared folder: they belong to one app, change with its design and its texts, and a run must be repeatable from a checkout alone.
- Store images opt in by the renders folder over a switch in the configuration: an app that has none runs as before without knowing the step exists.
- Store images as JPEG over PNG: a PNG with an alpha channel is rejected by App Store Connect even when every pixel is opaque, and a JPEG at high quality is about a fifth of the size with no visible loss in interface text. The screenshots themselves stay PNG, as the Simulator writes them.
- A Swift tool over a script in another language: it needs nothing but Xcode, and Core Text sets every script the store has.
