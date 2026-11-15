#!/bin/bash
#
# Captures App Store screenshots from the real app in the Simulator, for every configured device,
# store language, and scene, into ~/Downloads/<app>-SS-Export <date>/<device>/<language>/.
# See Documentation/ScriperKit.md.
#
# Usage, from the app's project root:
#   screenshots.sh --config <app's screenshots.conf>
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

CONFIG=""
DEVICE_FILTER=""
LOCALE_FILTER=""
SCENE_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --devices) DEVICE_FILTER="$2"; shift 2 ;;
    --locales) LOCALE_FILTER="$2"; shift 2 ;;
    --scenes) SCENE_FILTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

# The defaults first, so the app's configuration overrides them and adds what only the app knows.
# shellcheck source=defaults.conf
source "$RUNNER_DIR/defaults.conf"
# shellcheck disable=SC1090
source "${CONFIG:?Pass the configuration of the app with --config}"
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

# Reads languages and device families from the built app and the simulator runtimes. Compiled once
# and again only when its source changes; the stable Xcode builds it like the app.
build_simulator_info() {
  SIMULATOR_INFO="$WORK_DIR/simulator-info"
  if [ ! -x "$SIMULATOR_INFO" ] || [ "$RUNNER_DIR/simulator-info.swift" -nt "$SIMULATOR_INFO" ]; then
    mkdir -p "$WORK_DIR"
    xcrun swiftc -O -o "$SIMULATOR_INFO" "$RUNNER_DIR/simulator-info.swift"
  fi
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

launch_scene() {
  local udid="$1" scene="$2" attempt
  for attempt in $(seq "$LAUNCH_ATTEMPTS"); do
    if xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" "$SCENE_ARGUMENT" "$scene" >/dev/null 2>&1; then
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
      capture_scene "$udid" "$displays" "$EXPORT_DIR/$device_name/$folder" "$scene"
    done
  done 3<<< "$locales"
  shutdown_simulator "$udid"
}

main() {
  local entry device_name device_type displays
  ISSUES=0
  CAPTURED=0
  build_app
  build_simulator_info
  check_requested_languages
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
  echo "$CAPTURED screenshots to $EXPORT_DIR, $ISSUES to check"
  # A filter value that matches nothing in the configuration, such as a typo, ends up here.
  if [ "$CAPTURED" -eq 0 ]; then
    echo "Nothing captured: check --devices, --locales, and --scenes against the configuration" >&2
    return 64
  fi
  open "$EXPORT_DIR"
  [ "$ISSUES" -eq 0 ]
}

main
