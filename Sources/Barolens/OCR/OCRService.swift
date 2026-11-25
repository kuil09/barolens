import CoreGraphics
import Foundation
import NaturalLanguage
import Vision

enum OCRServiceError: Error, Equatable {
    case unsupportedRecognitionLanguages([String])
}

/// Vision work is serialized off the main actor. Bounds retain Vision's lower-left origin.
actor OCRService {
    func recognize(_ image: CGImage, source: BarolensLanguage? = nil, languages: [BarolensLanguage]? = nil) async throws -> [TextBlock] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        // Fast recognition does not support Korean and Japanese.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = try Self.recognitionLanguages(
            supported: request.supportedRecognitionLanguages(), source: source)
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let lines = (request.results ?? []).flatMap { observation -> [TextBlock] in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let text = candidate.string
            let runs = Self.inlineCJKProse(text) == nil ? Self.languageRuns(in: text) : []
            if !runs.isEmpty {
                let spans = runs.compactMap { run -> TextBlock? in
                    guard let rectangle = try? candidate.boundingBox(for: run.range) else { return nil }
                    let bounds = rectangle.boundingBox
                    guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return nil }
                    let language = if let languages { BarolensLanguage.match(run.language.rawValue, in: languages) }
                        else { Optional(run.language) }
                    return TextBlock(text: String(text[run.range]), bounds: bounds,
                                     language: language, confidence: candidate.confidence)
                }
                // Never approximate a piece by the full line bounds: the overlay
                // would paint over the neighboring language instead of that piece.
                if spans.count == runs.count { return spans }
            }
            return [TextBlock(text: text, bounds: observation.boundingBox,
                              language: Self.detectLanguage(text, languages: languages), confidence: candidate.confidence)]
        }
        // Establish layout context before language classification: a wrapped tail
        // such as "it." cannot reliably identify its language independently.
        return Self.assignLanguages(to: Self.groupParagraphs(lines), source: source, languages: languages)
    }

    struct LanguageRun {
        let range: Range<String.Index>
        let language: BarolensLanguage
    }

    /// Vision may report one observation for adjacent labels or sentences on the same
    /// baseline. Do not feed a whole mixed observation to a single-language translator.
    /// Split only when at least two ranges independently identify different languages.
    nonisolated static func languageRuns(in text: String) -> [LanguageRun] {
        func identified(_ ranges: [Range<String.Index>]) -> [LanguageRun] {
            let runs = ranges.compactMap { range -> LanguageRun? in
                guard let range = trimmedRange(range, in: text),
                      text[range].unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2,
                      let language = detectLanguage(String(text[range])) else { return nil }
                return LanguageRun(range: range, language: language)
            }
            guard let first = runs.first,
                  runs.contains(where: { !$0.language.isSameLanguage(as: first.language) }) else { return [] }
            return runs
        }

        // Visible label separators can also distinguish two Latin-script languages.
        let separators = mixedLabelSeparators.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if !separators.isEmpty {
            var cursor = text.startIndex
            var ranges: [Range<String.Index>] = []
            for separator in separators {
                guard let boundary = Range(separator.range, in: text) else { continue }
                ranges.append(cursor..<boundary.lowerBound)
                cursor = boundary.upperBound
            }
            ranges.append(cursor..<text.endIndex)
            let runs = identified(ranges)
            // Do not hide untranslated fragments of an otherwise unsplittable line.
            if runs.count == ranges.filter({ trimmedRange($0, in: text) != nil }).count, runs.count > 1 {
                return runs
            }
        }

        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var script: RunScript?
        var previousLetterEnd: String.Index?
        for index in text.indices {
            guard let next = runScript(text[index]) else { continue }
            let contiguous = previousLetterEnd == index
            if let prior = script, prior != next {
                // Han belongs to its surrounding Japanese/Korean word, not its own
                // Chinese segment. Across a label boundary keep scripts separate.
                if contiguous && prior == .han && (next == .kana || next == .hangul) {
                    script = next
                } else if !(contiguous && next == .han && (prior == .kana || prior == .hangul)) {
                    // No separator may be a single brand or a mixed-script word.
                    guard !contiguous else { return [] }
                    ranges.append(start..<index)
                    start = index
                    script = next
                }
            } else {
                script = next
            }
            previousLetterEnd = text.index(after: index)
        }
        guard !ranges.isEmpty else { return [] }
        ranges.append(start..<text.endIndex)
        let runs = identified(ranges)
        // A product name, OCR speck, or another unclassified fragment does not
        // justify cutting up a sentence. Keep the original conservative result.
        return runs.count == ranges.count ? runs : []
    }

    private nonisolated static let mixedLabelSeparators = try! NSRegularExpression(
        pattern: #"\s*[|｜•·]\s*|\s{2,}"#)

    private enum RunScript { case han, hangul, kana, other }

    private nonisolated static func runScript(_ character: Character) -> RunScript? {
        for scalar in character.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if isHangul(scalar.value) { return .hangul }
            if isKana(scalar.value) { return .kana }
            if isHan(scalar.value) { return .han }
            return .other
        }
        return nil
    }

    private nonisolated static func trimmedRange(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper && text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper && text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        return lower < upper ? lower..<upper : nil
    }

    nonisolated static func recognitionLanguages(supported: [String], source: BarolensLanguage?) throws -> [String] {
        guard let source else { return supported }
        guard let identifier = supported.first(where: { BarolensLanguage.match($0, in: [source]) != nil }) else {
            throw OCRServiceError.unsupportedRecognitionLanguages([source.rawValue])
        }
        // Prioritize the preference without relabeling other scripts as that language.
        return [identifier] + supported.filter { $0 != identifier }
    }

    // Strip only bounded inline identifiers for language detection. Keep the
    // original OCR text and coordinates for translation and rendering.
    private nonisolated static let inlineLatinName = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:[(（][A-Za-z][A-Za-z0-9&.+-]{1,9}[)）]|(?:[A-Z][A-Z0-9]{1,5}(?:[&./-][A-Z0-9]{1,5})*|[A-Z][&./-][A-Z0-9]{1,5}|[A-Z][il])(?: ?[0-9]{1,4})?)(?![A-Za-z0-9])"#)

    private nonisolated static func inlineCJKProse(_ text: String) -> String? {
        guard text.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil,
              text.range(of: #"[|｜•·]|[^\S\n]{2,}"#, options: .regularExpression) == nil else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = inlineLatinName.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }
        // Do not treat a string of standalone English words as CJK identifiers.
        for (lhs, rhs) in zip(matches, matches.dropFirst()) {
            let middle = NSRange(location: NSMaxRange(lhs.range), length: rhs.range.location - NSMaxRange(lhs.range))
            guard let t = Range(middle, in: text),
                  text[t].unicodeScalars.contains(where: { isHan($0.value) || isHangul($0.value) || isKana($0.value) }) else { return nil }
        }
        let cleaned = inlineLatinName.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let letters = cleaned.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let foreign = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count - letters.count
        guard letters.count >= 8, foreign > 0, letters.count >= foreign * 3,
              letters.allSatisfy({ isHan($0.value) || isHangul($0.value) || isKana($0.value) }),
              !(letters.contains { isHangul($0.value) } && letters.contains { isKana($0.value) }) else { return nil }
        return cleaned
    }

    /// Detect without constraining NL hypotheses, then match to the runtime translation catalog.
    nonisolated static func detectLanguage(_ text: String, source: BarolensLanguage? = nil, languages: [BarolensLanguage]? = nil) -> BarolensLanguage? {
        let text = inlineCJKProse(text) ?? text
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let best = hypotheses.max { $0.value < $1.value }
        let hasHangul = letters.contains { isHangul($0.value) }
        let hasKana = letters.contains { isKana($0.value) }
        func accepted(_ identifier: String) -> BarolensLanguage? {
            if let languages { return BarolensLanguage.match(identifier, in: languages) }
            return BarolensLanguage(rawValue: identifier)
        }
        guard !(hasHangul && hasKana) else { return nil }
        // A stray native character is not evidence that a foreign sentence is Korean/Japanese.
        let native = letters.filter { isHangul($0.value) || isKana($0.value) || isHan($0.value) }.count
        // A UI label containing incompatible scripts is not evidence for a single language.
        guard native == 0 || native == letters.count else { return nil }
        if hasHangul || hasKana {
            guard native * 2 >= letters.count else { return nil }
            let expected = hasHangul ? "ko" : "ja"
            if letters.count >= 8, let best, best.value >= 0.85, best.key.rawValue != expected { return nil }
            return accepted(expected)
        }
        let latin = matchesScript(letters, "Latin")
        let shortLabel = text.split(whereSeparator: \.isWhitespace).count <= 2
        let runnerUp = hypotheses.filter { $0.key != best?.key }.map(\.value).max() ?? 0
        let decisive = best.map { $0.value >= 0.85 && $0.value - runnerUp >= 0.5 } ?? false
        // Keep full-sentence detection independent of the user's preference. Short Latin
        // labels may stand alone only with strong, well-separated language evidence.
        if let best, best.value >= 0.85,
           (letters.count >= 8 && (!latin || !shortLabel) || latin && letters.count >= 2 && decisive),
           let detected = accepted(best.key.rawValue), compatible(letters, with: detected) != false {
            return detected
        }
        guard let source, shortLabel, compatible(letters, with: source) == true,
              letters.count >= 2 || letters.allSatisfy({ isHan($0.value) }) ||
                source.languageCode == "en" && ["a", "i"].contains(text.lowercased()),
              let preferred = accepted(source.rawValue) else { return nil }
        // Shared scripts are ambiguous; an explicit source is useful, but a clearly
        // different Latin language is counterevidence (for example Oui under English).
        if latin, let best, best.value >= 0.55, best.value - runnerUp >= 0.25,
           let alternative = BarolensLanguage(rawValue: best.key.rawValue),
           !alternative.isSameLanguage(as: source) { return nil }
        return preferred
    }

    private nonisolated static func matchesScript(_ letters: String.UnicodeScalarView, _ script: String) -> Bool {
        String(letters).range(of: "^\\p{\(script)}+$", options: .regularExpression) != nil
    }

    private nonisolated static func compatible(_ letters: String.UnicodeScalarView, with language: BarolensLanguage) -> Bool? {
        switch language.locale.script?.identifier {
        case "Jpan": return letters.allSatisfy { isHan($0.value) || isKana($0.value) }
        case "Kore": return letters.allSatisfy { isHangul($0.value) || isHan($0.value) }
        case "Hans", "Hant": return letters.allSatisfy { isHan($0.value) }
        default:
            let scripts = ["Latn": "Latin", "Cyrl": "Cyrillic", "Grek": "Greek", "Arab": "Arabic",
                           "Hebr": "Hebrew", "Deva": "Devanagari", "Thai": "Thai"]
            guard let identifier = language.locale.script?.identifier, let script = scripts[identifier] else { return nil }
            return matchesScript(letters, script)
        }
    }

    /// Context comes only from directly detected, nearby lines in the same column, without propagation.
    nonisolated static func assignLanguages(to lines: [TextBlock], source: BarolensLanguage? = nil, languages: [BarolensLanguage]? = nil) -> [TextBlock] {
        let detected = lines.map { detectLanguage($0.translationText, languages: languages) }
        return lines.enumerated().map { index, line in
            var language = detected[index]
            let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            if language == nil, !letters.isEmpty, letters.count <= 6,
               letters.allSatisfy({ isHan($0.value) }) {
                let nearby = lines.indices.filter { other in
                    other != index && sameColumn(line.bounds, lines[other].bounds)
                        && verticalGap(line.bounds, lines[other].bounds) <= max(line.bounds.height, lines[other].bounds.height) * 2
                }
                // Conflicting or unsupported textual neighbors are not evidence for Japanese.
                if !nearby.isEmpty && nearby.allSatisfy({ detected[$0] == .japanese }) {
                    language = .japanese
                }
            }
            if language == nil, letters.count >= 2, matchesScript(letters, "Latin"),
               line.text.split(whereSeparator: \.isWhitespace).count <= 2 {
                // Unknown labels are not anchors. Inferred labels never enter `detected`,
                // so a nearby sentence cannot spread through a chain of UI controls.
                let nearby = lines.indices.filter { other in
                    other != index && detected[other] != nil && sameColumn(line.bounds, lines[other].bounds)
                        && verticalGap(line.bounds, lines[other].bounds) <= max(line.bounds.height, lines[other].bounds.height) * 2
                }
                if let first = nearby.first, let neighbor = detected[first],
                   nearby.allSatisfy({ detected[$0]?.isSameLanguage(as: neighbor) == true }),
                   detectLanguage(line.translationText, source: neighbor, languages: languages)?.isSameLanguage(as: neighbor) == true {
                    language = neighbor
                }
            }
            if language == nil, let source {
                language = detectLanguage(line.translationText, source: source, languages: languages)
            }
            return TextBlock(id: line.id, text: line.text, bounds: line.bounds,
                             language: language, confidence: line.confidence, sourceLines: line.sourceLines)
        }
    }

    /// Layout context is independent of scheduling cells and output line wrapping.
    nonisolated static func groupParagraphs(_ input: [TextBlock]) -> [TextBlock] {
        let lines = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.bounds.isNull && !$0.bounds.isInfinite && $0.bounds.width > 0 && $0.bounds.height > 0
        }.sorted { lhs, rhs in
            if lhs.bounds.maxY != rhs.bounds.maxY { return lhs.bounds.maxY > rhs.bounds.maxY }
            return lhs.bounds.minX < rhs.bounds.minX
        }
        var groups: [[TextBlock]] = []
        for line in lines {
            let candidate = groups.indices.filter { index in
                guard let last = groups[index].last else { return false }
                let height = max(last.bounds.height, line.bounds.height)
                let gap = last.bounds.minY - line.bounds.maxY
                let first = groups[index][0]
                let columnWidth = groups[index].map(\.bounds.width).max() ?? first.bounds.width
                let aligned = abs(first.bounds.minX - line.bounds.minX) <= height * 0.6
                    && line.bounds.maxX <= first.bounds.minX + columnWidth + height
                let continuation = !endsSentence(last.text) || paragraphLine(line.text) ||
                    TextBlock.continuesWrappedDecimal(after: last.text, with: line.text)
                let contextLanguage = groups[index].compactMap(\.language).first
                let compatible = contextLanguage == nil || line.language == nil || contextLanguage == line.language
                return compatible && paragraphLine(first.text) && continuation
                    && aligned && !startsListItem(first.text) && !startsListItem(line.text)
                    && !tabularRow(last, in: lines) && !tabularRow(line, in: lines)
                    && comparableTypeSize(last, line)
                    && gap >= -height * 0.1 && gap <= height * 0.8
            }.min { verticalGap(groups[$0].last!.bounds, line.bounds) < verticalGap(groups[$1].last!.bounds, line.bounds) }
            if let candidate { groups[candidate].append(line) } else { groups.append([line]) }
        }
        return groups.map { group in
            let first = group[0]
            let weight = group.reduce(0) { $0 + $1.text.count }
            let confidence = group.reduce(Float(0)) { $0 + $1.confidence * Float($1.text.count) } / Float(weight)
            return TextBlock(id: first.id, text: group.map(\.text).joined(separator: "\n"),
                             bounds: group.dropFirst().reduce(first.bounds) { $0.union($1.bounds) },
                             language: group.compactMap(\.language).first, confidence: confidence,
                             sourceLines: group.flatMap(\.sourceLines))
        }
    }

    private nonisolated static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?。！？:：".contains(last)
    }
    private nonisolated static func comparableTypeSize(_ a: TextBlock, _ b: TextBlock) -> Bool {
        let heightRatio = min(a.bounds.height, b.bounds.height) / max(a.bounds.height, b.bounds.height)
        if heightRatio >= 0.75 { return true }
        // Real Vision observations can have inflated vertical boxes even for
        // identical fonts. Mean advance is independent supporting evidence, not
        // permission to merge a large heading into smaller body text.
        let advanceA = a.bounds.width / CGFloat(max(1, a.text.count))
        let advanceB = b.bounds.width / CGFloat(max(1, b.text.count))
        return heightRatio >= 0.55 && min(advanceA, advanceB) / max(advanceA, advanceB) >= 0.8
    }
    private nonisolated static func startsListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:[-•●▪·]|\d+[.)]|[A-Za-z][.)])\s+"#, options: .regularExpression) != nil
    }
    private nonisolated static func tabularRow(_ line: TextBlock, in lines: [TextBlock]) -> Bool {
        let peers = lines.filter {
            $0.id != line.id && abs($0.bounds.midY - line.bounds.midY) < line.bounds.height * 0.35 &&
            min($0.bounds.height, line.bounds.height) >= max($0.bounds.height, line.bounds.height) * 0.75 &&
            ($0.bounds.minX > line.bounds.maxX + line.bounds.height || line.bounds.minX > $0.bounds.maxX + line.bounds.height)
        }
        // Aligned short cells / multiple peers are table evidence. Two prose
        // columns are not automatically a table merely because baselines align.
        func cellLabel(_ text: String) -> Bool {
            !endsSentence(text) && text.split(whereSeparator: \.isWhitespace).count == 1
        }
        return peers.count >= 2 || (!peers.isEmpty &&
            (cellLabel(line.text) || peers.contains { cellLabel($0.text) }))
    }

    private nonisolated static func sameColumn(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = max(a.height, b.height)
        let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        return abs(a.minX - b.minX) <= height * 0.6
            && overlap >= min(a.width, b.width) * 0.8
            && min(a.width, b.width) >= max(a.width, b.width) * 0.55
    }

    private nonisolated static func verticalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
    }

    private nonisolated static func paragraphLine(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let cjk = letters.filter { isHangul($0.value) || isKana($0.value) || isHan($0.value) }.count
        return cjk >= 8 || (letters.count >= 16 && text.split(whereSeparator: \.isWhitespace).count >= 3)
    }

    private nonisolated static func isHangul(_ value: UInt32) -> Bool {
        (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value)
    }
    private nonisolated static func isKana(_ value: UInt32) -> Bool {
        (0x3041...0x3096).contains(value) || (0x30A1...0x30FA).contains(value) || (0xFF66...0xFF9D).contains(value)
    }
    private nonisolated static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) || (0x20000...0x2FA1F).contains(value)
    }
}
