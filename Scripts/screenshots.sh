#!/bin/bash
#
# Captures App Store screenshots from the real app in the Simulator, for every configured device,
# store language, and scene, into ~/Downloads/<app>-SS-Export <date>/<device>/<language>/.
# For an app that keeps renders of its devices, each screenshot is also set into its render with
# its headline, as a finished store image in <export>/App Store/<device>/<language>/.
# See Documentation/ScriperKit.md.
#
# Usage, from the app's project root:
#   screenshots.sh --init
#     Writes a starting screenshots.conf and ScreenshotScene.swift for the app.
#   screenshots.sh [--config <path>, default ./screenshots.conf]
#     [--devices "iPhone,iPad"] [--locales "de-DE,en-US"] [--scenes "list,editor"]
# Devices and languages come from the built app: every configured device of a family it supports,
# in every language it is localized in. Each filter narrows that; without filters everything runs.
#
# Safety: the runner only touches its own simulators, named "ScriperKit <device>".
# Simulator settings are written with plutil to that simulator's own files, or with
# `simctl spawn` inside it, never with `defaults` on a path: `defaults` treats a path ending in
# .GlobalPreferences as the Mac's own global domain.

set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
# The stable Xcode, so a beta selected with xcode-select never builds the screenshots.
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
# Shared by every app, so a second app costs no further simulators. The app is installed fresh
# per language anyway.
SIMULATOR_PREFIX="ScriperKit"
# The app reads the scene from this launch argument; LaunchScene.swift holds the same name.
SCENE_ARGUMENT="-ScreenshotScene"
# Attempts to launch the app while the home screen is still coming up after boot.
LAUNCH_ATTEMPTS=15
LAUNCH_RETRY_SECONDS=2

CONFIG="screenshots.conf"
INIT=false
DEVICE_FILTER=""
LOCALE_FILTER=""
SCENE_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --init) INIT=true; shift ;;
    --config) CONFIG="$2"; shift 2 ;;
    --devices) DEVICE_FILTER="$2"; shift 2 ;;
    --locales) LOCALE_FILTER="$2"; shift 2 ;;
    --scenes) SCENE_FILTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

# Writes a starting configuration into the project root and a scene file into the app's source
# folder, named like the project as Xcode creates it. Never overwrites a file.
init_app() {
  local workspace name list scheme scene_file
  if [ -e screenshots.conf ]; then
    echo "screenshots.conf exists already in $(pwd)" >&2
    return 64
  fi
  workspace="$(find . -maxdepth 2 -name '*.xcworkspace' -not -path '*.xcodeproj/*' | sort | head -1)"
  if [ -z "$workspace" ]; then
    workspace="$(find . -maxdepth 1 -name '*.xcodeproj' | sort | head -1)"
    if [ -z "$workspace" ]; then
      echo "No Xcode workspace or project in $(pwd): run --init from the app's project root" >&2
      return 64
    fi
    # Every project carries a workspace of its own, so the runner always builds a workspace.
    workspace="$workspace/project.xcworkspace"
  fi
  workspace="${workspace#./}"
  name="$(basename "${workspace%/project.xcworkspace}")"
  name="${name%.*}"
  # The scheme named like the project, otherwise the first one; a workspace also lists the
  # schemes of its packages.
  list="$(mktemp)"
  xcodebuild -list -json -workspace "$workspace" > "$list" 2>/dev/null
  if grep -qF "\"$name\"" <(plutil -extract workspace.schemes json -o - "$list"); then
    scheme="$name"
  else
    scheme="$(plutil -extract workspace.schemes.0 raw -o - "$list")"
  fi
  rm "$list"

  scene_file="ScreenshotScene.swift"
  [ -d "$name" ] && scene_file="$name/ScreenshotScene.swift"
  if [ -e "$scene_file" ]; then
    echo "$scene_file exists already" >&2
    return 64
  fi

  cat > screenshots.conf <<CONF
# Configuration of ScriperKit's screenshot runner for this app. Devices and languages come from the
# built app. Any value of ScriperKit's Scripts/defaults.conf can be overridden here.

# Relative to the project root, where the runner is started.
WORKSPACE="$workspace"
SCHEME="$scheme"

# Scenes, in the order they are captured. Each name is a case of ScreenshotScene.
SCENES=(home)
CONF

  cat > "$scene_file" <<'SWIFT'
// DEBUG only, like ScriperKit itself, so none of it reaches the App Store build.
#if DEBUG
import ScriperKit

/// A fixed, finished app state for one App Store screenshot, chosen per launch by ScriperKit's
/// runner. Each case is a scene name in screenshots.conf, captured in that order.
///
/// Where the app decides what to show, check the scene and put the app into its state:
/// `if ScreenshotScene.current == .home { … }`, or `ScreenshotScene.isActive` for anything all
/// scenes share, such as hiding tips. Keep every such check behind `#if DEBUG` too.
enum ScreenshotScene: String, LaunchScene {
    case home

    /// The scene of this launch, or `nil` for a normal launch.
    static let current = launchScene()
}
#endif
SWIFT

  echo "Wrote screenshots.conf (workspace $workspace, scheme $scheme) and $scene_file."
  echo "Next: link the ScriperKit library to the app target, then draw the scenes."
}

if $INIT; then
  init_app
  exit
fi

# The defaults first, so the app's configuration overrides them and adds what only the app knows.
# shellcheck source=defaults.conf
source "$RUNNER_DIR/defaults.conf"
if [ ! -f "$CONFIG" ]; then
  echo "No $CONFIG in $(pwd): run from the app's project root, create one with --init, or pass --config" >&2
  exit 64
fi
# shellcheck disable=SC1090
source "$CONFIG"
: "${WORKSPACE:?The configuration must set WORKSPACE}"
: "${SCHEME:?The configuration must set SCHEME}"
: "${SCENES:?The configuration must set SCENES}"
# Per scheme, so two apps never share build products.
WORK_DIR="${TMPDIR:-/tmp}/ScriperKit/$SCHEME"

# True when the value is in the comma-separated filter, or when there is no filter.
is_selected() {
  local value="$1" filter="$2"
  [ -z "$filter" ] || [[ ",$filter," == *",$value,"* ]]
}

# One folder per app and day, so the day's latest images are always in one place: a later run adds
# its images and replaces those of the same device, language, and scene. Images no later run
# captured again, such as those of other languages, stay.
make_export_dir() {
  local dir="$HOME/Downloads/$APP_NAME-SS-Export $(date +%Y-%m-%d)"
  mkdir -p "$dir"
  echo "$dir"
}

build_app() {
  echo "Building $SCHEME for the Simulator…"
  xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$WORK_DIR/DerivedData" \
    -quiet build
  APP_PATH="$WORK_DIR/DerivedData/Build/Products/Debug-iphonesimulator/$SCHEME.app"
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Info.plist")"
  # Names the export folder. The bundle name rather than the display name, which may hold spaces.
  APP_NAME="$(plutil -extract CFBundleName raw -o - "$APP_PATH/Info.plist")"
}

# Scene code must vanish from a Release build, and a reference outside #if DEBUG fails only there.
# Checked before the first screenshot, so it never first shows up in the App Store build.
check_release_build() {
  local log="$WORK_DIR/release-build.log"
  echo "Checking the Release build…"
  if ! xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$WORK_DIR/DerivedData" \
    -quiet build > "$log" 2>&1; then
    # Xcode adds a line per failed compiler call that says nothing about the cause.
    grep -E "error:" "$log" | grep -v "the following command failed" | head -20 >&2 || true
    echo "The Release build fails. Is screenshot code outside #if DEBUG? Full log: $log" >&2
    return 65
  fi
}

# Reads languages and device families from the built app and the simulator runtimes. Compiled once
# and again only when its source changes; the stable Xcode builds it like the app.
build_simulator_info() {
  SIMULATOR_INFO="$WORK_DIR/simulator-info"
  if [ ! -x "$SIMULATOR_INFO" ] || [ "$RUNNER_DIR/simulator-info.swift" -nt "$SIMULATOR_INFO" ]; then
    mkdir -p "$WORK_DIR"
    xcrun swiftc -O -o "$SIMULATOR_INFO" "$RUNNER_DIR/simulator-info.swift"
  fi
}

# Store images are made only for an app that keeps renders, so every other app runs as it always
# has. A setup that cannot work as a whole, a headline font that is not there, is reported once
# and switches the step off instead of failing on every image.
check_store_images() {
  STORE_IMAGES=false
  COMPOSED=0
  [ -d "$RENDERS_DIR" ] || return 0
  if [ -n "$HEADLINE_FONT" ] && [ ! -f "$HEADLINE_FONT" ]; then
    echo "No store images: the headline font $HEADLINE_FONT does not exist. Check HEADLINE_FONT in $CONFIG" >&2
    ISSUES=$((ISSUES + 1))
    return 0
  fi
  STORE_IMAGE="$WORK_DIR/store-image"
  if [ ! -x "$STORE_IMAGE" ] || [ "$RUNNER_DIR/store-image.swift" -nt "$STORE_IMAGE" ]; then
    mkdir -p "$WORK_DIR"
    xcrun swiftc -O -o "$STORE_IMAGE" "$RUNNER_DIR/store-image.swift"
  fi
  STORE_IMAGES=true
}

# The headlines of a store language: its own file, or that of another region of the same
# language, so one en-US.json also serves en-GB, en-AU, and en-CA.
headline_file() {
  local folder="$1" candidate
  for candidate in "$HEADLINES_DIR/$folder.json" "$HEADLINES_DIR/${folder%%-*}.json" "$HEADLINES_DIR/${folder%%-*}"-*.json; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# Sets each screenshot of a device and language into its render, with its headline. A device
# without a renders folder is not set up for store images and is left alone. Inside a folder that
# exists, everything that keeps an image from being made is reported and counted: a store set
# with a missing image must not pass unnoticed.
compose_store_images() {
  local device_name="$1" folder="$2"
  local renders="$RENDERS_DIR/$device_name" output="$EXPORT_DIR/$STORE_FOLDER/$device_name/$folder"
  local scene screenshot render headlines headline number=0 name
  $STORE_IMAGES && [ -d "$renders" ] || return 0
  # Without a headlines folder the app wants images without text. With one, a language or scene
  # that has no headline is a gap in the setup.
  headlines=""
  if [ -d "$HEADLINES_DIR" ] && ! headlines="$(headline_file "$folder")"; then
    echo "No store images for $folder: no headlines file for it in $HEADLINES_DIR" >&2
    ISSUES=$((ISSUES + 1))
    return 0
  fi
  mkdir -p "$output"
  for scene in "${SCENES[@]}"; do
    # Numbered in the order of SCENES, because the store shows a set in the order of its file
    # names. Counted before the filter, so a narrowed run keeps every image's number.
    number=$((number + 1))
    # JPEG, the format the store is used to: smaller to upload, and it cannot carry the alpha
    # channel App Store Connect rejects.
    name="$(printf '%02d' "$number")-$scene.jpg"
    is_selected "$scene" "$SCENE_FILTER" || continue
    screenshot="$EXPORT_DIR/$device_name/$folder/$scene.png"
    # A screenshot that was not captured is reported where that happened.
    [ -f "$screenshot" ] || continue
    render="$renders/$scene.png"
    if [ ! -f "$render" ]; then
      echo "No store image for $scene: $render is missing" >&2
      ISSUES=$((ISSUES + 1))
      continue
    fi
    headline=""
    if [ -n "$headlines" ] && ! headline="$(plutil -extract "$scene" raw -o - "$headlines" 2>/dev/null)"; then
      echo "No store image for $scene in $folder: no headline \"$scene\" in $headlines" >&2
      ISSUES=$((ISSUES + 1))
      continue
    fi
    # The tool says what is wrong with a render it cannot use.
    if "$STORE_IMAGE" "$render" "$screenshot" "$output/$name" --headline "$headline" \
      --font "$HEADLINE_FONT" --weight "$HEADLINE_WEIGHT" --color "$HEADLINE_COLOR"; then
      COMPOSED=$((COMPOSED + 1))
    else
      ISSUES=$((ISSUES + 1))
    fi
  done
}

# One line per store language of the app on that simulator: folder|language|region|keyboard.
# With "-" instead of a simulator, the keyboard stays empty.
app_locales() {
  "$SIMULATOR_INFO" locales "$APP_PATH" "$1" "${STORE_LOCALES[@]}"
}

# A language the app is not localized in is never exported. One asked for by name ends the run
# before the first screenshot, because its images would show the wrong language.
check_requested_languages() {
  local folders folder
  [ -n "$LOCALE_FILTER" ] || return 0
  folders="$(app_locales - | cut -d '|' -f 1)"
  for folder in ${LOCALE_FILTER//,/ }; do
    if ! grep -qxF "$folder" <<< "$folders"; then
      echo "$APP_NAME is not localized in $folder. Its languages: $(tr '\n' ' ' <<< "$folders")" >&2
      return 64
    fi
  done
}

# The UTC timestamp `status_bar` expects for the configured local wall-clock time. The offset of
# that date applies, so daylight saving time on the run day does not shift the clock.
status_bar_time() {
  date -u -r "$(date -j -f "%Y-%m-%d %H:%M:%S" "$STATUS_BAR_DATE" +%s)" +%Y-%m-%dT%H:%M:%S.000Z
}

# Only available simulators count: one whose runtime was removed from the Mac cannot boot. Its
# replacement gets the newest installed runtime that supports the device type, which is what
# `simctl create` picks without a runtime.
find_or_create_simulator() {
  local name="$1" device_type="$2" udid
  udid="$(xcrun simctl list devices available | grep -F "    $name (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)"
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl create "$name" "$device_type")" || return 1
  fi
  echo "$udid"
}

preferences_dir() {
  echo "$HOME/Library/Developer/CoreSimulator/Devices/$1/data/Library/Preferences"
}

shutdown_simulator() {
  xcrun simctl shutdown "$1" 2>/dev/null || true
}

boot_simulator() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
}

# Writes language, region, and keyboard into the shut-down simulator's own preferences file, so
# the system, its status bar, and its keyboard come up in that language on the next boot.
set_simulator_language() {
  local udid="$1" language="$2" region="$3" keyboard="$4" file
  file="$(preferences_dir "$udid")/.GlobalPreferences.plist"
  # A new simulator writes this file on its first boot.
  if [ ! -f "$file" ]; then
    boot_simulator "$udid"
    shutdown_simulator "$udid"
  fi
  plutil -replace AppleLanguages -json "[\"$language\"]" "$file"
  plutil -replace AppleLocale -string "$region" "$file"
  plutil -replace AppleKeyboards -json "[\"$keyboard\",\"emoji@sw=Emoji\"]" "$file"
}

# Sets everything that must look the same in every screenshot of the booted simulator.
prepare_booted_simulator() {
  local udid="$1"
  xcrun simctl ui "$udid" appearance "$APPEARANCE"
  xcrun simctl status_bar "$udid" override --time "$(status_bar_time)" \
    --batteryState discharging --batteryLevel 100 \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
    --dataNetwork wifi --operatorName ''
  # The text cursor stays on instead of blinking, so every screenshot with an active text field
  # shows it. This is the system's accessibility setting "Prefer Non-Blinking Cursor".
  # The keyboard's first-use introductions would cover the keyboard in the editor scene:
  # swipe typing, and typing two scripts on one keyboard, e.g. Hindi and English.
  # MultilingualKeyboardTip is the two-scripts one; without it a new simulator shows that
  # introduction in its first run. All at once, because each write takes about 3 seconds, and
  # each one waited for, so a failed write still ends the run.
  local setting pid pids=()
  for setting in "com.apple.Accessibility PrefersNonBlinkingCursorIndicator" \
    "com.apple.keyboard.preferences MultilingualKeyboardTip" \
    "com.apple.Preferences DidShowContinuousPathIntroduction" \
    "com.apple.Preferences DidShowInternationalInfoIntroduction" \
    "com.apple.Preferences DidShowGestureKeyboardIntroduction" \
    "com.apple.Preferences DidShowInlineCompletionEducationTip" \
    "com.apple.Preferences DidShowGenmojiTip"; do
    # Unquoted on purpose: each entry is a preferences domain and a key.
    # shellcheck disable=SC2086
    xcrun simctl spawn "$udid" defaults write $setting -bool true &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  # A fresh install per language, so the sample script is seeded in that language.
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$APP_PATH"
}

# Launches the scene and keeps the app's process ID in LAUNCHED_PID. Simulator apps run as Mac
# processes, so the runner can check later whether the app is still alive.
launch_scene() {
  local udid="$1" scene="$2" attempt output
  for attempt in $(seq "$LAUNCH_ATTEMPTS"); do
    if output="$(xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" "$SCENE_ARGUMENT" "$scene" 2>/dev/null)"; then
      LAUNCHED_PID="${output##* }"
      return 0
    fi
    sleep "$LAUNCH_RETRY_SECONDS"
  done
  echo "Could not launch scene $scene" >&2
  return 1
}

# UUID of the simulator screen with the given native size.
display_uuid() {
  local udid="$1" width="$2" height="$3"
  xcrun simctl io "$udid" enumerate | awk -v w="$width" -v h="$height" '
    /UUID:/ { uuid = $2 }
    /Default width:/ { width = $3 }
    /Default height:/ { if (width == w && $3 == h) { print uuid; exit } }'
}

is_blank() {
  sips -g pixelWidth -g pixelHeight "$1" | awk -v bytes="$(stat -f %z "$1")" -v max="$BLANK_DISPLAY_MAX_BYTES_PER_PIXEL" '
    /pixelWidth:/ { width = $2 }
    /pixelHeight:/ { height = $2 }
    END { exit !(bytes / (width * height) < max) }'
}

# Screenshots until one repeats the attempt before it and the screen is not blank, so the export
# never shows a launch still in progress or a sheet mid-animation. Keeps the last attempt of a
# screen that never settled and reports it, so a person checks it. Attempts go to the work folder
# and reach the export only when kept, so a blank screen never replaces an earlier good image.
capture_settled() {
  local udid="$1" file="$2" display_option="$3" attempt_file="$WORK_DIR/attempt.png" previous attempt
  previous="$(mktemp)"
  for attempt in $(seq "$CAPTURE_ATTEMPTS"); do
    xcrun simctl io "$udid" screenshot ${display_option:+"$display_option"} "$attempt_file" >/dev/null 2>&1
    if ! is_blank "$attempt_file" && cmp -s "$attempt_file" "$previous"; then
      rm "$previous"
      mv "$attempt_file" "$file"
      CAPTURED=$((CAPTURED + 1))
      return 0
    fi
    cp "$attempt_file" "$previous"
    sleep "$CAPTURE_RETRY_SECONDS"
  done
  rm "$previous"
  if is_blank "$attempt_file"; then
    rm "$attempt_file"
    echo "Missing $(basename "$file"): the screen stayed blank" >&2
  else
    mv "$attempt_file" "$file"
    CAPTURED=$((CAPTURED + 1))
    echo "Check $(basename "$file"): the screen never settled" >&2
  fi
  ISSUES=$((ISSUES + 1))
}

capture_scene() {
  local udid="$1" displays="$2" folder="$3" scene="$4" spec name size uuid
  if [ -z "$displays" ]; then
    capture_settled "$udid" "$folder/$scene.png" ""
    return
  fi
  for spec in $displays; do
    name="${spec%%=*}"
    size="${spec#*=}"
    uuid="$(display_uuid "$udid" "${size%x*}" "${size#*x}")"
    if [ -z "$uuid" ]; then
      echo "Missing $scene-$name: no display of $size" >&2
      ISSUES=$((ISSUES + 1))
      continue
    fi
    capture_settled "$udid" "$folder/$scene-$name.png" "--display=$uuid"
  done
}

run_device() {
  local device_name="$1" device_type="$2" displays="$3"
  local udid locales folder language region keyboard scene support=0
  # A device family the app does not run on natively, such as iPad for an iPhone-only app, has no
  # place on its product page. An unknown device type goes on and is reported below.
  "$SIMULATOR_INFO" supports "$APP_PATH" "$device_type" 2>/dev/null || support=$?
  if [ "$support" -eq 1 ]; then
    echo "Skipping $device_name: $APP_NAME does not support this device family"
    return
  fi
  # A device no installed runtime supports is skipped, so it never costs the other devices.
  if ! udid="$(find_or_create_simulator "$SIMULATOR_PREFIX $device_name" "$device_type")"; then
    echo "Skipping $device_name: no installed runtime supports $device_type" >&2
    ISSUES=$((ISSUES + 1))
    return
  fi
  # Per device, because each simulator's runtime brings its own keyboards. Read from its own file
  # descriptor, because simctl inside the loop would otherwise consume the list from stdin.
  locales="$(app_locales "$udid")"
  while IFS='|' read -r folder language region keyboard <&3; do
    is_selected "$folder" "$LOCALE_FILTER" || continue
    echo "$device_name $folder"
    shutdown_simulator "$udid"
    set_simulator_language "$udid" "$language" "$region" "$keyboard"
    boot_simulator "$udid"
    prepare_booted_simulator "$udid"
    mkdir -p "$EXPORT_DIR/$device_name/$folder"
    for scene in "${SCENES[@]}"; do
      is_selected "$scene" "$SCENE_FILTER" || continue
      # One scene that fails to launch is reported, not allowed to end a long run.
      launch_scene "$udid" "$scene" || { ISSUES=$((ISSUES + 1)); continue; }
      sleep "$SCENE_SETTLE_SECONDS"
      # A stopped app would leave the home screen in the image. ScriperKit stops it on a scene
      # name the app does not know; any crash at launch ends the same way.
      if ! kill -0 "$LAUNCHED_PID" 2>/dev/null; then
        echo "Missing $scene: the app stopped after launch. Is \"$scene\" a case of the scene enum?" >&2
        ISSUES=$((ISSUES + 1))
        continue
      fi
      capture_scene "$udid" "$displays" "$EXPORT_DIR/$device_name/$folder" "$scene"
    done
    compose_store_images "$device_name" "$folder"
  done 3<<< "$locales"
  shutdown_simulator "$udid"
}

main() {
  local entry device_name device_type displays
  ISSUES=0
  CAPTURED=0
  build_app
  check_release_build
  build_simulator_info
  check_requested_languages
  check_store_images
  EXPORT_DIR="$(make_export_dir)"
  echo "Exporting to $EXPORT_DIR"
  # One device after the other: simulators booting in parallel slow each other down so much
  # that a run takes no less time, and late frames end up in the export.
  for entry in "${DEVICES[@]}"; do
    IFS='|' read -r device_name device_type displays <<< "$entry"
    is_selected "$device_name" "$DEVICE_FILTER" || continue
    run_device "$device_name" "$device_type" "$displays"
  done
  # Counts this run only: the folder may also hold images of an earlier run of the same day.
  if $STORE_IMAGES; then
    echo "$CAPTURED screenshots and $COMPOSED store images to $EXPORT_DIR, $ISSUES to check"
  else
    echo "$CAPTURED screenshots to $EXPORT_DIR, $ISSUES to check"
  fi
  # A filter value that matches nothing in the configuration, such as a typo, ends up here.
  if [ "$CAPTURED" -eq 0 ]; then
    echo "Nothing captured: check --devices, --locales, and --scenes against the configuration" >&2
    return 64
  fi
  open "$EXPORT_DIR"
  [ "$ISSUES" -eq 0 ]
}

main
