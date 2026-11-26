import Foundation
import Combine
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CoreVideo

enum ScreenCaptureFailure: Error, LocalizedError, Equatable {
    case cancelled
    case permissionDenied
    case unavailable
    case invalidContent
    case invalidImage
    case imageTooLarge
    case encodingFailed
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消屏幕选择。"
        case .permissionDenied:
            return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许羽，必要时退出 App 后重新打开，再主动选择要读取的窗口或显示器。"
        case .unavailable: return "无法读取所选内容。请确认窗口仍在显示，再重新选择。"
        case .invalidContent: return "所选窗口或显示器尺寸无效，请重新选择。"
        case .invalidImage: return "这次没有取得可用画面，请重新选择。"
        case .imageTooLarge: return "所选画面过大，无法安全生成临时图片，请选择较小的窗口。"
        case .encodingFailed: return "画面未能转换为图片，请重新选择。"
        case .storageFailed: return "临时图片未能保存，请检查可用空间和临时文件夹权限。"
        }
    }

    static func captureError(_ error: Error) -> ScreenCaptureFailure {
        // SCStreamErrorUserDeclined is -3801. Do not request or modify TCC here.
        (error as NSError).code == -3801 ? .permissionDenied : .unavailable
    }
}

/// No driver is invoked until the person presses the choose button. Every invocation
/// must present a fresh system picker; a previous filter is never reused.
@MainActor
protocol ScreenCaptureDriver: AnyObject {
    func chooseContent(onSelection: @escaping () -> Void,
                       completion: @escaping (Result<CGImage, ScreenCaptureFailure>) -> Void)
    func cancel()
}

/// A single user-selected screenshot with an in-memory lifetime and a private temporary
/// PNG. It never creates an SCStream, reads audio, polls the screen or sends content to AI.
@MainActor
final class ScreenCaptureService: NSObject, ObservableObject {
    @Published private(set) var previewURL: URL?
    @Published private(set) var capturedAt: Date?
    @Published private(set) var isSelecting = false
    @Published private(set) var isCapturing = false
    @Published var errorMessage: String?
    @Published private(set) var statusText = "主动选择一个窗口或显示器后，仅截取一次画面。"

    static let maximumImageEdge = 2_560
    static let maximumImagePixels = maximumImageEdge * maximumImageEdge
    static let maximumPNGBytes = 12 * 1_024 * 1_024

    private let driver: ScreenCaptureDriver
    private let storageDirectory: URL
    private let selectionTimeout: TimeInterval
    private let captureTimeout: TimeInterval
    private var generation = UUID()
    private var selectedGeneration: UUID?
    private var timeoutTask: Task<Void, Never>?

    init(driver: ScreenCaptureDriver? = nil, temporaryDirectory: URL? = nil,
         selectionTimeout: TimeInterval = 120, captureTimeout: TimeInterval = 20) {
        self.driver = driver ?? SystemScreenCaptureDriver()
        storageDirectory = (temporaryDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("StashCat-ScreenCapture-\(UUID().uuidString)", isDirectory: true)
        self.selectionTimeout = Self.validTimeout(selectionTimeout, fallback: 120)
        self.captureTimeout = Self.validTimeout(captureTimeout, fallback: 20)
        super.init()
    }

    deinit {
        timeoutTask?.cancel()
        try? FileManager.default.removeItem(at: storageDirectory)
        let oldDriver = driver
        Task { @MainActor in oldDriver.cancel() }
    }

    func chooseContent() {
        invalidate()
        errorMessage = nil
        isSelecting = true
        statusText = "请在系统选择器中确认要读取的窗口或显示器。"
        let identity = generation
        armTimeout(seconds: selectionTimeout, identity: identity, selecting: true)
        driver.chooseContent(onSelection: { [weak self] in
            guard let self, self.generation == identity, self.isSelecting else { return }
            self.selectedGeneration = identity
            self.isSelecting = false
            self.isCapturing = true
            self.statusText = "正在截取你刚选择的内容，仅此一次…"
            self.armTimeout(seconds: self.captureTimeout, identity: identity, selecting: false)
        }, completion: { [weak self] result in
            guard let self, self.generation == identity, self.isSelecting || self.isCapturing else { return }
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.isSelecting = false
            self.isCapturing = false
            switch result {
            case let .success(image):
                guard self.didConfirmSelection(identity) else { return }
                do {
                    self.previewURL = try self.saveTemporaryPNG(image)
                    self.capturedAt = Date()
                    self.statusText = "已截取一次画面。检查预览后，由你确认是否交给 AI 分析。"
                } catch {
                    self.removeTemporaryImage()
                    self.errorMessage = (error as? ScreenCaptureFailure)?.localizedDescription ?? ScreenCaptureFailure.storageFailed.localizedDescription
                    self.statusText = "截图未完成，请重新选择。"
                }
            case let .failure(error):
                self.errorMessage = error == .cancelled ? nil : error.localizedDescription
                self.statusText = error == .cancelled ? "已取消；没有读取屏幕内容。" : "截图未完成，请重新选择。"
            }
            self.driver.cancel()
        })
    }

    /// Cancelling also deletes a completed preview, so hiding/stopping the assistant
    /// does not leave a screenshot behind or allow a delayed callback to restore it.
    func cancel() {
        invalidate()
        errorMessage = nil
        statusText = "已停止；再次读取需要重新选择。"
    }

    func clear() {
        invalidate()
        errorMessage = nil
        statusText = "画面已清除。再次读取需要重新选择。"
    }

    /// This opens Settings only when invoked by a user-facing button. It does not
    /// request permission, change settings, or trigger another screenshot.
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func validTimeout(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 && value <= 600 ? value : fallback
    }

    /// Small pure geometry helper, also used to bound the native capture allocation.
    static func boundedSize(contentSize: CGSize, pointPixelScale: Double) -> CGSize? {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              pointPixelScale.isFinite, pointPixelScale > 0 else { return nil }
        let width = contentSize.width * pointPixelScale
        let height = contentSize.height * pointPixelScale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let factor = min(1, Double(maximumImageEdge) / max(width, height))
        return CGSize(width: max(1, floor(width * factor)), height: max(1, floor(height * factor)))
    }

    private func armTimeout(seconds: TimeInterval, identity: UUID, selecting: Bool) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == identity, self.isSelecting || self.isCapturing else { return }
            self.invalidate()
            self.errorMessage = selecting ? "系统选择器等待已超时，请重新点击并选择内容。" : "单次截图等待已超时，请确认窗口仍在显示后重试。"
            self.statusText = "本次读取已停止；需要重新选择。"
        }
    }

    private func invalidate() {
        generation = UUID()
        selectedGeneration = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        driver.cancel()
        isSelecting = false
        isCapturing = false
        removeTemporaryImage()
    }

    private func didConfirmSelection(_ identity: UUID) -> Bool {
        // The driver is trusted, but do not accept an image if its selection callback
        // never ran. A system selection is the required boundary for each request.
        guard generation == identity, selectedGeneration == identity else {
            errorMessage = "请先通过系统选择器确认要读取的内容。"
            statusText = "没有读取画面；请重新选择。"
            driver.cancel()
            return false
        }
        return true
    }

    private func removeTemporaryImage() {
        previewURL = nil
        capturedAt = nil
        // This directory is always uniquely created by this service, never a user path.
        try? FileManager.default.removeItem(at: storageDirectory)
    }

    private func saveTemporaryPNG(_ image: CGImage) throws -> URL {
        guard image.width > 0, image.height > 0 else { throw ScreenCaptureFailure.invalidImage }
        guard image.width <= Self.maximumImageEdge, image.height <= Self.maximumImageEdge,
              image.width <= Self.maximumImagePixels / image.height,
              image.bytesPerRow > 0, image.bytesPerRow <= 64 * 1_024 * 1_024 / image.height else {
            throw ScreenCaptureFailure.imageTooLarge
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenCaptureFailure.encodingFailed
        }
        // Re-encode image pixels only: no window title, source path or screen metadata.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureFailure.encodingFailed }
        guard data.length > 0, data.length <= Self.maximumPNGBytes else { throw ScreenCaptureFailure.imageTooLarge }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)
            let url = storageDirectory.appendingPathComponent("screen-\(UUID().uuidString).png")
            // The parent is private before data is written; then the file is restricted
            // to its owner before any URL is exposed to the rest of the application.
            guard !FileManager.default.fileExists(atPath: url.path) else { throw ScreenCaptureFailure.storageFailed }
            try (data as Data).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { throw ScreenCaptureFailure.storageFailed }
    }
}

@MainActor
private final class SystemScreenCaptureDriver: ScreenCaptureDriver {
    private var session: ScreenCapturePickerSession?

    func chooseContent(onSelection: @escaping () -> Void,
                       completion: @escaping (Result<CGImage, ScreenCaptureFailure>) -> Void) {
        cancel()
        let current = ScreenCapturePickerSession(onSelection: onSelection, completion: completion)
        session = current
        current.present()
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

/// A new observer object per request also rejects old picker callbacks after a new
/// request begins. No filter is retained for later user actions or background work.
@MainActor
private final class ScreenCapturePickerSession: NSObject, SCContentSharingPickerObserver {
    private var onSelection: (() -> Void)?
    private var completion: ((Result<CGImage, ScreenCaptureFailure>) -> Void)?
    private var didSelect = false
    private var finished = false
    private var observing = false
    private var captureTask: Task<Void, Never>?

    init(onSelection: @escaping () -> Void,
         completion: @escaping (Result<CGImage, ScreenCaptureFailure>) -> Void) {
        self.onSelection = onSelection
        self.completion = completion
        super.init()
    }

    func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        observing = true
        picker.isActive = true
        // The floating nonactivating panel may not have made this accessory app active.
        NSApp.activate()
        picker.present()
    }

    func cancel() {
        finished = true
        captureTask?.cancel()
        captureTask = nil
        onSelection = nil
        completion = nil
        stopPicker()
    }

    private func stopPicker() {
        let picker = SCContentSharingPicker.shared
        if observing { picker.remove(self); observing = false }
        picker.isActive = false
    }

    private func finish(_ result: Result<CGImage, ScreenCaptureFailure>) {
        guard !finished else { return }
        finished = true
        stopPicker()
        let callback = completion
        completion = nil
        onSelection = nil
        captureTask = nil
        callback?(result)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.finish(.failure(.cancelled)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.capture(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let failure = ScreenCaptureFailure.captureError(error)
        Task { @MainActor [weak self] in self?.finish(.failure(failure)) }
    }

    private func capture(_ filter: SCContentFilter) {
        guard !finished, !didSelect else { return }
        didSelect = true
        onSelection?()
        onSelection = nil
        guard let size = ScreenCaptureService.boundedSize(contentSize: filter.contentRect.size,
                                                          pointPixelScale: Double(filter.pointPixelScale)) else {
            finish(.failure(.invalidContent)); return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
        captureTask = Task { [weak self] in
            do {
                // Give the system's picker confirmation UI time to disappear from a
                // selected display. This is cancellable and still captures only once.
                try await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard !Task.isCancelled else { return }
                self?.finish(.success(image))
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(.failure(ScreenCaptureFailure.captureError(error)))
            }
        }
    }
}
