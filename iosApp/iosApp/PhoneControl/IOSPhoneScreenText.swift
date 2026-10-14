import AmberPhoneControl
import Foundation
import ImageIO
import Vision

/// Text from one existing screenshot. OCR positions never become native element references.
enum IOSPhoneScreenText {
    struct Result: Encodable, Sendable, Equatable {
        let observationID: String
        let source = "ocr"
        let coordinateSpace = "screenshot_normalized_top_left"
        let items: [Item]
        let ocrMs: Double
        let emptyReason: EmptyReason?
        let coverageAdvice: CoverageAdvice

        enum CodingKeys: String, CodingKey {
            case observationID = "observation_id"
            case source, items
            case coordinateSpace = "coordinate_space"
            case ocrMs = "ocr_ms"
            case emptyReason = "empty_reason"
            case coverageAdvice = "coverage_advice"
        }
    }

    struct Item: Encodable, Sendable, Equatable {
        let text: String
        let confidence: Double
        let bbox: PhoneElementRect
        let center: Point
    }

    struct Point: Encodable, Sendable, Equatable {
        let x: Double
        let y: Double
    }

    enum EmptyReason: String, Encodable, Sendable {
        case noTextDetected = "no_text_detected"
    }

    enum CoverageAdvice: String, Encodable, Sendable {
        case textOnly = "text_only_use_native_tree_or_screenshot_for_control_semantics_and_icons"
        case noText = "no_text_use_screenshot_for_visual_targets"
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidPNG
        case recognitionLanguagesUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidPNG:
                return "无法读取当前 PNG 截图。"
            case .recognitionLanguagesUnavailable:
                return "当前设备的文字识别不支持中文或英文。"
            }
        }
    }

    static func recognize(_ screenshot: PhoneScreenshot) async throws -> Result {
        try Task.checkCancellation()
        let recognition = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            guard let imageSource = CGImageSourceCreateWithData(screenshot.data as CFData, nil),
                  CGImageSourceGetType(imageSource) as String? == "public.png",
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw Error.invalidPNG
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let supported = Set(try request.supportedRecognitionLanguages())
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
            guard !request.recognitionLanguages.isEmpty else {
                throw Error.recognitionLanguagesUnavailable
            }
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            try Task.checkCancellation()

            let items = (request.results ?? []).compactMap { observation -> Item? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let bounds = observation.boundingBox
                // Vision uses a bottom-left origin; phone point actions use screenshot top-left.
                return Item(text: text, confidence: Double(candidate.confidence), bbox: .init(
                    x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height
                ), center: .init(x: bounds.midX, y: 1 - bounds.midY))
            }
            return Result(observationID: screenshot.observationID, items: items,
                          ocrMs: (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                          emptyReason: items.isEmpty ? .noTextDetected : nil,
                          coverageAdvice: items.isEmpty ? .noText : .textOnly)
        }
        return try await withTaskCancellationHandler {
            let result = try await recognition.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            // Synchronous Vision work may finish, but a cancelled task cannot publish its result.
            recognition.cancel()
        }
    }
}
