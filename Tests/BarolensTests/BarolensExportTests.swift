import AppKit
import Testing
@testable import Barolens

@MainActor private struct ExportFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "BarolensExportTests.\(UUID().uuidString)"
    let store: BarolensExportStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BarolensExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defaults = UserDefaults(suiteName: suite)!
        store = BarolensExportStore(defaults: defaults, defaultDirectory: root.appendingPathComponent("Default"))
    }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test @MainActor func renamedAppMovesDefaultExportsWithoutLosingFiles() throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let fresh = BarolensExportStore.preferredDefaultDirectory(in: fixture.root)
    #expect(fresh.lastPathComponent == "Barolens")
    #expect(!FileManager.default.fileExists(atPath: fresh.path))
    let legacy = try fixture.folder(BarolensMigration.legacyExportDirectoryName)
    let existing = legacy.appendingPathComponent("existing.png")
    try Data([1, 2, 3]).write(to: existing)
    #expect(BarolensExportStore.preferredDefaultDirectory(in: fixture.root) == fresh)
    #expect(try Data(contentsOf: fresh.appendingPathComponent(existing.lastPathComponent)) == Data([1, 2, 3]))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
}

@Test @MainActor func automaticImagesAccumulateWithoutOverwritingAtTheSameTimestamp() throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let store = fixture.store
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try store.saveImage(Data("first".utf8), at: date)
    let second = try store.saveImage(Data("second".utf8), at: date)
    let third = try store.saveImage(Data("third".utf8), at: date)
    #expect(Set([first, second, third]).count == 3)
    #expect(first.pathExtension == "png" && first.lastPathComponent.hasPrefix("barolens-Image-"))
    #expect(second.lastPathComponent.hasSuffix("-2.png"))
    #expect(try Data(contentsOf: first) == Data("first".utf8))
    #expect(try Data(contentsOf: second) == Data("second".utf8))
    #expect(store.lastSavedURL == third)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 3)
}

@Test @MainActor func selectedFolderPersistsAndMissingFolderDoesNotSilentlyFallBack() throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let chosen = try fixture.folder("Selected")
    try fixture.store.selectDirectory(chosen)
    let restored = BarolensExportStore(defaults: fixture.defaults, defaultDirectory: fixture.root.appendingPathComponent("Unused"))
    #expect(restored.directory.resolvingSymlinksInPath() == chosen.resolvingSymlinksInPath())
    #expect(restored.lastSavedURL == nil)
    let saved = try restored.saveImage(Data([1, 2, 3]))
    #expect(saved.deletingLastPathComponent().resolvingSymlinksInPath() == chosen.resolvingSymlinksInPath())
    try FileManager.default.removeItem(at: chosen)
    #expect(throws: ExportError.self) { try restored.saveImage(Data([4])) }
    #expect(!FileManager.default.fileExists(atPath: chosen.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Unused").path))
}

@Test @MainActor func invalidFolderAndDamagedBookmarkRequireReselection() throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let file = fixture.root.appendingPathComponent("not-a-folder")
    try Data([1]).write(to: file)
    #expect(throws: ExportError.self) { try fixture.store.selectDirectory(file) }
    fixture.defaults.set(Data([0, 1, 2]), forKey: "exportDirectoryBookmark")
    fixture.defaults.set(file.path, forKey: "exportDirectoryPath")
    let restored = BarolensExportStore(defaults: fixture.defaults, defaultDirectory: fixture.root.appendingPathComponent("Unused"))
    #expect(throws: ExportError.self) { try restored.videoDestination() }
    let chosen = try fixture.folder("Recovered")
    try restored.selectDirectory(chosen)
    #expect(try restored.preparedDirectory() == chosen)
}

@Test @MainActor func readOnlyFolderFailsWithoutCreatingAnExport() throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let folder = try fixture.folder("ReadOnly")
    try fixture.store.selectDirectory(folder)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    #expect(throws: ExportError.self) { try fixture.store.saveImage(Data([1])) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    #expect(fixture.store.lastSavedURL == nil)
}

@Test @MainActor func changingFolderDuringRecordingOnlyAffectsTheNextExport() async throws {
    let fixture = try ExportFixture()
    defer { fixture.close() }
    let firstFolder = try fixture.folder("First")
    let nextFolder = try fixture.folder("Next")
    try fixture.store.selectDirectory(firstFolder)
    let recording = BarolensRecording()
    recording.onSaved = { fixture.store.didSave($0) }
    var failures: [String] = []
    recording.onError = { failures.append($0) }
    let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let destination = try fixture.store.videoDestination()
    try recording.start(destination: destination, firstFrame: image, frame: { image })
    try fixture.store.selectDirectory(nextFolder)
    let finish = try #require(recording.stop())
    await finish.value
    #expect(failures.isEmpty)
    #expect(fixture.store.lastSavedURL?.deletingLastPathComponent() == firstFolder)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let screenshot = try fixture.store.saveImage(Data([1, 2]))
    #expect(screenshot.deletingLastPathComponent() == nextFolder)
    #expect(try fixture.store.videoDestination().deletingLastPathComponent() == nextFolder)
}

@Test func exclusivePublicationPreservesFilesCreatedAfterRecordingStarts() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BarolensPublicationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let proposed = folder.appendingPathComponent("video.mp4")
    let temporary = folder.appendingPathComponent("partial.mp4")
    try Data("completed video".utf8).write(to: temporary)
    try Data("unrelated file".utf8).write(to: proposed)
    let actual = try BarolensExportFiles.publish(temporary, to: proposed)
    #expect(actual.lastPathComponent == "video-2.mp4")
    #expect(try Data(contentsOf: proposed) == Data("unrelated file".utf8))
    #expect(try Data(contentsOf: actual) == Data("completed video".utf8))
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
}

@Suite @MainActor struct BarolensExportFolderTests {
    @Test func missingDefaultIsCreatedBeforeOpening() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let directory = fixture.store.directory
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        var opened: [URL] = []
        try fixture.store.openDirectory { url in
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.isWritableFile(atPath: url.path))
            opened.append(url)
            return true
        }
        #expect(opened == [directory])
        #expect(fixture.store.lastSavedURL == nil)
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == nil)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == nil)
    }

    @Test func selectionChangeIsImmediateAndLastSavedFileIsIgnored() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let first = try fixture.folder("First")
        let next = try fixture.folder("Next")
        try fixture.store.selectDirectory(first)
        let saved = try fixture.store.saveImage(Data([1]))
        var opened: [URL] = []
        try fixture.store.openDirectory { opened.append($0); return true }
        try fixture.store.selectDirectory(next)
        try fixture.store.openDirectory { opened.append($0); return true }
        #expect(opened == [first, next])
        #expect(fixture.store.lastSavedURL == saved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: next.path).isEmpty)
    }

    @Test func restoredBookmarkOpensSelectedDirectory() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let selected = try fixture.folder("Selected")
        try fixture.store.selectDirectory(selected)
        let fallback = fixture.root.appendingPathComponent("Unused")
        let restored = BarolensExportStore(defaults: fixture.defaults, defaultDirectory: fallback)
        var opened: [URL] = []
        try restored.openDirectory { opened.append($0.resolvingSymlinksInPath()); return true }
        #expect(opened == [selected.resolvingSymlinksInPath()])
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
    }

    @Test(arguments: [false, true]) func deletedCustomFolderIsNotRecreatedOrReplaced(reload: Bool) throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let fallback = fixture.store.directory
        let selected = try fixture.folder("Selected")
        try fixture.store.selectDirectory(selected)
        let bookmark = fixture.defaults.data(forKey: "exportDirectoryBookmark")
        try FileManager.default.removeItem(at: selected)
        let store = reload ? BarolensExportStore(defaults: fixture.defaults, defaultDirectory: fallback) : fixture.store
        expectUnavailable(store)
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == bookmark)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == selected.path)
    }

    @Test(arguments: [false, true]) func invalidBookmarkNeverFallsBackToPreferencesOrDefault(hasSavedPath: Bool) throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let fallback = fixture.store.directory
        let validFolder = try fixture.folder("ValidButUnresolved")
        let damaged = Data([0, 1, 2])
        fixture.defaults.set(damaged, forKey: "exportDirectoryBookmark")
        if hasSavedPath { fixture.defaults.set(validFolder.path, forKey: "exportDirectoryPath") }
        let restored = BarolensExportStore(defaults: fixture.defaults, defaultDirectory: fallback)
        expectUnavailable(restored)
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: validFolder.path).isEmpty)
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == damaged)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == (hasSavedPath ? validFolder.path : nil))
    }

    @Test func customFolderReplacedByFileIsPreserved() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let fallback = fixture.store.directory
        let selected = try fixture.folder("Selected")
        try fixture.store.selectDirectory(selected)
        let bookmark = fixture.defaults.data(forKey: "exportDirectoryBookmark")
        try FileManager.default.removeItem(at: selected)
        let contents = Data("unrelated file".utf8)
        try contents.write(to: selected)
        expectUnavailable(fixture.store)
        #expect(try Data(contentsOf: selected) == contents)
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == bookmark)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == selected.path)
    }

    @Test func inaccessibleCustomFolderPreservesSelection() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let fallback = fixture.store.directory
        let selected = try fixture.folder("ReadOnly")
        try fixture.store.selectDirectory(selected)
        let bookmark = fixture.defaults.data(forKey: "exportDirectoryBookmark")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: selected.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path) }
        #expect(!FileManager.default.isWritableFile(atPath: selected.path))
        expectUnavailable(fixture.store)
        #expect(fixture.store.directory == selected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == bookmark)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == selected.path)
    }

    @Test func rejectedOpenThrowsActionableLocalizedErrorWithoutChangingSelection() throws {
        let fixture = try ExportFixture()
        defer { fixture.close() }
        let fallback = fixture.store.directory
        let selected = try fixture.folder("Selected")
        try fixture.store.selectDirectory(selected)
        let saved = try fixture.store.saveImage(Data([1]))
        let bookmark = fixture.defaults.data(forKey: "exportDirectoryBookmark")
        var opened: [URL] = []
        do {
            try fixture.store.openDirectory { opened.append($0); return false }
            Issue.record("Expected Finder rejection to throw")
        } catch ExportError.directoryOpenFailed {
            #expect(ExportError.directoryOpenFailed.errorDescription == L10n.text(
                "Cannot open the save folder in Finder. Try again or choose a folder again in Settings → Capture."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(opened == [selected])
        #expect(fixture.store.directory == selected)
        #expect(fixture.store.lastSavedURL == saved)
        #expect(try Data(contentsOf: saved) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
        #expect(fixture.defaults.data(forKey: "exportDirectoryBookmark") == bookmark)
        #expect(fixture.defaults.string(forKey: "exportDirectoryPath") == selected.path)
    }

    private func expectUnavailable(_ store: BarolensExportStore) {
        var openCalls = 0
        do {
            try store.openDirectory { _ in openCalls += 1; return true }
            Issue.record("Expected unavailable directory to throw")
        } catch ExportError.directoryUnavailable {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(openCalls == 0)
    }
}
