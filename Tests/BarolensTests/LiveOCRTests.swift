import AppKit
import Testing
@testable import Barolens

@Test(arguments: ["HiraginoSans-W3", "HiraginoSans-W6"])
@MainActor func visionRecognizesThreeLanguagesInRenderedImage(japaneseFontName: String) async throws {
    // A system-font CJK fallback is not a stable Japanese fixture across macOS releases.
    // At the same size, the macOS 27 fallback made Vision read 変更 as 恋更 on the
    // unchanged beta.10 baseline. Use native Japanese glyphs, keeping every original
    // assertion and additionally checking the complete Japanese sentence at two weights.
    let japaneseFont = try #require(NSFont(name: japaneseFontName, size: 32))
    let context = try #require(CGContext(data: nil, width: 1400, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1400, height: 360))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let lines = ["Please save your changes before closing this window.", "변경 사항을 저장한 후에 창을 닫아 주세요.", "変更を保存してからウィンドウを閉じてください。"]
    for (i, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 30, y: 280 - i * 100), withAttributes: [.font: i == 2 ? japaneseFont : NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(context.makeImage())
    let blocks = try await OCRService().recognize(image, source: nil)
    #expect(Set(blocks.compactMap(\.language)) == Set(TranslationBenchmark.languages))
    #expect(blocks.contains { $0.text.contains("save your changes") })
    #expect(blocks.contains { $0.text.contains("변경") && $0.text.contains("저장") })
    #expect(blocks.contains { $0.text.contains("変更") && $0.text.contains("保存") })
    #expect(blocks.contains { $0.text == lines[2] })
}

@Test @MainActor func visionRecognizesFrenchGermanAndChineseWithoutThreeLanguageRestriction() async throws {
    let context = try #require(CGContext(data: nil, width: 1800, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1800, height: 360))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let lines = ["Veuillez enregistrer les modifications avant de fermer cette fenêtre.",
                 "Bitte speichern Sie Ihre Änderungen, bevor Sie dieses Fenster schließen.",
                 "请保存所有修改，然后再关闭这个窗口。"]
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 30, y: 280 - index * 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    let languages = ["fr", "de", "zh"].compactMap(BarolensLanguage.init(rawValue:))
    let blocks = try await OCRService().recognize(#require(context.makeImage()), source: nil, languages: languages)
    #expect(Set(blocks.compactMap { $0.language?.languageCode }) == ["fr", "de", "zh"])
    #expect(blocks.contains { $0.text.contains("enregistrer") })
    #expect(blocks.contains { $0.text.contains("speichern") })
    #expect(blocks.contains { $0.text.contains("保存") })
}

@Test @MainActor func visionRecognizesMixedEnglishAndKoreanOnOneBaseline() async throws {
    let context = try #require(CGContext(data: nil, width: 1900, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1900, height: 240))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    // One tightly spaced text run, not independently rendered labels on separate lines.
    let line = "Save your changes before closing. 변경 사항을 저장한 후에 창을 닫아 주세요."
    (line as NSString).draw(at: CGPoint(x: 30, y: 90),
        withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()

    let blocks = try await OCRService().recognize(#require(context.makeImage()),
                                                   source: .english, languages: [.english, .korean])
    let english = try #require(blocks.first { $0.language == .english && $0.text.contains("your changes") },
                               "Recognized: \(blocks.map(\.text))")
    let korean = try #require(blocks.first { $0.language == .korean && $0.text.contains("저장") },
                              "Recognized: \(blocks.map(\.text))")
    #expect(english.bounds.midX < korean.bounds.midX)
    #expect(english.bounds.intersection(korean.bounds).width < 0.01)
    let pipelineContext = RegionalTranslationPipeline.Context(source: .english, target: .japanese,
        languages: [.english, .korean, .japanese])
    #expect(RegionalTranslationPipeline.accepts(english, in: pipelineContext))
    #expect(!RegionalTranslationPipeline.accepts(korean, in: pipelineContext))
}

@Test @MainActor func visionKeepsTraditionalChineseMarketProseWithInlineTickers() async throws {
    let context = try #require(CGContext(data: nil, width: 1400, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let font = try #require(NSFont(name: "PingFangTC-Regular", size: 32))
    let source = try #require(BarolensLanguage(rawValue: "zh-TW"))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1400, height: 360))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let rows = [
        "市場關注聯準會（Fed）利率決策，AI族群跌幅擴大，",
        "同時那斯達克指數下跌356.02點，標普S&P 500指數則下跌36.",
        "08點，或0.50%。"
    ]
    for (i, line) in rows.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 30, y: 265 - i * 38),
            withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
    NSGraphicsContext.restoreGraphicsState()
    let blocks = try await OCRService().recognize(#require(context.makeImage()),
        source: source, languages: [source, .korean, .english, .japanese])
    let tc = RegionalTranslationPipeline.Context(source: source, target: .korean, languages: [source, .korean, .english, .japanese])
    let accepted = blocks.filter { RegionalTranslationPipeline.accepts($0, in: tc) }
    let combined = accepted.map(\.translationText).joined(separator: "\n")
    #expect(combined.contains("聯準會") && combined.contains("Fed") && (combined.contains("AI") || combined.contains("Al")), "OCR: \(blocks.map { ($0.text, $0.language?.rawValue) })")
    #expect(combined.contains("那斯達克") && combined.contains("S&P") && combined.contains("356.02"))
    #expect(combined.contains("36.08") && combined.contains("0.50"))
}
