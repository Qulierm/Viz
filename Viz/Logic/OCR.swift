//
//  OCR.swift
//  Grabber
//
//  Created by Alin Lupascu on 4/5/24.
//

import SwiftUI
import Vision
import Foundation
import AlinFoundation


/// Which engine turns a captured image into text. Vision is the default and needs no
/// downloads; the local model is an explicit opt-in that runs OvisOCR2 through a pinned
/// llama.cpp runtime.
enum RecognitionEngine: String, CaseIterable, Identifiable {
    case vision = "vision"
    case localModel = "localModel"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vision: return "Apple Vision"
        case .localModel: return "OvisOCR2 (local model)"
        }
    }
}

/// Turns an image into text.
protocol TextRecognizing {
    func recognize(image: NSImage,
                   languageCode: String?,
                   quality: TextRecognitionQuality,
                   keepLineBreaks: Bool) async throws -> String
}

/// Apple's Vision framework: a text request plus a barcode request, combined exactly the way
/// the app has always done it.
struct VisionRecognizer: TextRecognizing {
    func recognize(image: NSImage,
                   languageCode: String?,
                   quality: TextRecognitionQuality,
                   keepLineBreaks: Bool) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        var recognizedText = ""
        var recognizedBarcodes = ""

        let textRequest = textRequest(quality: quality, languageCode: languageCode, keepLineBreaks: keepLineBreaks) { text in
            recognizedText = text
        }
        let barcodeRequest = barcodeRequest(keepLineBreaks: keepLineBreaks) { barcodes in
            recognizedBarcodes = barcodes
        }

        try requestHandler.perform([textRequest, barcodeRequest])

        return [recognizedText, recognizedBarcodes]
            .filter { !$0.isEmpty && !$0.hasPrefix("Unable to extract") }
            .joined(separator: "\n")
    }

    private func textRequest(quality: TextRecognitionQuality,
                             languageCode: String?,
                             keepLineBreaks: Bool,
                             completion: @escaping (String) -> Void) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion("Unable to extract any text from selection")
                return
            }

            var recognizedText = ""
            for observation in observations {
                guard let text = observation.topCandidates(1).first else { continue }
                recognizedText += text.string
                if keepLineBreaks {
                    recognizedText += "\n"
                } else {
                    recognizedText += " "
                }
            }

            if recognizedText.isEmpty {
                completion("Unable to extract any text from selection")
            } else if keepLineBreaks {
                completion(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                completion(recognizedText)
            }
        }

        request.recognitionLevel = quality == .fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        if let langCode = languageCode {
            request.recognitionLanguages = [langCode]
        }

        return request
    }

    private func barcodeRequest(keepLineBreaks: Bool,
                                completion: @escaping (String) -> Void) -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest { request, error in
            guard let observations = request.results as? [VNBarcodeObservation] else {
                completion("Unable to extract any qr/barcode from selection")
                return
            }

            var barcodeText = ""
            for observation in observations {
                let barcodeValue = observation.payloadStringValue ?? "Unknown value"
                barcodeText += barcodeValue
                if keepLineBreaks {
                    barcodeText += "\n"
                } else {
                    barcodeText += " "
                }
            }

            if barcodeText.isEmpty {
                completion("Unable to extract any qr/barcode from selection")
            } else if keepLineBreaks {
                completion(barcodeText.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                completion(barcodeText)
            }
        }

        return request
    }
}

/// Why the local model could not produce text. Every case falls back to Vision upstream.
enum LocalModelError: Error, LocalizedError, Equatable {
    case runtimeMissing
    case modelMissing
    case launchFailed(String)
    case nonZeroExit(Int32)
    case timedOut
    case emptyOutput
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "the recognition runtime is not in the app"
        case .modelMissing: return "the local model is not downloaded"
        case .launchFailed(let reason): return "the runtime could not start (\(reason))"
        case .nonZeroExit(let code): return "the runtime exited with code \(code)"
        case .timedOut: return "the model took too long"
        case .emptyOutput: return "the model returned no text"
        case .imageEncodingFailed: return "the captured image could not be encoded"
        }
    }
}

/// Runs OvisOCR2 through the pinned llama.cpp `llama-mtmd-cli`, which turns a page image into
/// a single Markdown document. The model card is at https://huggingface.co/ATH-MaaS/OvisOCR2.
struct LocalModelRecognizer: TextRecognizing {
    /// Runs the executable and returns everything it printed. Injectable so the harness can
    /// exercise this type without the 763 MB model or the runtime.
    typealias ProcessLauncher = (_ executable: URL, _ arguments: [String]) throws -> String

    /// How long the model may run before it is killed. A page takes roughly six seconds on
    /// the machine this was developed on, so this leaves room for a slow page while staying
    /// bounded.
    static let timeout: TimeInterval = 120
    /// Output token limit for one page (the model card uses 16384; a page of text fits well
    /// inside 4096 and the smaller bound keeps the worst case short).
    static let tokenLimit = 4096

    /// The model card's prompt, verbatim. It asks for one Markdown document in reading
    /// order, formulas as LaTeX, tables as HTML and images as HTML image tags.
    static let prompt = """
    Extract all readable content from the image in natural human reading order and output the result as a single Markdown document. For charts or images, represent them using an HTML image tag: <img src="images/bbox_{left}_{top}_{right}_{bottom}.jpg" />, where left, top, right, bottom are bounding box coordinates scaled to [0, 1000). Format formulas as LaTeX. Format tables as HTML: <table>...</table>. Transcribe all other text as standard Markdown. Preserve the original text without translation or paraphrasing.
    """

    var runtimeURL: URL?
    var modelURL: URL?
    var projectorURL: URL?
    var launcher: ProcessLauncher = LocalModelRecognizer.launch

    /// The argument vector handed to the runtime. Recorded in BUILDING.md; the spike that
    /// proved it works used exactly these flags.
    func arguments(imageURL: URL) -> [String] {
        var args: [String] = []
        if let modelURL { args += ["-m", modelURL.path] }
        if let projectorURL { args += ["--mmproj", projectorURL.path] }
        args += ["--image", imageURL.path]
        args += ["-p", Self.prompt]
        args += ["-n", String(Self.tokenLimit)]
        args += ["--jinja", "-t", "8"]
        return args
    }

    func recognize(image: NSImage,
                   languageCode: String?,
                   quality: TextRecognitionQuality,
                   keepLineBreaks: Bool) async throws -> String {
        guard let runtimeURL else { throw LocalModelError.runtimeMissing }
        guard let modelURL, let projectorURL else { throw LocalModelError.modelMissing }
        guard let png = Self.pngData(from: image) else { throw LocalModelError.imageEncodingFailed }

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viz-ovis-\(UUID().uuidString).png")
        try png.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let output = try launcher(runtimeURL, arguments(imageURL: imageURL))
        let text = Self.markdown(fromRuntimeOutput: output)
        guard !text.isEmpty else { throw LocalModelError.emptyOutput }
        return text
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Strips what the runtime prints around the answer: its log lines, and the model's
    /// thinking block. This build does not accept `--chat-template-kwargs`, so the model
    /// card's `enable_thinking=False` cannot be set through the CLI and the answer always
    /// follows a line containing `</think>`.
    static func markdown(fromRuntimeOutput output: String) -> String {
        var body = output
        if let range = body.range(of: "</think>", options: .backwards) {
            body = String(body[range.upperBound...])
        }
        let logPrefix = try? NSRegularExpression(pattern: "^\\s*\\d+(\\.\\d+)+\\s+[IWE]\\s")
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let logPrefix else { return true }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return logPrefix.firstMatch(in: String(line), range: range) == nil
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The real launcher: runs the runtime with a timeout and returns its combined output.
    static func launch(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw LocalModelError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            throw LocalModelError.timedOut
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalModelError.nonZeroExit(process.terminationStatus)
        }
        return output
    }
}

struct TextRecognition {
    @AppStorage("appendRecognizedText") var appendRecognizedText: Bool = false
    @AppStorage("postcommands") var postCommands: String = "say [ocr];"
    @AppStorage("processing") var processingIsEnabled: Bool = false

    let appState = AppState.shared

    var recognizedContent = RecognizedContent.shared
    var image: NSImage
    var historyState: HistoryState
    var didFinishRecognition: () -> Void

    //MARK: Universal Recognition
    func recognizeContent() {
        // Vision is the only engine wired into the capture flow so far; the engine setting
        // exists but the local model is not used here yet.
        let recognizer: TextRecognizing = VisionRecognizer()
        let languageCode = appState.selectedLanguage.code
        let quality = appState.selectedQuality

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let combinedText = try await recognizer.recognize(image: self.image,
                                                                      languageCode: languageCode,
                                                                      quality: quality,
                                                                      keepLineBreaks: self.keepLineBreaks)
                    DispatchQueue.main.async {
                        let finalItem = TextItem(text: combinedText.isEmpty ? "Unable to extract any content from selection" : combinedText)
                        self.processRecognitionResult(textItem: finalItem, failureMessage: "Unable to extract any content from selection")
                    }
                } catch {
                    printOS("Failed to recognize content: \(error.localizedDescription)")
                }
            }
        }
    }

    @AppStorage("keepLineBreaks") private var keepLineBreaks: Bool = true

    // Helper function
    private func processRecognitionResult(textItem: TextItem, failureMessage: String) {
        self.updateRecognizedContent(with: textItem)
        self.didFinishRecognition()

        guard textItem.text != failureMessage else { return }

        copyTextItemsToClipboard(textItems: self.recognizedContent.items)
        playSound(for: .text(TextItem(text: "")))
        historyState.historyItems.append(.text(textItem))
        if processingIsEnabled {
            updateOnMain {
                AppState.shared.cmdOutput = "Running post-processing commands.."
            }
            Task(priority: .userInitiated) {
                let combinedText = self.recognizedContent.items.map { $0.text }.joined(separator: "\n")
                let command = replaceContentToken(in: postCommands, with: combinedText)
                let result = executeShellCommand(command)
                updateOnMain {
                    AppState.shared.cmdOutput = result
                }
            }
        }
    }

    private func updateRecognizedContent(with textItem: TextItem) {
        if appendRecognizedText {
            recognizedContent.items.append(textItem)
        } else {
            recognizedContent.items = [textItem]
        }
    }

}





class CaptureService {
    @AppStorage("postcommands") var postCommands: String = "say [ocr];"

    static let shared = CaptureService()
    var screenCaptureUtility = ScreenCaptureUtility()
    var recognizedContent = RecognizedContent.shared
    let pasteboard = NSPasteboard.general

    func captureContent() {
        updateOnMain {
            AppState.shared.cmdOutput = ""
        }
        screenCaptureUtility.captureScreenSelectionToClipboard { capturedImage in
            if let image = capturedImage {

                TextRecognition(recognizedContent: self.recognizedContent, image: image, historyState: HistoryState.shared) {
                    showPreviewWindow(contentView: PreviewContentView())
                }.recognizeContent()
            } else {
                printOS("Failed to capture image")
            }
        }
    }


}
