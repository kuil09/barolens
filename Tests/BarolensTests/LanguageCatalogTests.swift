import Foundation
import Testing
@testable import Barolens

private let french = BarolensLanguage(rawValue: "fr")!
@MainActor private final class RefreshDelay { var enabled = false }

@Test func systemLanguageMatchingPreservesScriptsAndPreferredOrder() throws {
    let simplified = BarolensLanguage(rawValue: "zh-Hans")!
    let traditional = BarolensLanguage(rawValue: "zh-Hant")!
    let languages: [BarolensLanguage] = [.english, .korean, french, simplified, traditional]
    #expect(BarolensLanguage.systemDefault(preferred: ["fr-CA", "ko-KR"], supported: languages) == french)
    #expect(BarolensLanguage.systemDefault(preferred: ["zz", "ko-KR"], supported: languages) == .korean)
    #expect(BarolensLanguage.systemDefault(preferred: ["zz"], supported: languages) == .english)
    #expect(BarolensLanguage.match("zh-TW", in: languages) == traditional)
    #expect(BarolensLanguage.match("zh-CN", in: languages) == simplified)
    #expect(BarolensLanguage.match("zh-TW", in: [simplified]) == nil)
    #expect(BarolensLanguage(rawValue: "en-GB")!.isSameLanguage(as: .english))
    #expect(!simplified.isSameLanguage(as: traditional))
    let data = try JSONEncoder().encode(french)
    #expect(String(decoding: data, as: UTF8.self) == "\"fr\"")
    #expect(try JSONDecoder().decode(BarolensLanguage.self, from: data) == french)
}

@Test @MainActor func catalogSeparatesTranslationTargetsFromOCRSourcesAndPairStatus() async {
    let hindi = BarolensLanguage(rawValue: "hi")!
    let catalog = LanguageCatalog(languageLoader: { [.english, french, hindi, .korean] },
        recognitionLoader: { ["en-US", "fr-FR", "ko-KR"] }, routeResolver: { pair in
            TranslationRoute(status: pair.source == french ? .installed : .supported, strategy: .highFidelity)
        })
    await catalog.load()
    await catalog.refresh(target: .korean)
    #expect(catalog.languages.contains(hindi))
    #expect(!catalog.sourceLanguages.contains(hindi))
    #expect(catalog.sourceLanguages.contains(french))
    #expect(catalog.route(from: french, to: .korean)?.status == .installed)
    #expect(catalog.route(from: french, to: .english) == nil)
    #expect(catalog.route(from: .korean, to: .korean) == nil)
}

@Test @MainActor func targetPreferenceDefaultsToOSAndPreservesExplicitChoice() async throws {
    let suite = "BarolensLanguageTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let catalog = LanguageCatalog(languageLoader: { [.english, french, .japanese, .korean] },
        recognitionLoader: { ["en-US", "fr-FR", "ja-JP", "ko-KR"] },
        routeResolver: { _ in TranslationRoute(status: .installed, strategy: .lowLatency) })
    let model = BarolensModel(defaults: defaults, languages: catalog, preferredLanguages: { ["fr-CA"] })
    await model.refreshLanguages()
    #expect(model.target == french)
    #expect(model.targetPreference == nil)
    #expect(defaults.string(forKey: "target") == nil)
    model.targetPreference = .japanese
    #expect(model.target == .japanese)
    #expect(defaults.string(forKey: "target") == "ja")
    let restored = BarolensModel(defaults: defaults, languages: catalog, preferredLanguages: { ["fr-CA"] })
    #expect(restored.target == .japanese)
    var invalidations = 0
    model.onRegionInvalidated = { invalidations += 1 }
    model.targetPreference = nil
    #expect(model.target == french)
    #expect(invalidations == 1)
    #expect(defaults.string(forKey: "target") == nil)
}

@Test @MainActor func outdatedCatalogRefreshCannotPublishAfterTargetChange() async {
    var entered: CheckedContinuation<Void, Never>?
    var response: CheckedContinuation<Void, Never>?
    let delay = RefreshDelay()
    let catalog = LanguageCatalog(languageLoader: { [.english, french, .korean] }, recognitionLoader: { ["en-US"] },
        routeResolver: { pair in
            if delay.enabled && pair.target == french {
                await withCheckedContinuation { continuation in
                    response = continuation; entered?.resume(); entered = nil
                }
            }
            return TranslationRoute(status: .installed, strategy: .lowLatency)
        })
    await catalog.load()
    delay.enabled = true
    let first = Task { await catalog.refresh(target: french) }
    await withCheckedContinuation { continuation in
        if response != nil { continuation.resume() } else { entered = continuation }
    }
    await catalog.refresh(target: .korean)
    response?.resume()
    await first.value
    #expect(catalog.checkedTarget == .korean)
    #expect(catalog.route(from: french, to: .korean)?.status == .installed)
    #expect(!catalog.loading)
}

@MainActor private final class StrategySession: TranslationBatchSession {
    let strategy: TranslationCacheStrategy
    init(_ strategy: TranslationCacheStrategy) { self.strategy = strategy }
    func translate(_ texts: [String]) async throws -> [String] { texts.map { "\(strategy):\($0)" } }
    func cancel() {}
}

@MainActor private final class SelectedStrategy {
    var value: TranslationCacheStrategy = .highFidelity
}

@Test @MainActor func engineRoutesAndCachesInstalledModelsWithoutCrossStrategyLeakage() async throws {
    let selected = SelectedStrategy()
    var factories: [TranslationCacheStrategy] = []
    let engine = AppleTranslationEngine(routeResolver: { _ in .init(status: .installed, strategy: selected.value) },
        sessionFactory: { _, strategy in factories.append(strategy); return StrategySession(strategy) })
    let input = TranslationInput(id: UUID(), text: "Bonjour le monde", source: french, target: .korean)
    #expect(try await engine.translate([input]).first?.text == "highFidelity:Bonjour le monde")
    selected.value = .lowLatency
    #expect(try await engine.translate([input]).first?.text == "lowLatency:Bonjour le monde")
    #expect(factories == [.highFidelity, .lowLatency])
    let missing = AppleTranslationEngine(routeResolver: { _ in .init(status: .supported, strategy: .lowLatency) },
        sessionFactory: { _, _ in Issue.record("Uninstalled model must not be created"); return StrategySession(.lowLatency) })
    await #expect(throws: (any Error).self) { try await missing.translate([input]) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["BAROLENS_TEST_INSTALLED_LANGUAGES"] == "1"))
@MainActor func installedMultilingualModelsTranslateSyntheticSamples() async throws {
    let engine = AppleTranslationEngine()
    let samples: [(BarolensLanguage, BarolensLanguage, String)] = [
        (.english, .korean, "Do not delete these 3 files."),
        (.japanese, .korean, "会議は午後2時30分に始まります。"),
        (.korean, .english, "이 파일 3개를 삭제하지 마세요."),
        (.korean, .japanese, "회의는 오후 2시 30분에 시작합니다."),
        (.english, .japanese, "Do not delete these 3 files."),
        (.japanese, .english, "この3つのファイルを削除しないでください。")
    ]
    for (source, target, text) in samples {
        #expect(await engine.availability(source: source, target: target) == .installed)
        let outputs = try await engine.translate([TranslationInput(id: UUID(), text: text, source: source, target: target)])
        let translated = try #require(outputs.first?.text)
        #expect(!translated.isEmpty && translated != text)
        print("INSTALLED_TRANSLATION \(source.rawValue)->\(target.rawValue): \(translated)")
    }
}
