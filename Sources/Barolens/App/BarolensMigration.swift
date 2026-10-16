import Foundation

/// One-time compatibility with installations created before the product rename.
/// Legacy names are confined here; new settings and exports use the new identity.
enum BarolensMigration {
    static let currentBundleIdentifier = "dev.local.barolens"
    static let legacyBundleIdentifier = "dev.local.lens"
    static let legacyExportDirectoryName = "Lens"
    static let legacyWindowFrameKey = "NSWindow Frame LensSettingsWindow"
    private static let marker = "barolens.preferencesMigrationVersion"

    static func migratePreferences(in defaults: UserDefaults = .standard,
                                   from previousDomain: String = legacyBundleIdentifier,
                                   to currentDomain: String = currentBundleIdentifier) {
        var current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[marker] == nil,
              let previous = defaults.persistentDomain(forName: previousDomain) else { return }
        let renamedKeys = [
            legacyWindowFrameKey: "NSWindow Frame BarolensSettingsWindow",
            "NSToolbar Configuration LensActions": "NSToolbar Configuration BarolensActions",
            "NSToolbar Configuration LensSettingsToolbar": "NSToolbar Configuration BarolensSettingsToolbar"
        ]
        for (key, value) in previous {
            let destination = renamedKeys[key] ?? key
            if current[destination] == nil { current[destination] = value }
        }
        current[marker] = 1
        defaults.setPersistentDomain(current, forName: currentDomain)
    }

    static func defaultExportDirectory(in pictures: URL) -> URL {
        let destination = pictures.appendingPathComponent("Barolens", isDirectory: true)
        let previous = pictures.appendingPathComponent(legacyExportDirectoryName, isDirectory: true)
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard !files.fileExists(atPath: destination.path),
              files.fileExists(atPath: previous.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? previous.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return destination
        }
        do {
            try files.moveItem(at: previous, to: destination)
            return destination
        } catch {
            // Keep existing exports reachable if the directory cannot be renamed.
            return previous
        }
    }
}
