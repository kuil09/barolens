import AppKit
import Combine
import CoreImage
import Testing
@testable import Barolens

@MainActor private final class StartupClock { var value = 0.0 }
@MainActor private final class StartupBarrier {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class StartupEngine: TranslationEngine {
    var requests = 0
    var availabilityCalls = 0
    var availabilityBarrier: StartupBarrier?
    var translationBarrier: StartupBarrier?
    func availability(source: BarolensLanguage, target: BarolensLanguage) async -> LanguagePairStatus {
        availabilityCalls += 1
        if availabilityCalls == 1 { await availabilityBarrier?.wait() }
        return .installed
    }
    func cancel() {}
    func translate(_ inputs: [TranslationInput]) async throws -> [TranslationOutput] {
        requests += 1
        if requests == 1 { await translationBarrier?.wait() }
        return inputs.map { .init(id: $0.id, text: "합성 번역") }
    }
}
private let startupImage = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 500))
private let startupFingerprint = FrameFingerprint(bytes: Array(repeating: 255, count: 128 * 80 * 4))
private let startupContext = RegionalTranslationPipeline.Context(source: .english, target: .korean, languages: [.english, .korean])
private func startupBlock() -> TextBlock {
    .init(text: "Please save these files before closing this window.",
          bounds: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.1), language: .english, confidence: 1)
}
@MainActor private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

@Suite(.serialized) struct StartupRecoveryTests {
    enum Stage: CaseIterable { case ocr, availability, translation }

    @Test @MainActor func singleFrameDuringLanguagePreparationTranslatesWhenReadyWithoutAnotherFrame() async throws {
        let suite = "BarolensEarlyFrame.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "source"); defaults.set("ko", forKey: "target")
        let preparation = StartupBarrier(), engine = StartupEngine()
        let catalog = LanguageCatalog(languageLoader: { await preparation.wait(); return [.english, .korean] },
            recognitionLoader: { ["en-US", "ko-KR"] }, routeResolver: { _ in .init(status: .installed, strategy: .lowLatency) })
        let model = BarolensModel(translator: engine, defaults: defaults, languages: catalog)
        let refresh = Task { await model.refreshLanguages() }
        #expect(await eventually { preparation.continuation != nil })
        model.begin()
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1200, 300, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1200, height: 300,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Please save these files before closing this window." as NSString).draw(at: CGPoint(x: 30, y: 140),
            withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState(); CVPixelBufferUnlockBaseAddress(buffer, [])
        model.capture.onFrame?(.init(buffer: buffer, version: model.regionVersion, capturedAt: 0, id: 1))
        #expect(model.frameCount == 1 && model.hasFrame && engine.requests == 0)
        preparation.release(); await refresh.value
        #expect(await eventually { !model.translations.isEmpty })
        #expect(model.frameCount == 1 && engine.requests == 1)
        model.suspend()
    }
    @Test @MainActor func rightRailContainsOneSetOfActions() {
        let controls = BarolensToolbar(onCapture: {}, onRecord: {})
        #expect(controls.buttons.count == 6)
        #expect(Set(controls.buttons.values.compactMap { $0.identifier?.rawValue }).count == 6)
    }

    @Test @MainActor func rightRailAndResizeRingStayInteractiveAtRightBoundary() throws {
        _ = NSApplication.shared
        for width: CGFloat in [320, 400, 800] {
            let panel = BarolensPanel(overlayRect: CGRect(x: 1100, y: 200, width: width, height: 300))
            panel.isReleasedWhenClosed = false
            let controls = BarolensToolbar(onCapture: {}, onRecord: {})
            controls.attach(to: panel)
            panel.installBody(surface: NSView(), size: CGSize(width: width, height: 300))
            panel.setBodyClickThrough(true)
            let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
            panel.clampPair(to: screen)
            #expect(panel.pairFrame.maxX <= 1192 && panel.pairFrame.minX >= 8)
            #expect(!panel.ignoresMouseEvents && panel.bodyPanel?.ignoresMouseEvents == true)
            #expect(panel.resizePanels.allSatisfy { !$0.ignoresMouseEvents && screen.contains($0.frame) })
            controls.update(.init(hasFrame: true, locked: true))
            #expect(controls.buttons["lock"]?.isEnabled == true)
            #expect(panel.toolbar == nil && controls.buttons.count == 6)
            panel.close()
        }
    }

    @Test @MainActor func regionalExplicitSourceIsNotReplacedByDefaultOrTreatedAsMissing() async throws {
        let suite = "BarolensRegionalSource.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en-GB", forKey: "source"); defaults.set("ko", forKey: "target")
        let catalog = LanguageCatalog(languageLoader: { [.english, .korean] }, recognitionLoader: { ["en-US", "ko-KR"] },
            routeResolver: { _ in .init(status: .installed, strategy: .lowLatency) })
        let model = BarolensModel(defaults: defaults, languages: catalog, preferredLanguages: { ["ko"] })
        await model.refreshLanguages()
        #expect(model.source?.rawValue == "en-GB" && defaults.string(forKey: "source") == "en-GB")
        #expect(model.readiness == .ready && model.sourceChoices.count == 1)
    }

    @Test @MainActor func noInstalledPairNeverEnablesAutomaticSource() async throws {
        let suite = "BarolensMissingPair.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = LanguageCatalog(languageLoader: { [.english, .korean] }, recognitionLoader: { ["en-US", "ko-KR"] },
            routeResolver: { _ in .init(status: .supported, strategy: .lowLatency) })
        let model = BarolensModel(defaults: defaults, languages: catalog)
        await model.refreshLanguages()
        #expect(model.source == nil && !model.canTranslate && model.readiness == .missing)
        #expect(model.startRequest.request(model.readiness) == .guide)
    }

    @Test(arguments: ["", "auto", "system", "automatic"])
    @MainActor func firstLaunchChoosesInstalledExplicitSourceAndKeepsStartIntent(legacy: String) async throws {
        let suite = "BarolensStartup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if !legacy.isEmpty { defaults.set(legacy, forKey: "source") }
        let catalog = LanguageCatalog(languageLoader: { [.english, .korean] }, recognitionLoader: { ["en-US", "ko-KR"] },
            routeResolver: { _ in .init(status: .installed, strategy: .lowLatency) })
        let model = BarolensModel(defaults: defaults, languages: catalog, preferredLanguages: { ["ko-KR"] })
        #expect(model.startRequest.request(.checking) == .wait)
        await model.refreshLanguages()
        #expect(model.source == .english && model.target == .korean)
        #expect(defaults.string(forKey: "source") == "en")
        #expect(model.readiness == .ready)
        #expect(model.startRequest.resolve(model.readiness) == .start)
        #expect(model.startRequest.resolve(model.readiness) == .none)
    }

    @Test @MainActor func unsupportedSavedTargetNormalizationKeepsPendingStart() async throws {
        let suite = "BarolensTargetFallback.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fr", forKey: "target")
        let catalog = LanguageCatalog(languageLoader: { [.english, .korean] }, recognitionLoader: { ["en-US", "ko-KR"] },
            routeResolver: { _ in .init(status: .installed, strategy: .lowLatency) })
        let model = BarolensModel(defaults: defaults, languages: catalog, preferredLanguages: { ["ko-KR"] })
        _ = model.startRequest.request(.checking)
        await model.refreshLanguages()
        #expect(model.source == .english && model.target == .korean)
        #expect(model.startRequest.resolve(model.readiness) == .start)
    }

    @Test(arguments: Stage.allCases) @MainActor func timedOutFirstWorkRecoversOnNextFrameWithoutToggle(stage: Stage) async throws {
        let barrier = StartupBarrier(), clock = StartupClock(), engine = StartupEngine()
        if stage == .availability { engine.availabilityBarrier = barrier }
        if stage == .translation { engine.translationBarrier = barrier }
        var ocrCalls = 0
        let pipeline = RegionalTranslationPipeline(translator: engine, now: { clock.value }, recognize: { _, _, _ in
            ocrCalls += 1
            if stage == .ocr && ocrCalls == 1 { await barrier.wait() }
            return [startupBlock()]
        }, scheduleWake: { _, _ in AnyCancellable {} }, serviceTimeout: .milliseconds(30))
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        clock.value = 0.13
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { barrier.continuation != nil })
        #expect(await eventually { pipeline.diagnostics.activeOCR == 0 && pipeline.diagnostics.activeTranslation == 0 })
        clock.value = 1
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { pipeline.display.count == 1 })
        let completedRequests = engine.requests
        barrier.release()
        try await Task.sleep(for: .milliseconds(10))
        #expect(pipeline.display.count == 1 && engine.requests == completedRequests)
        #expect(pipeline.diagnostics.maxActiveOCR == 1 && pipeline.diagnostics.maxActiveTranslation == 1)
        pipeline.reset()
    }

    @Test(arguments: [Stage.availability, .translation])
    @MainActor func cancelledTranslationStageDoesNotBlockNewGeneration(stage: Stage) async throws {
        let barrier = StartupBarrier(), clock = StartupClock(), engine = StartupEngine()
        if stage == .availability { engine.availabilityBarrier = barrier }
        else { engine.translationBarrier = barrier }
        let pipeline = RegionalTranslationPipeline(translator: engine, now: { clock.value },
            recognize: { _, _, _ in [startupBlock()] }, scheduleWake: { _, _ in AnyCancellable {} })
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        clock.value = 0.13
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { barrier.continuation != nil })
        for _ in 0..<50 { pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint) }
        #expect(engine.availabilityCalls == 1 && engine.requests == (stage == .availability ? 0 : 1))
        pipeline.reset()
        clock.value = 1
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        clock.value = 1.13
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { pipeline.display.count == 1 })
        let completedRequests = engine.requests
        barrier.release()
        try await Task.sleep(for: .milliseconds(10))
        #expect(engine.requests == completedRequests && pipeline.display.count == 1)
        #expect(pipeline.diagnostics.maxActiveTranslation == 1)
        pipeline.reset()
    }

    @Test @MainActor func completeFramesBeforeAndAfterStartAndStaleGeneration() async throws {
        let gate = CaptureFirstFrame()
        gate.reset(to: 1); gate.accept(1)
        try await gate.wait(for: 1, timeout: .milliseconds(100))
        gate.reset(to: 2)
        var connected = false
        let wait = Task { try await gate.wait(for: 2, timeout: .seconds(1)); connected = true }
        gate.accept(1)
        try await Task.sleep(for: .milliseconds(10))
        #expect(!connected)
        gate.accept(2); try await wait.value
        #expect(connected)
        gate.reset(to: 3)
        await #expect(throws: AsyncStageError.self) { try await gate.wait(for: 3, timeout: .milliseconds(20)) }
        gate.reset(to: 4)
        let cancelled = Task { try await gate.wait(for: 4) }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        gate.reset(to: 5); gate.accept(5)
        try await gate.wait(for: 5)
    }

    @Test @MainActor func unavailableSavedSourceIsPreservedAndRequiresGuidance() async throws {
        let suite = "BarolensSavedSource.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ja", forKey: "source"); defaults.set("ko", forKey: "target")
        let catalog = LanguageCatalog(languageLoader: { [.english, .japanese, .korean] }, recognitionLoader: { ["en-US", "ja-JP", "ko-KR"] },
            routeResolver: { .init(status: $0.source == .japanese ? .supported : .installed, strategy: .lowLatency) })
        let model = BarolensModel(defaults: defaults, languages: catalog)
        await model.refreshLanguages()
        #expect(model.source == .japanese && defaults.string(forKey: "source") == "ja")
        #expect(model.readiness == .missing && !model.canTranslate)
    }

    @Test @MainActor func cancelledOCRDoesNotBlockFreshFrameOrPublishLateResult() async throws {
        let barrier = StartupBarrier(), clock = StartupClock(), engine = StartupEngine()
        var calls = 0
        let pipeline = RegionalTranslationPipeline(translator: engine, now: { clock.value }, recognize: { _, _, _ in
            calls += 1
            if calls == 1 { await barrier.wait() }
            return [startupBlock()]
        }, scheduleWake: { _, _ in AnyCancellable {} })
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        clock.value = 0.13
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { barrier.continuation != nil })
        pipeline.reset()
        clock.value = 1
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        clock.value = 1.13
        pipeline.receive(startupImage, context: startupContext, fingerprint: startupFingerprint)
        #expect(await eventually { pipeline.display.count == 1 })
        #expect(engine.requests == 1 && pipeline.diagnostics.maxActiveOCR == 1)
        barrier.release()
        #expect(await eventually { pipeline.diagnostics.activeOCR == 0 })
        #expect(engine.requests == 1 && pipeline.display.count == 1)
        pipeline.reset()
    }

    @Test @MainActor func failedInitialSessionIsRecreatedForRetry() async throws {
        var factories = 0
        let engine = AppleTranslationEngine { _ in
            factories += 1
            return StartupSession(fail: factories == 1)
        }
        let input = TranslationInput(id: UUID(), text: startupBlock().text, source: .english, target: .korean)
        await #expect(throws: StartupSession.Failure.self) { try await engine.translate([input]) }
        let result = try await engine.translate([input])
        #expect(result.first?.text == "합성 번역" && factories == 2)
    }

    @Test @MainActor func delayedSessionPreparationIsSharedAndPrecedesTranslation() async throws {
        let session = PreparingStartupSession()
        var factories = 0
        let engine = AppleTranslationEngine { _ in factories += 1; return session }
        let first = Task { try await engine.translate([.init(id: UUID(), text: "First sentence.", source: .english, target: .korean)]) }
        let second = Task { try await engine.translate([.init(id: UUID(), text: "Second sentence.", source: .english, target: .korean)]) }
        #expect(await eventually { session.barrier.continuation != nil })
        #expect(session.preparations == 1 && session.requests == 0 && factories == 1)
        session.barrier.release()
        let a = try await first.value, b = try await second.value
        #expect(a.count == 1 && b.count == 1 && session.requests == 2 && session.preparations == 1)
    }

    @Test @MainActor func cancellingPreparationAllowsFreshSessionAndRejectsLatePreparedSession() async throws {
        let delayed = PreparingStartupSession()
        var factories = 0
        let engine = AppleTranslationEngine { _ -> any TranslationBatchSession in
            factories += 1
            return factories == 1 ? delayed : StartupSession(fail: false)
        }
        let input = TranslationInput(id: UUID(), text: "Please keep these files.", source: .english, target: .korean)
        let first = Task { try await engine.translate([input]) }
        #expect(await eventually { delayed.barrier.continuation != nil })
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await engine.translate([input]).first?.text == "합성 번역")
        delayed.barrier.release()
        try await Task.sleep(for: .milliseconds(10))
        #expect(delayed.requests == 0 && factories == 2)
    }
}

@MainActor private final class PreparingStartupSession: TranslationBatchSession {
    let barrier = StartupBarrier()
    var preparations = 0, requests = 0
    var ready = false
    func prepare() async throws { preparations += 1; await barrier.wait(); ready = true }
    func cancel() {}
    func translate(_ texts: [String]) async throws -> [String] {
        guard ready else { throw StartupSession.Failure.unavailable }
        requests += 1
        return texts.map { _ in "합성 번역" }
    }
}

@MainActor private final class StartupSession: TranslationBatchSession {
    enum Failure: Error { case unavailable }
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func cancel() {}
    func translate(_ texts: [String]) async throws -> [String] {
        if fail { throw Failure.unavailable }
        return texts.map { _ in "합성 번역" }
    }
}
