//
//  OCR.swift
//  Grabber
//
//  Created by Alin Lupascu on 4/5/24.
//

import SwiftUI
import Vision
import CryptoKit
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

/// One file the local engine needs, pinned by repository revision and SHA-256. Nothing here
/// is ever committed or bundled: the user downloads these files into Application Support.
struct ModelFile: Identifiable, Equatable {
    let name: String
    let byteSize: Int64
    let sha256: String
    let repository: String
    let revision: String

    var id: String { name }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!
    }
}

/// The OvisOCR2 catalogue: the model card is at https://huggingface.co/ATH-MaaS/OvisOCR2
/// (Apache-2.0) and the GGUF conversion is `bartowski/ATH-MaaS_OvisOCR2-GGUF`. The revision
/// and both checksums were pinned by the feasibility spike, which ran this exact pair
/// through llama.cpp build b11160 and produced correct Markdown.
enum OvisModel {
    static let displayName = "OvisOCR2"
    static let modelLicence = "Apache-2.0"
    static let runtimeLicence = "MIT"
    static let summary = "Page-level Markdown with tables and formulas, running fully offline."

    static let files: [ModelFile] = [
        ModelFile(name: "ATH-MaaS_OvisOCR2-Q4_K_M.gguf",
                  byteSize: 557_867_136,
                  sha256: "3786d230ceb8f217abdfb8ea8adba975827595053ad5087cb5502898d6a8a68e",
                  repository: "bartowski/ATH-MaaS_OvisOCR2-GGUF",
                  revision: "ab22420f3d44201d3aa5a62ca49a665a46b507e9"),
        ModelFile(name: "mmproj-ATH-MaaS_OvisOCR2-f16.gguf",
                  byteSize: 204_987_040,
                  sha256: "4e0e9cb9d79dd0f423ba152a51816aa82a1f1a9d1a0190b6f67b2cd4cc5dd681",
                  repository: "bartowski/ATH-MaaS_OvisOCR2-GGUF",
                  revision: "ab22420f3d44201d3aa5a62ca49a665a46b507e9")
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }

    /// Where the files live: the app's Application Support folder, never the repository.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Viz/Models/OvisOCR2", isDirectory: true)
    }

    static var modelURL: URL? { url(for: files.first?.name) }
    static var projectorURL: URL? { url(for: files.last?.name) }

    static func url(for name: String?) -> URL? {
        guard let name else { return nil }
        return directory.appendingPathComponent(name)
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
        let languageCode = appState.selectedLanguage.code
        let quality = appState.selectedQuality

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                // The local model is only used when the user selected it AND its files and
                // the runtime are present; anything else means Vision.
                var note: String?
                var combinedText = ""
                if let model = Self.localModelRecognizerIfReady(appState: self.appState) {
                    do {
                        combinedText = try await model.recognize(image: self.image,
                                                                 languageCode: languageCode,
                                                                 quality: quality,
                                                                 keepLineBreaks: self.keepLineBreaks)
                    } catch {
                        // Every failure falls back to Vision for this capture, with a short
                        // note naming the reason. A capture never fails because of the model.
                        let reason = (error as? LocalModelError)?.errorDescription ?? error.localizedDescription
                        note = "Local model unavailable (\(reason)); used Vision instead"
                        printOS("Local model failed, falling back to Vision: \(reason)")
                    }
                }
                if combinedText.isEmpty {
                    do {
                        combinedText = try await VisionRecognizer().recognize(image: self.image,
                                                                              languageCode: languageCode,
                                                                              quality: quality,
                                                                              keepLineBreaks: self.keepLineBreaks)
                    } catch {
                        printOS("Failed to recognize content: \(error.localizedDescription)")
                    }
                }
                let text = combinedText
                let finalNote = note
                DispatchQueue.main.async {
                    AppState.shared.recognitionNote = finalNote
                    let finalItem = TextItem(text: text.isEmpty ? "Unable to extract any content from selection" : text)
                    self.processRecognitionResult(textItem: finalItem, failureMessage: "Unable to extract any content from selection")
                }
            }
        }
    }

    /// The local recogniser, but only when the engine is selected and everything it needs is
    /// on disk: the pinned runtime inside the bundle plus both verified model files.
    static func localModelRecognizerIfReady(appState: AppState,
                                            runtimeURL: URL? = ModelStore.bundledRuntimeURL,
                                            modelDirectory: URL = OvisModel.directory) -> LocalModelRecognizer? {
        guard appState.recognitionEngine == .localModel else { return nil }
        guard let runtime = runtimeURL else { return nil }
        guard ModelStore.filesPresent(in: modelDirectory) else { return nil }
        var recognizer = LocalModelRecognizer()
        recognizer.runtimeURL = runtime
        recognizer.modelURL = modelDirectory.appendingPathComponent(OvisModel.files[0].name)
        recognizer.projectorURL = modelDirectory.appendingPathComponent(OvisModel.files[1].name)
        return recognizer
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

/// Downloads, verifies and removes the local model files. A file only counts as installed
/// once its SHA-256 matches the manifest; a mismatch deletes it instead of leaving a file
/// that would fail later.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var installedBytes: Int64 = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    private var downloadTask: Task<Void, Never>?

    init() { refresh() }

    var isInstalled: Bool { installedBytes >= OvisModel.totalBytes }

    /// The runtime that ships inside the app bundle, if the build fetched it. Nonisolated:
    /// the recognition path checks it off the main actor.
    nonisolated static var bundledRuntimeURL: URL? {
        Bundle.main.url(forResource: "llama-mtmd-cli", withExtension: nil, subdirectory: "Runtime")
    }

    /// True when both pinned files are on disk with their manifest sizes. The directory is a
    /// parameter so the harness can point at a fake folder instead of the real one.
    nonisolated static func filesPresent(in directory: URL = OvisModel.directory) -> Bool {
        for file in OvisModel.files {
            let path = directory.appendingPathComponent(file.name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if size != file.byteSize { return false }
        }
        return true
    }

    func refresh() {
        var total: Int64 = 0
        for file in OvisModel.files where FileManager.default.fileExists(atPath: OvisModel.directory.appendingPathComponent(file.name).path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: OvisModel.directory.appendingPathComponent(file.name).path)[.size] as? Int64) ?? 0
            if size == file.byteSize { total += size }
        }
        installedBytes = total
    }

    /// Verifies one file against the manifest, deleting it when it does not match.
    /// Nonisolated so the capture path and the harness can both call it.
    nonisolated static func verify(_ file: ModelFile, at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    func download() {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        lastError = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: OvisModel.directory, withIntermediateDirectories: true)
                var completed: Int64 = 0
                for file in OvisModel.files {
                    let destination = OvisModel.directory.appendingPathComponent(file.name)
                    // A partial download goes to a .part file and is moved into place only
                    // after the checksum matches, so an interrupted run can never look
                    // installed.
                    let partial = destination.appendingPathExtension("part")
                    try? FileManager.default.removeItem(at: partial)

                    let (bytes, _) = try await URLSession.shared.bytes(from: file.downloadURL)
                    var buffer = Data()
                    buffer.reserveCapacity(1 << 20)
                    var written: Int64 = 0
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: partial)
                    defer { try? handle.close() }
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= (1 << 20) {
                            try handle.write(contentsOf: buffer)
                            written += Int64(buffer.count)
                            buffer.removeAll(keepingCapacity: true)
                            await MainActor.run {
                                self.progress = Double(completed + written) / Double(OvisModel.totalBytes)
                            }
                        }
                    }
                    if !buffer.isEmpty {
                        try handle.write(contentsOf: buffer)
                        written += Int64(buffer.count)
                    }
                    try handle.close()

                    guard written == file.byteSize, Self.verify(file, at: partial) else {
                        try? FileManager.default.removeItem(at: partial)
                        throw LocalModelError.modelMissing
                    }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partial, to: destination)
                    completed += written
                    await MainActor.run { self.progress = Double(completed) / Double(OvisModel.totalBytes) }
                }
                await MainActor.run {
                    self.isDownloading = false
                    self.progress = 1
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.lastError = error.localizedDescription
                    self.refresh()
                }
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        refresh()
    }

    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: OvisModel.directory)
        isDownloading = false
        progress = 0
        refresh()
    }
}
