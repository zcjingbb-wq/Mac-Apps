import Foundation
import Combine
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Information from the user's system-picker selection, retained only in memory
/// for frame association and the application name shown with the preview.
struct ScreenWindowTarget: Equatable, Sendable {
    let pid: Int32
    let windowID: UInt32
    let frame: CGRect
    let appName: String
}

struct ScreenSessionFrame: Equatable, Sendable {
    /// A content version: unchanged PNG pixels retain this ID within the same session.
    let id: UUID
    let sessionID: UUID
    let imageURL: URL
    let capturedAt: Date
    let windowTarget: ScreenWindowTarget?
}

enum ScreenSessionFailure: Error, LocalizedError, Equatable {
    case cancelled, permissionDenied, unavailable, invalidContent, storageFailed, noFrame
    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消系统屏幕选择。"
        case .permissionDenied: return "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 Wings，必要时退出后重开，再主动选择内容。"
        case .unavailable: return "屏幕共享已结束，或所选窗口已关闭。再次观察需要重新选择。"
        case .invalidContent: return "所选画面无效或过大，请选择其他窗口。"
        case .storageFailed: return "临时画面未能保存，请检查可用空间和文件夹权限。"
        case .noFrame: return "当前没有可用的观察画面，请重新选择并等待画面出现。"
        }
    }
    static func captureError(_ error: Error) -> ScreenSessionFailure {
        (error as NSError).code == -3801 ? .permissionDenied : .unavailable
    }
}

@MainActor
protocol ScreenSessionCaptureDriver: AnyObject {
    func chooseContent(onSelection: @escaping (ScreenWindowTarget?) -> Void,
                       onStarted: @escaping () -> Void,
                       onFrame: @escaping (CGImage, Date, ScreenWindowTarget?) -> Void,
                       onIdle: @escaping (Date, ScreenWindowTarget?) -> Void,
                       onStopped: @escaping (ScreenSessionFailure?) -> Void)
    /// Returns only after capture has stopped and the picker/observer are released.
    func stop() async
}

/// Explicitly started, local-only observation of the system-picker selection.
@MainActor
final class ScreenSessionCapture: NSObject, ObservableObject {
    @Published private(set) var latestFrame: ScreenSessionFrame?
    @Published private(set) var isSelecting = false
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var statusText = "选择窗口或显示器后，才开始本地屏幕观察。"
    @Published var errorMessage: String?

    static let maximumImageEdge = 2_560
    static let maximumPNGBytes = 12 * 1_024 * 1_024
    static let frameInterval: TimeInterval = 2
    private let driver: ScreenSessionCaptureDriver
    private let temporaryParent: URL
    private let storageDirectory: URL
    private let selectionTimeout: TimeInterval
    private let startupTimeout: TimeInterval
    private var generation = UUID()
    private var selected = false
    private var transitionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var lastDigest: Data?
    private var lastDeliveredAt: Date?

    init(driver: ScreenSessionCaptureDriver? = nil, temporaryDirectory: URL? = nil,
         selectionTimeout: TimeInterval = 120, startupTimeout: TimeInterval = 20) {
        self.driver = driver ?? NativeScreenSessionDriver()
        temporaryParent = temporaryDirectory ?? FileManager.default.temporaryDirectory
        storageDirectory = temporaryParent.appendingPathComponent("StashCat-ScreenSession-\(UUID().uuidString)", isDirectory: true)
        self.selectionTimeout = Self.safeTimeout(selectionTimeout, fallback: 120)
        self.startupTimeout = Self.safeTimeout(startupTimeout, fallback: 20)
        super.init()
    }

    deinit {
        timeoutTask?.cancel()
        let oldDriver = driver
        let oldDirectory = storageDirectory
        Task { @MainActor in
            await oldDriver.stop()
            try? FileManager.default.removeItem(at: oldDirectory)
        }
    }

    func chooseContent() {
        let wasActive = isRunning || isSelecting || isStopping || transitionTask != nil
        generation = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
        selected = false
        isRunning = false
        isSelecting = false
        latestFrame = nil
        lastDigest = nil
        lastDeliveredAt = nil
        errorMessage = nil
        if wasActive { transition(restart: true) }
        else {
            try? FileManager.default.removeItem(at: storageDirectory)
            beginSelection(identity: generation)
        }
    }

    func stop() {
        generation = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
        selected = false
        isRunning = false
        isSelecting = false
        latestFrame = nil
        lastDigest = nil
        lastDeliveredAt = nil
        errorMessage = nil
        transition(restart: false)
    }

    /// The returned PNG is an independent stable copy. Its caller owns the enclosing
    /// uniquely named directory and must delete it after analysis. Stopping this service
    /// or replacing its latest frame never removes a leased image.
    func leaseScreenshot() throws -> ScreenSessionFrame {
        guard isRunning, let frame = latestFrame, frame.sessionID == generation,
              FileManager.default.fileExists(atPath: frame.imageURL.path) else { throw ScreenSessionFailure.noFrame }
        let directory = temporaryParent.appendingPathComponent("StashCat-ScreenLease-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent("frame.png")
            try FileManager.default.copyItem(at: frame.imageURL, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return ScreenSessionFrame(id: frame.id, sessionID: frame.sessionID, imageURL: destination,
                                      capturedAt: frame.capturedAt, windowTarget: frame.windowTarget)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ScreenSessionFailure.storageFailed
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    static func boundedSize(_ size: CGSize, scale: Double) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let width = size.width * scale, height = size.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let factor = min(1, Double(maximumImageEdge) / max(width, height))
        return CGSize(width: max(1, floor(width * factor)), height: max(1, floor(height * factor)))
    }

    private static func safeTimeout(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 && value <= 600 ? value : fallback
    }

    private func beginSelection(identity: UUID) {
        guard generation == identity else { return }
        isStopping = false
        isSelecting = true
        statusText = "请通过系统选择器确认要持续观察的窗口或显示器。"
        armTimeout(selectionTimeout, identity: identity)
        driver.chooseContent(onSelection: { [weak self] _ in
            guard let self, self.generation == identity, self.isSelecting else { return }
            self.selected = true
            self.statusText = "正在开始本地观察…"
            self.armTimeout(self.startupTimeout, identity: identity)
        }, onStarted: { [weak self] in
            guard let self, self.generation == identity, self.selected, self.isSelecting else { return }
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.isSelecting = false
            self.isRunning = true
            self.statusText = "正在本地观察，每 2 秒更新最新画面；可随时停止。"
        }, onFrame: { [weak self] image, date, target in
            guard let self, self.generation == identity, self.selected, self.isRunning else { return }
            self.accept(image: image, capturedAt: date, target: target, identity: identity)
        }, onIdle: { [weak self] date, target in
            guard let self, self.generation == identity, self.selected, self.isRunning,
                  let previous = self.latestFrame, previous.sessionID == identity,
                  date.timeIntervalSince1970.isFinite else { return }
            if let last = self.lastDeliveredAt, date.timeIntervalSince(last) < Self.frameInterval { return }
            // Only a real valid idle sample invokes this path. No timer assumes the
            // screen is still current, and no PNG encoding/copying is needed.
            self.latestFrame = ScreenSessionFrame(id: previous.id, sessionID: identity, imageURL: previous.imageURL,
                                                  capturedAt: date, windowTarget: target)
            self.lastDeliveredAt = date
        }, onStopped: { [weak self] failure in
            guard let self, self.generation == identity else { return }
            self.generation = UUID()
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.selected = false
            self.isSelecting = false
            self.isRunning = false
            self.latestFrame = nil
            self.errorMessage = failure == .cancelled ? nil : failure?.localizedDescription
            self.transition(restart: false, preserveError: true)
        })
    }

    private func transition(restart: Bool, preserveError: Bool = false) {
        let identity = generation
        let previous = transitionTask
        isStopping = true
        statusText = "正在停止屏幕共享…"
        transitionTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.driver.stop()
            guard self.generation == identity else { return }
            try? FileManager.default.removeItem(at: self.storageDirectory)
            self.transitionTask = nil
            self.isStopping = false
            self.lastDigest = nil
            self.lastDeliveredAt = nil
            if restart { self.beginSelection(identity: identity) }
            else {
                if !preserveError { self.errorMessage = nil }
                self.statusText = "已停止屏幕观察；再次开始需要重新选择。"
            }
        }
    }

    private func armTimeout(_ seconds: TimeInterval, identity: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == identity, self.isSelecting else { return }
            self.generation = UUID()
            self.selected = false
            self.isSelecting = false
            self.errorMessage = "屏幕选择或启动等待超时，请重新选择。"
            self.transition(restart: false, preserveError: true)
        }
    }

    private func accept(image: CGImage, capturedAt: Date, target: ScreenWindowTarget?, identity: UUID) {
        guard capturedAt.timeIntervalSince1970.isFinite else { return }
        if let lastDeliveredAt, capturedAt.timeIntervalSince(lastDeliveredAt) < Self.frameInterval { return }
        do {
            let data = try Self.png(image)
            let digest = Data(SHA256.hash(data: data))
            if digest == lastDigest, let previous = latestFrame {
                latestFrame = ScreenSessionFrame(id: previous.id, sessionID: identity, imageURL: previous.imageURL,
                                                 capturedAt: capturedAt, windowTarget: target)
            } else {
                try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let destination = storageDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let previous = latestFrame?.imageURL
                latestFrame = ScreenSessionFrame(id: UUID(), sessionID: identity, imageURL: destination,
                                                 capturedAt: capturedAt, windowTarget: target)
                if let previous { try? FileManager.default.removeItem(at: previous) }
                lastDigest = digest
            }
            self.lastDeliveredAt = capturedAt
        } catch {
            generation = UUID()
            selected = false
            isRunning = false
            latestFrame = nil
            errorMessage = (error as? ScreenSessionFailure)?.localizedDescription ?? ScreenSessionFailure.storageFailed.localizedDescription
            transition(restart: false, preserveError: true)
        }
    }

    private static func png(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0, image.width <= maximumImageEdge, image.height <= maximumImageEdge,
              image.bytesPerRow > 0, image.bytesPerRow <= 64 * 1_024 * 1_024 / image.height else { throw ScreenSessionFailure.invalidContent }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ScreenSessionFailure.invalidContent }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= maximumPNGBytes else { throw ScreenSessionFailure.invalidContent }
        return data as Data
    }
}

@MainActor
private final class NativeScreenSessionDriver: ScreenSessionCaptureDriver {
    private var session: NativeScreenSession?
    func chooseContent(onSelection: @escaping (ScreenWindowTarget?) -> Void, onStarted: @escaping () -> Void,
                       onFrame: @escaping (CGImage, Date, ScreenWindowTarget?) -> Void,
                       onIdle: @escaping (Date, ScreenWindowTarget?) -> Void,
                       onStopped: @escaping (ScreenSessionFailure?) -> Void) {
        guard session == nil else { onStopped(.unavailable); return }
        let current = NativeScreenSession(onSelection: onSelection, onStarted: onStarted, onFrame: onFrame, onIdle: onIdle, onStopped: onStopped)
        session = current
        current.present()
    }
    func stop() async {
        let previous = session
        await previous?.stop()
        if session === previous { session = nil }
    }
}

@MainActor
private final class NativeScreenSession: NSObject, SCContentSharingPickerObserver, SCStreamDelegate {
    private var onSelection: ((ScreenWindowTarget?) -> Void)?
    private var onStarted: (() -> Void)?
    private var onFrame: ((CGImage, Date, ScreenWindowTarget?) -> Void)?
    private var onIdle: ((Date, ScreenWindowTarget?) -> Void)?
    private var onStopped: ((ScreenSessionFailure?) -> Void)?
    private var target: ScreenWindowTarget?
    private var stream: SCStream?
    private var output: ScreenSessionOutput?
    private var startupTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var finishing = false
    private var didSelect = false
    private var observing = false
    private var reportedStop = false

    init(onSelection: @escaping (ScreenWindowTarget?) -> Void, onStarted: @escaping () -> Void,
         onFrame: @escaping (CGImage, Date, ScreenWindowTarget?) -> Void,
         onIdle: @escaping (Date, ScreenWindowTarget?) -> Void,
         onStopped: @escaping (ScreenSessionFailure?) -> Void) {
        self.onSelection = onSelection; self.onStarted = onStarted
        self.onFrame = onFrame; self.onIdle = onIdle; self.onStopped = onStopped
        super.init()
    }

    func present() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        if let identifier = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [identifier] }
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        observing = true
        picker.isActive = true
        NSApp.activate()
        picker.present()
    }

    func stop() async {
        if let stoppingTask { await stoppingTask.value; return }
        finishing = true
        output?.deactivate()
        startupTask?.cancel()
        let pendingStartup = startupTask
        let task = Task {
            // If startCapture is already awaiting the framework, wait for it to settle
            // before stopping and releasing the stream or picker authorization.
            if let pendingStartup { await pendingStartup.value }
            if let stream = self.stream {
                try? await stream.stopCapture()
                if let output = self.output { try? stream.removeStreamOutput(output, type: .screen) }
            }
            self.stream = nil
            self.output = nil
            self.startupTask = nil
            let picker = SCContentSharingPicker.shared
            if self.observing { picker.remove(self); self.observing = false }
            picker.isActive = false
            self.onSelection = nil; self.onStarted = nil; self.onFrame = nil; self.onIdle = nil; self.onStopped = nil
        }
        stoppingTask = task
        await task.value
        stoppingTask = nil
    }

    private func reportStop(_ failure: ScreenSessionFailure?) {
        guard !finishing, !reportedStop else { return }
        reportedStop = true
        output?.deactivate()
        onStopped?(failure)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.reportStop(.cancelled) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.begin(filter) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let failure = ScreenSessionFailure.captureError(error)
        Task { @MainActor [weak self] in self?.reportStop(failure) }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let failure = ScreenSessionFailure.captureError(error)
        Task { @MainActor [weak self] in self?.reportStop(failure) }
    }

    private func begin(_ filter: SCContentFilter) {
        guard !finishing, !didSelect else { return }
        didSelect = true
        if #available(macOS 15.2, *), filter.style == .window,
           filter.includedWindows.count == 1, let window = filter.includedWindows.first,
           let app = window.owningApplication, app.processID > 0 {
            target = ScreenWindowTarget(pid: app.processID, windowID: window.windowID, frame: window.frame, appName: app.applicationName)
        }
        // Older systems can still observe the selected content without exposing
        // the selected application's name through this filter.
        onSelection?(target)
        guard let size = ScreenSessionCapture.boundedSize(filter.contentRect.size, scale: Double(filter.pointPixelScale)) else {
            reportStop(.invalidContent); return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width); configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(seconds: ScreenSessionCapture.frameInterval, preferredTimescale: 600)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
        let output = ScreenSessionOutput(onFrame: { [weak self] image, date in
            Task { @MainActor [weak self] in
                guard let self, !self.finishing, !self.reportedStop else { return }
                self.onFrame?(image, date, self.target)
            }
        }, onIdle: { [weak self] date in
            Task { @MainActor [weak self] in
                guard let self, !self.finishing, !self.reportedStop else { return }
                self.onIdle?(date, self.target)
            }
        }, onStopped: { [weak self] in
            Task { @MainActor [weak self] in self?.reportStop(.unavailable) }
        })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream; self.output = output
        do { try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue) }
        catch { reportStop(.captureError(error)); return }
        startupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !self.finishing, !Task.isCancelled else { return }
                try await stream.startCapture()
                guard !self.finishing, !Task.isCancelled else { return }
                self.onStarted?()
            } catch {
                guard !Task.isCancelled else { return }
                self?.reportStop(.captureError(error))
            }
        }
    }

}

/// All sample handling and pixel conversion happens on one dedicated queue. Deactivating
/// is lock-protected so frames already queued after stop cannot reach the UI.
private final class ScreenSessionOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.jingzicheng.stashcat.screen-session", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var lastDelivered = -Double.infinity
    private var hasImage = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CGImage, Date) -> Void
    private let onIdle: @Sendable (Date) -> Void
    private let onStopped: @Sendable () -> Void

    init(onFrame: @escaping @Sendable (CGImage, Date) -> Void,
         onIdle: @escaping @Sendable (Date) -> Void,
         onStopped: @escaping @Sendable () -> Void) {
        self.onFrame = onFrame; self.onIdle = onIdle; self.onStopped = onStopped
    }
    func deactivate() { lock.lock(); active = false; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? NSNumber,
              let status = SCFrameStatus(rawValue: rawStatus.intValue) else { return }
        lock.lock(); let isActive = active; lock.unlock()
        guard isActive else { return }
        if status == .stopped || status == .blank || status == .suspended { deactivate(); onStopped(); return }
        guard status == .complete || status == .idle else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDelivered >= 2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 2_560, height <= 2_560 else { deactivate(); onStopped(); return }
        if status == .idle, hasImage {
            lock.lock(); let stillActive = active; lock.unlock()
            guard stillActive else { return }
            lastDelivered = now
            onIdle(Date())
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let converted = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }
        lock.lock(); let stillActive = active; lock.unlock()
        guard stillActive else { return }
        lastDelivered = now
        hasImage = true
        onFrame(converted, Date())
    }
}
