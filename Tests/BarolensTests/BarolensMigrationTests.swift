import Foundation
import Testing
@testable import Barolens

@Test func preferencesMigrationPreservesChoicesBookmarksAndOriginalDomain() throws {
    let previous = "BarolensMigrationTests.previous.\(UUID())"
    let current = "BarolensMigrationTests.current.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: current))
    defer {
        defaults.removePersistentDomain(forName: previous)
        defaults.removePersistentDomain(forName: current)
    }
    let bookmark = Data([1, 2, 3, 4])
    defaults.setPersistentDomain([
        "source": "ja", "target": "ko", "onboardingCompleted": true,
        "exportDirectoryBookmark": bookmark,
        BarolensMigration.legacyWindowFrameKey: "10 20 640 480 0 0 1920 1080"
    ], forName: previous)
    defaults.setPersistentDomain(["source": "en"], forName: current)
    BarolensMigration.migratePreferences(in: defaults, from: previous, to: current)
    let migrated = try #require(defaults.persistentDomain(forName: current))
    #expect(migrated["source"] as? String == "en")
    #expect(migrated["target"] as? String == "ko")
    #expect(migrated["onboardingCompleted"] as? Bool == true)
    #expect(migrated["exportDirectoryBookmark"] as? Data == bookmark)
    #expect(migrated["NSWindow Frame BarolensSettingsWindow"] as? String == "10 20 640 480 0 0 1920 1080")
    #expect(migrated[BarolensMigration.legacyWindowFrameKey] == nil)
    #expect(defaults.persistentDomain(forName: previous)?["source"] as? String == "ja")
    defaults.setPersistentDomain(["target": "fr"], forName: previous)
    BarolensMigration.migratePreferences(in: defaults, from: previous, to: current)
    #expect(defaults.persistentDomain(forName: current)?["target"] as? String == "ko")
}

@Test func defaultExportMigrationNeverMergesOrOverwritesExistingFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarolensMigrationTests-\(UUID())")
    let previous = root.appendingPathComponent(BarolensMigration.legacyExportDirectoryName, isDirectory: true)
    let current = root.appendingPathComponent("Barolens", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
    try Data([1]).write(to: previous.appendingPathComponent("same.png"))
    try Data([2]).write(to: current.appendingPathComponent("same.png"))
    #expect(BarolensMigration.defaultExportDirectory(in: root) == current)
    #expect(try Data(contentsOf: previous.appendingPathComponent("same.png")) == Data([1]))
    #expect(try Data(contentsOf: current.appendingPathComponent("same.png")) == Data([2]))
}

@Test @MainActor func migratedBookmarkResolvesAfterDefaultFolderRename() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BarolensBookmarkMigration-\(UUID())", isDirectory: true).resolvingSymlinksInPath()
    let previous = "BarolensMigrationTests.bookmark.previous.\(UUID())"
    let current = "BarolensMigrationTests.bookmark.current.\(UUID())"
    let oldDefaults = try #require(UserDefaults(suiteName: previous))
    let newDefaults = try #require(UserDefaults(suiteName: current))
    defer {
        oldDefaults.removePersistentDomain(forName: previous)
        newDefaults.removePersistentDomain(forName: current)
        try? FileManager.default.removeItem(at: root)
    }
    let oldFolder = root.appendingPathComponent(BarolensMigration.legacyExportDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
    let oldStore = BarolensExportStore(defaults: oldDefaults, defaultDirectory: oldFolder)
    try oldStore.selectDirectory(oldFolder)
    let existing = try oldStore.saveImage(Data([9, 8, 7]))
    BarolensMigration.migratePreferences(in: newDefaults, from: previous, to: current)
    let renamed = BarolensMigration.defaultExportDirectory(in: root).resolvingSymlinksInPath()
    let newStore = BarolensExportStore(defaults: newDefaults, defaultDirectory: renamed)
    #expect(try newStore.preparedDirectory().resolvingSymlinksInPath().path == renamed.path)
    #expect(try Data(contentsOf: renamed.appendingPathComponent(existing.lastPathComponent)) == Data([9, 8, 7]))
    let savedPath = try #require(newDefaults.string(forKey: "exportDirectoryPath"))
    #expect(URL(fileURLWithPath: savedPath).resolvingSymlinksInPath().path == renamed.path)
}
