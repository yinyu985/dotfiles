import Foundation
import ImageIO
import Vision

struct OCRCharacter: Codable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRCandidate: Codable {
    let text: String
    let confidence: Float
}

struct OCRItem: Codable {
    var text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var characters: [OCRCharacter]?
    let candidates: [OCRCandidate]?
}

func isWellFormedNumber(_ text: String) -> Bool {
    // A thousands group is exactly three digits. Vision drops the space between
    // adjacent small values, so "1,0366.32%" must not pass as one number: the
    // layout layer uses this to decide whether the text needs a safe split.
    return text.range(of: #"^[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?%?$"#,
        options: .regularExpression) != nil
}

func characterBoxes(_ candidate: VNRecognizedText) -> [OCRCharacter]? {
    let text = candidate.string
    // Accurate recognition returns word-level boxes; these are not glyph bounds.
    // Ordinary words and single numbers never need substring data.
    // Avoid thousands of unused objects crossing the Foundation-to-Lua bridge.
    if !text.contains(where: { $0.isWhitespace }) {
        guard text.contains("%") || text.contains("％") else { return nil }
        var number = text.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "％", with: "%")
        for currency in ["$", "€", "¥", "£"] { number = number.replacingOccurrences(of: currency, with: "") }
        if number.hasPrefix("("), number.hasSuffix(")") {
            number = "-" + number.dropFirst().dropLast()
        }
        if isWellFormedNumber(number) {
            return nil
        }
    }
    return text.indices.map { index in
        let end = candidate.string.index(after: index)
        // Vision returns zero rectangles for whitespace. Keep its text so a
        // consumer can preserve spacing when splitting only confirmed columns.
        let box = (try? candidate.boundingBox(for: index..<end)?.boundingBox) ?? .zero
        return OCRCharacter(text: String(candidate.string[index..<end]),
            x: box.minX, y: box.minY, width: box.width, height: box.height)
    }
}

struct Configuration: Decodable {
    var languages = ["zh-Hans", "en-US"]
    var recognitionLevel = "accurate"
    var languageCorrection = false
    var automaticLanguageDetection = false
    var minimumTextHeight: Float = 0
    var customWords: [String] = []
    var candidateCount = 1
    var refineTickerCells = true

    enum CodingKeys: String, CodingKey {
        case languages, recognitionLevel, languageCorrection
        case automaticLanguageDetection, minimumTextHeight, customWords, candidateCount
        case refineTickerCells
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? languages
        recognitionLevel = try values.decodeIfPresent(String.self, forKey: .recognitionLevel) ?? recognitionLevel
        languageCorrection = try values.decodeIfPresent(Bool.self, forKey: .languageCorrection) ?? languageCorrection
        automaticLanguageDetection = try values.decodeIfPresent(Bool.self, forKey: .automaticLanguageDetection)
            ?? automaticLanguageDetection
        minimumTextHeight = try values.decodeIfPresent(Float.self, forKey: .minimumTextHeight) ?? minimumTextHeight
        customWords = try values.decodeIfPresent([String].self, forKey: .customWords) ?? customWords
        candidateCount = try values.decodeIfPresent(Int.self, forKey: .candidateCount) ?? candidateCount
        refineTickerCells = try values.decodeIfPresent(Bool.self, forKey: .refineTickerCells) ?? refineTickerCells
    }
}

struct OCRMetadata: Encodable {
    let supportedRevisions: [Int]
    let osVersion: String
    let customWords: [String]
    let candidateCount: Int
    let revision: Int
    let languages: [String]
    let recognitionLevel: String
    let languageCorrection: Bool
    let automaticLanguageDetection: Bool
    let minimumTextHeight: Float
    let recognitionMS: Double
    let totalMS: Double
    let meanConfidence: Float?
    let refineMS: Double
    let refinedCells: Int
}

struct OCRResult: Encodable {
    let items: [OCRItem]
    let metadata: OCRMetadata
}

struct OCRError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func configuredRequest(_ config: Configuration) throws -> VNRecognizeTextRequest {
    guard (1...10).contains(config.candidateCount) else {
        throw OCRError(message: "candidateCount must be between 1 and 10")
    }
    let request = VNRecognizeTextRequest()
    // Select only an algorithm revision actually available on this macOS.
    request.revision = VNRecognizeTextRequest.supportedRevisions.last ?? VNRecognizeTextRequest.defaultRevision
    switch config.recognitionLevel {
    case "accurate": request.recognitionLevel = .accurate
    case "fast": request.recognitionLevel = .fast
    default: throw OCRError(message: "recognitionLevel must be accurate or fast")
    }
    guard config.minimumTextHeight.isFinite, (0...1).contains(config.minimumTextHeight) else {
        throw OCRError(message: "minimumTextHeight must be between 0 and 1")
    }
    guard !config.languages.isEmpty else {
        throw OCRError(message: "languages must not be empty")
    }
    let supported = try request.supportedRecognitionLanguages()
    var languages: [String] = []
    for language in config.languages {
        let canonical = language.replacingOccurrences(of: "_", with: "-")
        guard let match = supported.first(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) else {
            throw OCRError(message: "unsupported language for \(config.recognitionLevel): \(language)")
        }
        if !languages.contains(match) { languages.append(match) }
    }
    guard config.customWords.isEmpty || config.languageCorrection else {
        throw OCRError(message: "customWords requires languageCorrection=true")
    }
    guard !config.automaticLanguageDetection || config.recognitionLevel == "accurate" else {
        throw OCRError(message: "automaticLanguageDetection requires accurate recognition")
    }
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = config.languageCorrection
    request.customWords = config.customWords
    // Explicit zero preserves small text. A larger cutoff deliberately trades recall for speed.
    request.minimumTextHeight = config.minimumTextHeight
    if #available(macOS 13.0, *) {
        request.automaticallyDetectsLanguage = config.automaticLanguageDetection
    } else if config.automaticLanguageDetection {
        throw OCRError(message: "automaticLanguageDetection requires macOS 13 or later")
    }
    return request
}

private let tickerDecorations: Set<Character> = ["•", "·", "・", "®", "©", "◎", "⁃", "∙", "※", "★", "☆"]

// "TICKER VENUE" only; anything else (prices, notes) is left alone.
// Decoration tokens (•, ®) are dropped before counting.
func tickerCellParts(_ text: String) -> (ticker: String, venue: String)? {
    var tokens: [String] = []
    for token in text.split(separator: " ", omittingEmptySubsequences: true) {
        var value = String(token)
        while let first = value.first, tickerDecorations.contains(first) { value.removeFirst() }
        while let last = value.last, tickerDecorations.contains(last) { value.removeLast() }
        if value.isEmpty { continue }
        tokens.append(value)
    }
    guard tokens.count == 2 else { return nil }
    let ticker = tokens[0], venue = tokens[1]
    guard (1...6).contains(ticker.count),
          ticker.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil,
          (3...12).contains(venue.count),
          venue.range(of: "^[A-Z][A-Z.,]*$", options: .regularExpression) != nil else { return nil }
    return (ticker, venue)
}

// Permissive test for "this cell may be a ticker": uppercase short first token,
// a venue-looking tail without digits. The strict check above is applied only to
// the re-read text.
func tickerCandidate(_ text: String) -> String? {
    let parts = text.split(separator: " ").map(String.init)
    guard parts.count >= 2 else { return nil }
    let ticker = parts[0]
    guard (1...6).contains(ticker.count),
          ticker.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil else { return nil }
    let rest = parts.dropFirst().joined()
    guard !rest.isEmpty, rest.count <= 14,
          rest.range(of: "[0-9]", options: .regularExpression) == nil else { return nil }
    return ticker
}

func editDistance(_ left: String, _ right: String) -> Int {
    let a = Array(left), b = Array(right)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for row in 1...a.count {
        current[0] = row
        for column in 1...b.count {
            let cost = a[row - 1] == b[column - 1] ? 0 : 1
            current[column] = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

// The portfolio grid draws "—" in cells without a value. On low-quality inputs
// Vision sometimes reports that grey placeholder as the digit "1". The box then
// looks like a digit, but the ink is a flat bar, so check the pixels.
func inkBounds(_ image: CGImage, box: CGRect) -> CGRect? {
    let padded = box.insetBy(dx: -0.0008, dy: -0.0008)
    let pixel = CGRect(x: padded.minX * Double(image.width), y: (1 - padded.maxY) * Double(image.height),
        width: padded.width * Double(image.width), height: padded.height * Double(image.height)).integral
    guard pixel.width >= 4, pixel.height >= 4, let crop = image.cropping(to: pixel) else { return nil }
    let width = crop.width, height = crop.height
    guard let space = CGColorSpace(name: CGColorSpace.linearGray),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var histogram = [Int](repeating: 0, count: 256)
    for index in 0..<(width * height) { histogram[Int(data[index])] += 1 }
    var background = 0
    for value in 1..<256 where histogram[value] > histogram[background] { background = value }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where abs(Int(data[y * width + x]) - background) > 48 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func isPlaceholderBar(_ item: OCRItem, image: CGImage) -> Bool {
    guard item.confidence < 0.4, item.text.count == 1,
          item.text.range(of: "^[0-9lI]$", options: .regularExpression) != nil else { return false }
    let box = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
    guard let ink = inkBounds(image, box: box) else { return false }
    return ink.width >= 6 && ink.height <= max(3, ink.width * 0.35)
}

// The mixed Chinese/English model turns the ~8 px exchange suffix into N/Q/O/M
// noise. Re-read each ticker cell alone with the English model. One request per
// cell, all inside this process, so no second full-image pass and no extra
// helper launch.
func refineTickerColumn(_ items: [OCRItem], image: CGImage, config: Configuration)
    throws -> ([OCRItem], Double, Int) {
    var targets: [Int] = []
    for (index, item) in items.enumerated() where item.x < 0.2 && tickerCandidate(item.text) != nil {
        targets.append(index)
    }
    guard targets.count >= 3 else { return (items, 0, 0) }

    var english = config
    english.languages = ["en-US"]
    english.candidateCount = 1
    var output = items
    var refined = 0
    let started = ProcessInfo.processInfo.systemUptime
    for index in targets {
        let item = items[index]
        let padded = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
            .insetBy(dx: -0.002, dy: -0.002)
        let pixel = CGRect(x: padded.minX * Double(image.width), y: (1 - padded.maxY) * Double(image.height),
            width: padded.width * Double(image.width), height: padded.height * Double(image.height)).integral
        guard pixel.width >= 16, pixel.height >= 8, let crop = image.cropping(to: pixel) else { continue }
        let request = try configuredRequest(english)
        try VNImageRequestHandler(cgImage: crop).perform([request])
        guard let candidate = request.results?.first?.topCandidates(1).first,
              let parts = tickerCellParts(candidate.string),
              let original = tickerCandidate(item.text),
              editDistance(original, parts.ticker) <= 1 else { continue }
        if ProcessInfo.processInfo.environment["OCR_DEBUG_REFINE"] != nil {
            FileHandle.standardError.write(Data("  \(item.text) -> \(candidate.string)\n".utf8))
        }
        let text = parts.ticker + " " + parts.venue
        if output[index].text != text {
            output[index].text = text
            output[index].characters = nil
            refined += 1
        }
    }
    return (output, (ProcessInfo.processInfo.systemUptime - started) * 1000, refined)
}

let usage = """
usage: visionocr [--config JSON] [--details] [--output FILE] IMAGE
       visionocr --capabilities

Default: accurate, zh-Hans/en-US, automatic language detection off,
  language correction off, all text sizes.
--config accepts languages, recognitionLevel, languageCorrection,
  automaticLanguageDetection, minimumTextHeight, customWords, candidateCount (1...10)
  and refineTickerCells (default true: one extra English read of a ticker column).
--details returns {items, metadata}, including character boxes for table alignment;
  otherwise output is the original item array.
--output writes JSON atomically to a file instead of stdout.
--capabilities reports the installed OS's supported languages and revision.
"""

do {
    let start = ProcessInfo.processInfo.systemUptime
    var config = Configuration()
    var details = false
    var outputPath: String?
    var imagePath: String?
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let argument = args.removeFirst()
        switch argument {
        case "--help", "-h":
            FileHandle.standardOutput.write(Data((usage + "\n").utf8))
            exit(0)
        case "--capabilities":
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequest.supportedRevisions.last ?? VNRecognizeTextRequest.defaultRevision
            request.recognitionLevel = .accurate
            let accurate = try request.supportedRecognitionLanguages()
            request.recognitionLevel = .fast
            let fast = try request.supportedRecognitionLanguages()
            let capabilities: [String: Any] = ["revision": request.revision,
                "supportedRevisions": Array(VNRecognizeTextRequest.supportedRevisions),
                "accurateLanguages": accurate, "fastLanguages": fast]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: capabilities, options: .sortedKeys))
            exit(0)
        case "--config":
            guard !args.isEmpty else { throw OCRError(message: "--config requires JSON") }
            config = try JSONDecoder().decode(Configuration.self, from: Data(args.removeFirst().utf8))
        case "--details": details = true
        case "--output":
            guard !args.isEmpty else { throw OCRError(message: "--output requires a file path") }
            outputPath = args.removeFirst()
        case "--":
            guard imagePath == nil, args.count == 1 else { throw OCRError(message: usage) }
            imagePath = args.removeFirst()
        default:
            guard !argument.hasPrefix("--"), imagePath == nil else { throw OCRError(message: usage) }
            imagePath = argument
        }
    }
    guard let imagePath else { throw OCRError(message: usage) }
    let imageURL = URL(fileURLWithPath: imagePath)
    if let outputPath, URL(fileURLWithPath: outputPath).standardizedFileURL == imageURL.standardizedFileURL {
        throw OCRError(message: "output file must differ from the input image")
    }
    guard FileManager.default.isReadableFile(atPath: imageURL.path) else {
        throw OCRError(message: "image is not readable")
    }
    guard CGImageSourceCreateWithURL(imageURL as CFURL, nil) != nil else {
        throw OCRError(message: "image format is invalid or unsupported")
    }
    let request = try configuredRequest(config)
    // The URL handler preserves image orientation metadata and original screenshot pixels.
    let handler = VNImageRequestHandler(url: imageURL, options: [:])
    let recognitionStart = ProcessInfo.processInfo.systemUptime
    try handler.perform([request])
    let recognitionMS = (ProcessInfo.processInfo.systemUptime - recognitionStart) * 1000

    var items = (request.results ?? []).compactMap { observation -> OCRItem? in
        let candidates = observation.topCandidates(config.candidateCount)
        guard let candidate = candidates.first else { return nil }
        let box = observation.boundingBox
        return OCRItem(
            text: candidate.string,
            confidence: candidate.confidence,
            x: box.origin.x,
            y: box.origin.y,
            width: box.size.width,
            height: box.size.height,
            characters: details ? characterBoxes(candidate) : nil,
            candidates: details && config.candidateCount > 1
                ? candidates.map { OCRCandidate(text: $0.string, confidence: $0.confidence) } : nil
        )
    }

    // The mixed Chinese/English model reads the tiny exchange suffix of a ticker
    // cell ("NASDAQ.NMS", ~8 px) as N/Q/O/M noise. Re-read only that column with
    // the English model; one extra request, no second full-image pass.
    var refineMS: Double = 0
    var refinedCells = 0
    if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        if config.refineTickerCells {
            (items, refineMS, refinedCells) = try refineTickerColumn(items, image: image, config: config)
        }
        items.removeAll { isPlaceholderBar($0, image: image) }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let output: Data
    if details {
        let metadata = OCRMetadata(supportedRevisions: Array(VNRecognizeTextRequest.supportedRevisions),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            customWords: config.customWords, candidateCount: config.candidateCount, revision: request.revision, languages: request.recognitionLanguages,
            recognitionLevel: config.recognitionLevel, languageCorrection: config.languageCorrection,
            automaticLanguageDetection: config.automaticLanguageDetection,
            minimumTextHeight: config.minimumTextHeight, recognitionMS: recognitionMS,
            totalMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
            meanConfidence: items.isEmpty ? nil : items.reduce(0) { $0 + $1.confidence } / Float(items.count),
            refineMS: refineMS, refinedCells: refinedCells)
        output = try encoder.encode(OCRResult(items: items, metadata: metadata))
    } else {
        output = try encoder.encode(items)
    }
    if let outputPath {
        try output.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    } else {
        FileHandle.standardOutput.write(output)
    }
} catch {
    FileHandle.standardError.write(Data(("Vision OCR failed: \(error.localizedDescription)\n").utf8))
    exit(1)
}
