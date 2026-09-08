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

struct OCRItem: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let characters: [OCRCharacter]?
}

func characterBoxes(_ candidate: VNRecognizedText) -> [OCRCharacter]? {
    let text = candidate.string
    // The formatter only splits whitespace-separated observations or compound
    // percentages. Ordinary words and single numbers never need character data.
    // Avoid thousands of unused objects crossing the Foundation-to-Lua bridge.
    if !text.contains(where: { $0.isWhitespace }) {
        guard text.contains("%") || text.contains("％") else { return nil }
        var number = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "％", with: "%")
        for currency in ["$", "€", "¥", "£"] { number = number.replacingOccurrences(of: currency, with: "") }
        if number.hasPrefix("("), number.hasSuffix(")") {
            number = "-" + number.dropFirst().dropLast()
        }
        if number.range(of: #"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)%?$"#, options: .regularExpression) != nil {
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
    var languages = ["zh-Hans", "zh-Hant", "en-US"]
    var recognitionLevel = "accurate"
    var languageCorrection = false
    var automaticLanguageDetection = false
    var minimumTextHeight: Float = 0
    var customWords: [String] = []

    enum CodingKeys: String, CodingKey {
        case languages, recognitionLevel, languageCorrection
        case automaticLanguageDetection, minimumTextHeight, customWords
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
    }
}

struct OCRMetadata: Encodable {
    let revision: Int
    let languages: [String]
    let recognitionLevel: String
    let languageCorrection: Bool
    let automaticLanguageDetection: Bool
    let minimumTextHeight: Float
    let recognitionMS: Double
    let totalMS: Double
    let meanConfidence: Float?
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

let usage = """
usage: visionocr [--config JSON] [--details] [--output FILE] IMAGE
       visionocr --capabilities

Default: accurate, zh-Hans/zh-Hant/en-US, raw text, all text sizes.
--config accepts languages, recognitionLevel, languageCorrection,
  automaticLanguageDetection, minimumTextHeight and customWords.
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

    let items = (request.results ?? []).compactMap { observation -> OCRItem? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return OCRItem(
            text: candidate.string,
            confidence: candidate.confidence,
            x: box.origin.x,
            y: box.origin.y,
            width: box.size.width,
            height: box.size.height,
            characters: details ? characterBoxes(candidate) : nil
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let output: Data
    if details {
        let metadata = OCRMetadata(revision: request.revision, languages: request.recognitionLanguages,
            recognitionLevel: config.recognitionLevel, languageCorrection: config.languageCorrection,
            automaticLanguageDetection: config.automaticLanguageDetection,
            minimumTextHeight: config.minimumTextHeight, recognitionMS: recognitionMS,
            totalMS: (ProcessInfo.processInfo.systemUptime - start) * 1000,
            meanConfidence: items.isEmpty ? nil : items.reduce(0) { $0 + $1.confidence } / Float(items.count))
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
