import Foundation

/// Move only Floe preferences from its former app identity. macOS permissions
/// deliberately remain separate and must be granted to the new identity.
enum PreferencesMigration {
    static let legacyIdentifier = "local.globetalk.app"
    static let identifier = "io.github.wanghongyang.floe"
    private static let marker = "migratedLegacyPreferences"
    private static let keys = ["useGlobe", "autoInsert", "hotwordText",
                               "hotwordsEnabled", "hotwordScore", "learnCorrections", "pasteInterval"]

    static func merged(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        var result = current
        for key in keys where result[key] == nil {
            if let value = legacy[key] { result[key] = value }
        }
        result[marker] = true
        return result
    }

    static func run() {
        guard Bundle.main.bundleIdentifier == identifier else { return }
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: identifier) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyIdentifier) ?? [:]
        defaults.setPersistentDomain(merged(legacy: legacy, current: current), forName: identifier)
    }

    static func test() -> Bool {
        let legacy: [String: Any] = ["hotwordText": "FSDP2", "pasteInterval": 0.005,
                                   "autoInsert": true, "unrelated": "do not copy"]
        let current: [String: Any] = ["autoInsert": false, "newSetting": 12]
        let result = merged(legacy: legacy, current: current)
        return result["hotwordText"] as? String == "FSDP2" &&
               result["pasteInterval"] as? Double == 0.005 &&
               result["autoInsert"] as? Bool == false &&
               result["newSetting"] as? Int == 12 &&
               result["unrelated"] == nil && result[marker] as? Bool == true
    }
}
