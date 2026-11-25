import CoreGraphics
import Testing
@testable import Barolens

private func line(_ text: String, x: CGFloat = 0.1, y: CGFloat = 0.8,
                  width: CGFloat = 0.35, language: BarolensLanguage? = .english,
                  confidence: Float = 0.9) -> TextBlock {
    TextBlock(text: text, bounds: CGRect(x: x, y: y, width: width, height: 0.03),
              language: language, confidence: confidence)
}

@Suite struct OCRTests {
@Test func recognitionLanguageValidation() throws {
    let supported = ["ko-KR", "ja-JP", "en-US", "fr-FR"]
    #expect(try OCRService.recognitionLanguages(supported: supported, source: nil) == supported)
    #expect(Set(try OCRService.recognitionLanguages(supported: supported, source: .korean)) == Set(supported))
    #expect(try OCRService.recognitionLanguages(supported: ["ja-JP"], source: .japanese) == ["ja-JP"])
    #expect(try OCRService.recognitionLanguages(supported: ["en-US"], source: nil) == ["en-US"])
    #expect(throws: OCRServiceError.unsupportedRecognitionLanguages(["ko"])) {
        try OCRService.recognitionLanguages(supported: ["en-US"], source: .korean)
    }
}

@Test func conservativeLanguageDetection() {
    #expect(OCRService.detectLanguage("설정") == .korean)
    #expect(OCRService.detectLanguage("カメラの設定") == .japanese)
    #expect(OCRService.detectLanguage("This is a complete sentence written in English.") == .english)
    for text in ["OK", "Oui", "設定", "12345", "", "Привет"] {
        #expect(OCRService.detectLanguage(text) == nil)
    }
    #expect(OCRService.detectLanguage("OK", source: .japanese) == nil)
    #expect(OCRService.detectLanguage("This is an English sentence with one 가", source: .korean) == nil)
    #expect(OCRService.detectLanguage("한국어와日本語です", source: .korean) == nil)
    #expect(OCRService.detectLanguage("Bonjour tout le monde, comment allez vous aujourd'hui?")?.languageCode == "fr")
    #expect(OCRService.detectLanguage("这是一个中文句子")?.languageCode == "zh")
    #expect(OCRService.detectLanguage("Bonjour tout le monde, comment allez vous aujourd'hui?", languages: [.english, .korean]) == nil)
}

@Test func separateStrongMixedLanguageRunsWithoutRelabelingInlineNames() {
    let adjacent = "日本語の設定を変更してください。 한국어 설정을 변경해 주세요."
    let runs = OCRService.languageRuns(in: adjacent)
    #expect(runs.map(\.language) == [.japanese, .korean])
    #expect(runs.map { String(adjacent[$0.range]) } == ["日本語の設定を変更してください。", "한국어 설정을 변경해 주세요."])

    let separated = "Bonjour tout le monde, comment allez vous aujourd'hui? | Bitte speichern Sie Ihre Änderungen vor dem Schließen."
    let labelRuns = OCRService.languageRuns(in: separated)
    #expect(labelRuns.map { $0.language.languageCode } == ["fr", "de"])
    #expect(labelRuns.allSatisfy { !separated[$0.range].contains("|") })

    #expect(OCRService.languageRuns(in: "OpenAIのアカウント設定を変更します。").isEmpty)
    #expect(OCRService.languageRuns(in: "This is an English sentence with one 가").isEmpty)
    #expect(OCRService.languageRuns(in: "한국어와日本語です").isEmpty)
}

@Test func neighboringContextIsLocalAndDoesNotGuessLatin() {
    let lines = [line("これは日本語の説明です", y: 0.8), line("設定", y: 0.75),
                 line("設定", x: 0.6, y: 0.75), line("Oui", y: 0.60), line("設定", y: 0.3)]
    let result = OCRService.assignLanguages(to: lines)
    #expect(result.map(\.language) == [.japanese, .japanese, nil, nil, nil])
    #expect(result[1].id == lines[1].id)
    // Direct Japanese context wins; isolated Han labels can use the explicitly chosen Korean source.
    #expect(OCRService.assignLanguages(to: lines, source: .korean).map(\.language) == [.japanese, .japanese, .korean, nil, .korean])
    let conflicting = [lines[0], lines[1], line("한국어 설명입니다", y: 0.70)]
    #expect(OCRService.assignLanguages(to: conflicting)[1].language == nil)
    let unknownNeighbor = [lines[0], lines[1], line("Oui", y: 0.70)]
    #expect(OCRService.assignLanguages(to: unknownNeighbor)[1].language == nil)
}

@Test func paragraphGroupingPreservesColumnsAndCoordinates() {
    let a = line("This is the first paragraph line.", y: 0.8, confidence: 0.8)
    let b = line("This is the second paragraph line.", y: 0.76)
    let c = line("This belongs to another column.", x: 0.6, y: 0.8)
    let d = line("This continues the other column.", x: 0.6, y: 0.76)
    let result = OCRService.groupParagraphs([d, b, c, a])
    #expect(result.count == 2)
    #expect(result[0].text == a.text + "\n" + b.text)
    #expect(result[0].bounds == a.bounds.union(b.bounds))
    #expect(result[0].bounds.minY == 0.76)
    #expect(result[0].id == a.id)
    #expect(result[0].confidence > 0.8 && result[0].confidence < 0.9)
    #expect(result[1].text == c.text + "\n" + d.text)
}

@Test func controlsGapsAndDifferentLanguagesStaySeparate() {
    #expect(OCRService.groupParagraphs([line("Settings"), line("Continue", y: 0.76)]).count == 2)
    let a = line("This is a sufficiently long sentence.")
    #expect(OCRService.groupParagraphs([a, line(a.text, y: 0.65)]).count == 2)
    #expect(OCRService.groupParagraphs([a, line(a.text, y: 0.76, language: .japanese)]).count == 2)
    #expect(OCRService.groupParagraphs([a, line(a.text, x: 0.5)]).count == 2)
    #expect(OCRService.groupParagraphs([]).isEmpty)
    #expect(OCRService.groupParagraphs([line("  ")]).isEmpty)
}
}

@Test func inlineNamesDoNotEraseChineseOrMergeSeparateEnglish() throws {
    let chinese = try #require(BarolensLanguage(rawValue: "zh-TW"))
    let langs = [chinese, .english, .korean, .japanese]
    let message = "市場關注聯準會（Fed）利率政策，AI族群走弱，S&P 500指數同步下跌。"
    #expect(OCRService.detectLanguage(message, source: chinese, languages: langs) == chinese)
    let separate = "市場關注聯準會將公布最新利率決策。 | Save your changes before closing."
    #expect(OCRService.detectLanguage(separate, source: chinese, languages: langs) == nil)
    #expect(OCRService.languageRuns(in: separate).map(\.language.languageCode) == ["zh", "en"])
    #expect(OCRService.detectLanguage("市場關注聯準會將公布最新利率決策。 BUY NOW", source: chinese, languages: langs) == nil)
    #expect(OCRService.detectLanguage("Please save your changes before closing.", source: chinese, languages: langs) == .english)
}

@Test func wrappedDecimalDoesNotJoinAnOrdinaryNextLine() {
    #expect(TextBlock.continuesWrappedDecimal(after: "標普指數下跌36.", with: "08點，或0.50%。"))
    #expect(!TextBlock.continuesWrappedDecimal(after: "今天是第36.", with: "08 步繼續操作"))
    #expect(!TextBlock.continuesWrappedDecimal(after: "The index ended at 36.", with: "08% of participants voted."))
}
