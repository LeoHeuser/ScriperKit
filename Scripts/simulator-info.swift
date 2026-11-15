// Answers what the runner needs to know from the built app and the installed simulator runtimes,
// so no app has to list its languages or devices. Compiled once per run by screenshots.sh.
// See Documentation/ScriperKit.md.
//
// Usage:
//   simulator-info locales <app> <simulator udid | -> <store locale>...
//     One line per store language of the app: folder|system language|region|keyboard
//     With "-" instead of a simulator, the keyboard column stays empty: enough to check names.
//   simulator-info supports <app> <device type identifier>
//     Exits 0 when the app runs natively on the device type's family, 1 otherwise.

import Foundation

// MARK: - App

/// Every language the app is localized in: its `.lproj` folders without `Base`, plus the
/// development language, which an app may ship without a folder of its own.
func appLanguages(at app: URL) throws -> [String] {
    let folders = try FileManager.default.contentsOfDirectory(atPath: app.path)
        .filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }
        .map { String($0.dropLast(".lproj".count)) }
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
    let development = info?["CFBundleDevelopmentRegion"] as? String
    let all = folders + [development].compactMap { $0 }
    // Canonical form, so "English", "pt_PT", and "pt-PT" each count once.
    return Array(Set(all.map { Locale.canonicalLanguageIdentifier(from: $0) }))
}

/// Families of `UIDeviceFamily`: 1 is iPhone, 2 is iPad. Without the key, an app runs everywhere.
func appSupports(_ productFamily: String, at app: URL) -> Bool {
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
    guard let families = info?["UIDeviceFamily"] as? [Int] else { return true }
    switch productFamily {
    case "iPhone": return families.contains(1)
    case "iPad": return families.contains(2)
    default: return false
    }
}

// MARK: - Simulators

func simctlList(_ arguments: [String]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "list", "--json"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

func productFamily(ofDeviceType identifier: String) throws -> String? {
    let types = try simctlList(["devicetypes"])["devicetypes"] as? [[String: Any]] ?? []
    return types.first { $0["identifier"] as? String == identifier }?["productFamily"] as? String
}

/// The keyboard folder of the runtime the simulator runs on.
func textInputFolder(ofSimulator udid: String) throws -> URL? {
    let list = try simctlList(["devices", "runtimes"])
    let devices = list["devices"] as? [String: [[String: Any]]] ?? [:]
    guard let runtimeID = devices.first(where: { $0.value.contains { $0["udid"] as? String == udid } })?.key,
          let runtimes = list["runtimes"] as? [[String: Any]],
          let root = runtimes.first(where: { $0["identifier"] as? String == runtimeID })?["runtimeRoot"] as? String
    else { return nil }
    return URL(fileURLWithPath: root).appendingPathComponent("System/Library/TextInput")
}

// MARK: - Keyboards

/// The keyboard tables of every language the runtime ships, merged.
struct Keyboards {
    /// Locale or language, such as "en_GB" or "ja", to its default input modes, best first.
    var defaults: [String: [String]] = [:]
    /// Input mode to its software layouts, the default first.
    var layouts: [String: [String]] = [:]

    init(folder: URL) {
        let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for bundle in bundles where bundle.lastPathComponent.hasPrefix("TextInput_") {
            let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("InputMode_") {
                guard let plist = NSDictionary(contentsOf: file) else { continue }
                for (key, modes) in plist["UIKeyboardDefaultLanguageInputModes"] as? [String: [String]] ?? [:] {
                    defaults[key] = modes
                }
                for (mode, settings) in plist["UIKeyboardSupportedInputModes"] as? [String: [String: Any]] ?? [:] {
                    layouts[mode] = settings["SWLayouts"] as? [String] ?? []
                }
            }
        }
    }

    /// The keyboard a person in this language and region gets by default, as AppleKeyboards
    /// writes it, such as "de_DE@sw=QWERTZ-German;hw=Automatic".
    func keyboard(language: String, script: String?, region: String) -> String {
        let keys = [script.map { "\(language)_\($0)" }, "\(language)_\(region)", language].compactMap { $0 }
        // A typing keyboard of the language itself: the default lists also hold handwriting,
        // transliteration, multilingual, and English modes.
        let ownModes = keys.lazy.compactMap { defaults[$0] }.flatMap { $0 }.filter { mode in
            Keyboards.language(of: mode) == language && !["HWR", "Translit", "@ml="].contains { mode.contains($0) }
        }
        let mode = ownModes.first
            ?? ["\(language)_\(region)", language].first { layouts[$0] != nil }
            ?? "en_US"
        if mode.contains("@sw=") {
            return "\(mode);hw=Automatic"
        }
        guard let layout = layouts[Keyboards.baseMode(of: mode)]?.first ?? layouts[mode]?.first else {
            return mode
        }
        return "\(mode)@sw=\(layout);hw=Automatic"
    }

    static func language(of mode: String) -> String {
        String(mode.prefix { $0.isLetter })
    }

    static func baseMode(of mode: String) -> String {
        String(mode.prefix { $0 != "@" })
    }
}

// MARK: - Store languages

/// App Store Connect writes Norwegian as "no", Xcode as "nb".
let languageAliases = ["no": "nb"]

func languageCode(_ identifier: String) -> String {
    let code = Locale.Language(identifier: identifier).languageCode?.identifier ?? identifier
    return languageAliases[code] ?? code
}

/// The store languages that show an app language: every store locale of the same language whose
/// script and region the app language does not rule out, such as en-US, en-GB, en-AU, and en-CA
/// for "en". A language without a store locale keeps its own code as the folder.
func storeFolders(for appLanguage: String, storeLocales: [String]) -> [String] {
    let app = Locale.Language(identifier: appLanguage)
    let matches = storeLocales.filter { storeLocale in
        let store = Locale.Language(identifier: storeLocale)
        guard languageCode(storeLocale) == languageCode(appLanguage) else { return false }
        if let script = app.script, let storeScript = store.script, script != storeScript { return false }
        if let region = app.region, store.region != region { return false }
        return true
    }
    return matches.isEmpty ? [appLanguage] : matches
}

func printLocales(app: URL, simulator: String, storeLocales: [String]) throws {
    var keyboards: Keyboards?
    if simulator != "-" {
        guard let textInput = try textInputFolder(ofSimulator: simulator) else {
            throw RunnerError("No runtime found for simulator \(simulator)")
        }
        keyboards = Keyboards(folder: textInput)
    }
    var lines: [String: String] = [:]
    // Most specific first, so an app with both "en" and "en-GB" shows en-GB from its own folder.
    let languages = try appLanguages(at: app).sorted { $0.count > $1.count }
    for appLanguage in languages {
        for folder in storeFolders(for: appLanguage, storeLocales: storeLocales) where lines[folder] == nil {
            // The store locale with the app's own language code, such as "nb" for the store's "no".
            let suffix = folder.drop { $0.isLetter }
            let systemLanguage = languageCode(appLanguage) + suffix
            let language = Locale.Language(identifier: systemLanguage)
            // The store's region, otherwise the language's most likely one, such as IT for "it".
            let region = language.region?.identifier
                ?? Locale.Language(identifier: language.maximalIdentifier).region?.identifier
                ?? "US"
            let code = languageCode(systemLanguage)
            let keyboard = keyboards?.keyboard(language: code, script: language.script?.identifier, region: region) ?? ""
            lines[folder] = "\(folder)|\(systemLanguage)|\(code)_\(region)|\(keyboard)"
        }
    }
    for folder in lines.keys.sorted() {
        print(lines[folder]!)
    }
}

struct RunnerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "locales" where arguments.count >= 3:
        try printLocales(
            app: URL(fileURLWithPath: arguments[1]),
            simulator: arguments[2],
            storeLocales: Array(arguments.dropFirst(3))
        )
    case "supports" where arguments.count == 3:
        guard let family = try productFamily(ofDeviceType: arguments[2]) else {
            throw RunnerError("Unknown device type \(arguments[2])")
        }
        exit(appSupports(family, at: URL(fileURLWithPath: arguments[1])) ? 0 : 1)
    default:
        throw RunnerError("Usage: simulator-info locales <app> <udid> <store locale>... | supports <app> <device type>")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
