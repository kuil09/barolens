import AppKit
import Combine
import CoreImage

@MainActor
final class BarolensModel: ObservableObject {
    @Published var source: BarolensLanguage? {
        didSet {
            guard source != oldValue else { return }
            defaults.set(source?.rawValue, forKey: "source"); settingsChanged()
        }
    }
    @Published var targetPreference: BarolensLanguage? {
        didSet {
            guard targetPreference != oldValue else { return }
            defaults.set(targetPreference?.rawValue, forKey: "target")
            applyLanguagePreferences()
            settingsChanged()
            if !changingLanguagePair { refreshLanguageRoutes() }
        }
    }
    @Published private(set) var target: BarolensLanguage
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity"); surface?.overlay.maskOpacity = opacity } }
    @Published var responsiveness: TranslationResponsiveness {
        didSet {
            guard responsiveness != oldValue else { return }
            defaults.set(responsiveness.rawValue, forKey: TranslationResponsiveness.preferenceKey)
            pipeline.setResponsiveness(responsiveness)
        }
    }
    @Published var locked = false { didSet { surface?.overlay.interactionEnabled = !locked } }
    @Published var status = L10n.text("Prepare language packs before starting.")
    @Published var running = false { didSet { surface?.setTranslationActive(running) } }
    @Published var permissionNeeded = false
    @Published var hasFrame = false
    @Published var translations: [DisplayTranslation] = []
    @Published var metrics = L10n.text("Waiting for measurements")
    @Published private(set) var readiness: TranslationReadiness = .checking
    @Published var startRequest = TranslationStartRequest()
    var onRestart: (() -> Void)?
    var onRegionInvalidated: (() -> Void)?
    var onRecordingFrame: ((RecordingFrame) -> Void)?
    var onRecordingObservation: ((RecordingObservation) -> Void)?
    var onRecordingTranslation: ((RecordingTranslation) -> Void)?
    private(set) var latestRecordingFrame: RecordingFrame?
    func setRecordingActive(_ active: Bool) { pipeline.setRecordingActive(active) }
    weak var surface: BarolensSurface?
    let capture = ScreenCapture()
    let languages: LanguageCatalog
    let reading = TranslationReading()
    private let translator: any TranslationEngine
    private lazy var pipeline = RegionalTranslationPipeline(translator: translator)
    private let defaults: UserDefaults
    private let preferredLanguages: @MainActor () -> [String]
    private var languageRefresh: Task<Void, Never>?
    private var gate = ResultGate()
    private var renderSamples = LatencySamples()
    private var translationSamples = LatencySamples()
    private var lastMetricUpdate: Double = 0
    private var changingLanguagePair = false
    private var refreshGeneration = UUID()
    private(set) var frameCount = 0
    var recognitionCount: Int { pipeline.diagnostics.ocrRequests }

    init(translator: (any TranslationEngine)? = nil, defaults: UserDefaults = .standard,
         languages: LanguageCatalog? = nil, preferredLanguages: @escaping @MainActor () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.languages = languages ?? LanguageCatalog()
        self.preferredLanguages = preferredLanguages
        self.translator = translator ?? AppleTranslationEngine()
        let savedSource = defaults.string(forKey: "source")
        source = savedSource.flatMap { ["auto", "automatic", "system"].contains($0.lowercased()) ? nil : BarolensLanguage(rawValue: $0) }
        let savedTarget = defaults.string(forKey: "target").flatMap(BarolensLanguage.init(rawValue:))
        targetPreference = savedTarget
        target = savedTarget ?? preferredLanguages().first.flatMap(BarolensLanguage.init(rawValue:)) ?? .english
        opacity = defaults.object(forKey: "opacity") as? Double ?? 1
        responsiveness = TranslationResponsiveness.load(from: defaults)
        pipeline.setResponsiveness(responsiveness)
        pipeline.onDisplay = { [weak self] display in
            self?.translations = display; self?.surface?.overlay.translations = display
        }
        pipeline.onReading = { [weak self] sources, epoch in self?.reading.receive(sources, epoch: epoch) }
        pipeline.onRecordingObservation = { [weak self] in self?.onRecordingObservation?($0) }
        pipeline.onRecordingTranslation = { [weak self] in self?.onRecordingTranslation?($0) }
        pipeline.onStatus = { [weak self] status in self?.status = status }
        pipeline.onLatency = { [weak self] elapsed in
            self?.translationSamples.append(elapsed); self?.updateMetrics()
        }
        capture.onFrame = { [weak self] in self?.receive($0) }
        capture.onFailure = { [weak self] error, version in
            // The old stream can fail during the debounce before a move connects its replacement.
            guard let self, running, version == regionVersion else { return }
            suspend()
            status = L10n.text("Capture stopped: %1$@ · Start again to retry.", error)
        }
    }
    var regionVersion: UInt64 { gate.version.region }
    var selectableSources: [BarolensLanguage] { languages.installedSources(to: target) }
    var sourceChoices: [BarolensLanguage] {
        guard let source, !selectableSources.contains(source) else { return selectableSources }
        return [source] + selectableSources.filter { !$0.isSameLanguage(as: source) }
    }
    func isSourceInstalled(_ source: BarolensLanguage) -> Bool { selectableSources.contains { $0.isSameLanguage(as: source) } }
    var canTranslate: Bool {
        readiness == .ready
    }
    private var hasInstalledSelection: Bool {
        guard languages.installedTargets.contains(target) else { return false }
        guard let source else { return false }
        return isSourceInstalled(source)
    }
    var systemTarget: BarolensLanguage {
        BarolensLanguage.systemDefault(preferred: preferredLanguages(), supported: languages.installedTargets)
    }
    var canSwapLanguages: Bool {
        guard let source, !source.isSameLanguage(as: target) else { return false }
        return languages.sourceLanguages.contains { $0.isSameLanguage(as: target) }
            && languages.installedTargets.contains { $0.isSameLanguage(as: source) }
    }
    func swapLanguages() {
        guard canSwapLanguages, let previousSource = source else { return }
        changingLanguagePair = true
        source = target
        targetPreference = previousSource
        changingLanguagePair = false
        settingsChanged()
        refreshLanguageRoutes()
    }
    func prepareLanguageCheck() { readiness = .checking }
    func refreshLanguages() async {
        let token = UUID(); refreshGeneration = token
        readiness = .checking
        languageRefresh?.cancel()
        let previousSources = selectableSources
        await languages.load()
        guard refreshGeneration == token, !Task.isCancelled else { return }
        if let error = languages.error { readiness = .failed(error); return }
        let oldTarget = target
        let oldSource = source
        changingLanguagePair = true
        applyLanguagePreferences()
        changingLanguagePair = false
        await languages.refresh(target: target)
        guard refreshGeneration == token, !Task.isCancelled else { return }
        if let error = languages.error { readiness = .failed(error); return }
        changingLanguagePair = true
        reconcileSource()
        changingLanguagePair = false
        readiness = hasInstalledSelection ? .ready : .missing
        if running && !canTranslate { suspend() }
        else if running {
            if previousSources != selectableSources || oldTarget != target || oldSource != source {
                onRegionInvalidated?(); pipeline.reset()
            }
            translateLatestFrame()
        }
    }
    private func applyLanguagePreferences() {
        guard languages.hasLoaded else { return }
        if let preference = targetPreference {
            if let installed = BarolensLanguage.match(preference.rawValue, in: languages.installedTargets) { target = installed }
            else { targetPreference = nil }
        } else {
            target = systemTarget
        }
    }
    private func refreshLanguageRoutes() {
        let token = UUID(); refreshGeneration = token
        readiness = .checking
        languageRefresh?.cancel()
        languageRefresh = Task { [weak self] in
            guard let self else { return }
            await languages.refresh(target: target)
            guard refreshGeneration == token, !Task.isCancelled else { return }
            changingLanguagePair = true
            reconcileSource()
            changingLanguagePair = false
            readiness = languages.error.map { .failed($0) } ?? (hasInstalledSelection ? .ready : .missing)
            if running && !canTranslate { suspend() }
            else { translateLatestFrame() }
        }
    }
    private func reconcileSource() {
        // Missing packs must not erase an explicit preference or silently enable detection.
        guard source == nil, !selectableSources.isEmpty else { return }
        source = BarolensLanguage.systemDefault(preferred: preferredLanguages(), supported: selectableSources)
    }
    func attach(_ view: BarolensSurface) {
        surface = view; view.setTranslationActive(running); view.overlay.maskOpacity = opacity
        view.overlay.interactionEnabled = !locked
        view.canvas.onPresented = { [weak self] latency in self?.renderSamples.append(latency); self?.updateMetrics() }
    }
    func invalidate() {
        onRegionInvalidated?()
        hasFrame = false
        latestRecordingFrame = nil
        gate.regionChanged(); pipeline.reset()
        surface?.overlay.resetTransitions()
        translations = []; surface?.overlay.translations = []
    }
    func begin() { running = true; status = L10n.text("Connecting to the screen…") }
    func suspend() { startRequest.cancel(); running = false; hasFrame = false; invalidate(); surface?.canvas.clear(); status = L10n.text("Pause") }
    private func settingsChanged() {
        guard !changingLanguagePair else { return }
        startRequest.cancel()
        if readiness != .checking {
            readiness = languages.error.map { .failed($0) } ?? (hasInstalledSelection ? .ready : .missing)
        }
        invalidate(); if running { onRestart?() }
    }
    private func receive(_ frame: CapturedFrame) {
        guard running, frame.version == gate.version.region else { return }
        if !hasFrame { status = L10n.text("Screen connected · Waiting for text") }
        frameCount += 1; surface?.canvas.present(frame); hasFrame = true
        let recordingFrame = RecordingFrame(id: frame.id, contextID: frame.version, capturedAt: frame.capturedAt,
            buffer: frame.buffer, pointSize: surface?.bounds.size ?? CGSize(width: CVPixelBufferGetWidth(frame.buffer),
                height: CVPixelBufferGetHeight(frame.buffer)), opacity: opacity)
        latestRecordingFrame = recordingFrame
        onRecordingFrame?(recordingFrame)
        translateLatestFrame()
    }
    private func translateLatestFrame() {
        // Static screens may supply one complete frame, then only idle notifications.
        // Keep that frame while languages are checked and submit it exactly when ready.
        guard running, canTranslate, let source, let recordingFrame = latestRecordingFrame,
              recordingFrame.contextID == gate.version.region else { return }
        pipeline.receive(CIImage(cvPixelBuffer: recordingFrame.buffer),
            context: .init(source: source, target: target, languages: languages.sourceLanguages), recordingFrame: recordingFrame)
    }
    private func updateMetrics() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMetricUpdate > 1 else { return }; lastMetricUpdate = now
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f ms", $0 * 1000) } ?? "—" }
        metrics = L10n.text("Render submission p95 %1$@ · Translation p50 %2$@ / p95 %3$@", String(describing: ms(renderSamples.percentile(0.95))), String(describing: ms(translationSamples.percentile(0.5))), String(describing: ms(translationSamples.percentile(0.95))))
    }
}

enum PipelineError: LocalizedError {
    case languageNotReady
    var errorDescription: String? { L10n.text("Translation languages are not ready. Open System Language Download, then check again.") }
}
