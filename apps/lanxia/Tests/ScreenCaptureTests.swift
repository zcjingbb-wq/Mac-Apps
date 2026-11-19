import Foundation
import AppKit
import ImageIO

@MainActor
private final class SyntheticScreenCaptureDriver: ScreenCaptureDriver {
    struct Request {
        let selected: () -> Void
        let completed: (Result<CGImage, ScreenCaptureFailure>) -> Void
    }
    private(set) var requests: [Request] = []
    private(set) var cancellationCount = 0

    func chooseContent(onSelection: @escaping () -> Void,
                       completion: @escaping (Result<CGImage, ScreenCaptureFailure>) -> Void) {
        requests.append(Request(selected: onSelection, completed: completion))
    }

    func cancel() { cancellationCount += 1 }

    func succeed(_ image: CGImage, request: Int? = nil) {
        let active = requests[request ?? requests.count - 1]
        active.selected()
        active.completed(.success(image))
    }
}

@main
struct ScreenCaptureTests {
    @MainActor private static var assertions = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        assertions += 1
    }

    private static func image(width: Int = 96, height: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 8, y: 12, width: 40, height: 4))
        return context.makeImage()!
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Synthetic lifecycle timed out")
    }

    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-ScreenCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let syntheticImage = image()
        let driver = SyntheticScreenCaptureDriver()
        let service = ScreenCaptureService(driver: driver, temporaryDirectory: folder)
        expect(driver.requests.isEmpty, "Initialization never chooses or captures content")
        expect(service.previewURL == nil && service.capturedAt == nil, "No screenshot exists at startup")
        expect(!service.isSelecting && !service.isCapturing && service.errorMessage == nil, "Initial idle state")
        expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "No capture directory is created before user action")

        service.chooseContent()
        expect(driver.requests.count == 1, "Each user choice invokes exactly one picker driver")
        expect(service.isSelecting && !service.isCapturing && service.previewURL == nil, "Choosing does not yet capture pixels")
        driver.requests[0].selected()
        expect(!service.isSelecting && service.isCapturing, "Only confirmed selection starts capture")
        driver.requests[0].completed(.success(syntheticImage))
        expect(!service.isSelecting && !service.isCapturing, "Single capture returns to idle")
        expect(service.errorMessage == nil && service.capturedAt != nil, "Successful preview has date and no error")
        let firstURL = service.previewURL!
        expect(firstURL.pathExtension == "png" && firstURL.isFileURL, "Preview is a local temporary PNG")
        expect(firstURL.path.hasPrefix(folder.path + "/StashCat-ScreenCapture-"), "Screenshot uses a uniquely owned temporary directory")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: firstURL.deletingLastPathComponent().path)
        expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Temporary PNG permissions are owner-only")
        expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Temporary directory is owner-only")
        let data = try Data(contentsOf: firstURL)
        expect(data.starts(with: [137, 80, 78, 71]), "Valid PNG signature")
        expect(data.count <= ScreenCaptureService.maximumPNGBytes, "PNG is within disk/memory limit")
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        expect(decoded.width == 96 && decoded.height == 64, "Stored image preserves synthetic content dimensions")
        expect(CGImageSourceGetCount(source) == 1, "Only one frame is stored")
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        expect(metadata[kCGImagePropertyGPSDictionary as String] == nil && exif[kCGImagePropertyExifUserComment as String] == nil && exif[kCGImagePropertyExifDateTimeOriginal as String] == nil, "No source path, GPS, user comments or original capture metadata is copied")
        expect(service.statusText.contains("由你确认"), "Preview does not imply an automatic AI submission")
        driver.requests[0].completed(.success(syntheticImage))
        expect(service.previewURL == firstURL, "Duplicate screenshot callbacks do not write a second file")
        print("PASS explicit selection, single PNG frame, private storage and no implicit AI submission")

        service.chooseContent()
        expect(driver.requests.count == 2, "A second screenshot requires a new selection")
        expect(!FileManager.default.fileExists(atPath: firstURL.path), "Reselecting deletes the old screenshot")
        expect(service.previewURL == nil && service.capturedAt == nil, "Old preview and timestamp are cleared before selecting")
        driver.requests[1].completed(.failure(.cancelled))
        expect(!service.isSelecting && !service.isCapturing && service.previewURL == nil, "Picker cancellation returns to idle without a picture")
        expect(service.errorMessage == nil && service.statusText.contains("取消"), "Human cancellation is not shown as an error")

        service.chooseContent()
        let stoppedRequest = driver.requests.count - 1
        driver.requests[stoppedRequest].selected()
        service.cancel()
        expect(!service.isSelecting && !service.isCapturing && service.previewURL == nil, "Stopping resets capture state")
        driver.requests[stoppedRequest].completed(.success(syntheticImage))
        expect(service.previewURL == nil && service.capturedAt == nil, "Late screenshot after stop is discarded")
        expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Late callback never writes a file")

        service.chooseContent()
        let oldRequest = driver.requests.count - 1
        service.chooseContent()
        let newRequest = driver.requests.count - 1
        driver.requests[oldRequest].selected()
        driver.requests[oldRequest].completed(.success(syntheticImage))
        expect(service.isSelecting && !service.isCapturing && service.previewURL == nil, "Old picker callbacks cannot affect a new request")
        driver.succeed(syntheticImage, request: newRequest)
        expect(service.previewURL != nil && !service.isSelecting, "New selection still completes successfully")
        let clearedURL = service.previewURL!
        service.clear()
        expect(service.previewURL == nil && service.capturedAt == nil, "Clear resets preview metadata")
        expect(!FileManager.default.fileExists(atPath: clearedURL.path), "Clear deletes the private screenshot")
        expect(!FileManager.default.fileExists(atPath: clearedURL.deletingLastPathComponent().path), "Clear removes its private directory too")
        expect(driver.cancellationCount > 0, "Cancel/clear actively stop the driver")
        print("PASS cancellation, clear, repeated selections and generation-safe late callback rejection")

        service.chooseContent()
        driver.requests.last!.completed(.success(syntheticImage))
        expect(service.previewURL == nil && service.errorMessage?.contains("系统选择器") == true, "Pixels cannot be accepted without this request's selection confirmation")
        expect(!service.isSelecting && !service.isCapturing, "Unconfirmed image returns to idle")
        for failure in [ScreenCaptureFailure.permissionDenied, .unavailable, .invalidContent, .invalidImage, .encodingFailed] {
            service.chooseContent()
            driver.requests.last!.completed(.failure(failure))
            expect(service.errorMessage == failure.localizedDescription, "Failures are translated into actionable UI messages")
            expect(!service.isSelecting && !service.isCapturing && service.previewURL == nil, "Failures never leave an active capture or old preview")
        }
        expect(ScreenCaptureFailure.permissionDenied.localizedDescription.contains("系统设置"), "Permission denial points to system settings")
        expect(ScreenCaptureFailure.permissionDenied.localizedDescription.contains("屏幕与系统音频录制"), "Permission denial identifies the correct settings area")
        expect(ScreenCaptureFailure.permissionDenied.localizedDescription.contains("退出"), "Permission denial explains possible relaunch")
        expect(ScreenCaptureFailure.captureError(NSError(domain: "SCStreamErrorDomain", code: -3801)) == .permissionDenied, "SCStream user-declined error is actionable")
        expect(ScreenCaptureFailure.captureError(NSError(domain: "Synthetic", code: 2)) == .unavailable, "Other capture errors do not leak raw paths or window names")

        service.chooseContent()
        driver.succeed(image(width: ScreenCaptureService.maximumImageEdge + 1, height: 1))
        expect(service.previewURL == nil && service.errorMessage == ScreenCaptureFailure.imageTooLarge.localizedDescription, "Oversized output is rejected before PNG allocation")
        expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "Rejected output leaves no screenshot")
        let blocked = folder.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocked)
        let storageDriver = SyntheticScreenCaptureDriver()
        let blockedStorage = ScreenCaptureService(driver: storageDriver, temporaryDirectory: blocked)
        blockedStorage.chooseContent()
        storageDriver.succeed(syntheticImage)
        expect(blockedStorage.previewURL == nil && blockedStorage.errorMessage == ScreenCaptureFailure.storageFailed.localizedDescription, "Storage failure is recoverable and exposes no partial URL")
        try FileManager.default.removeItem(at: blocked)
        print("PASS permission denial, invalid input, size bounds and storage failures")

        let selectingDriver = SyntheticScreenCaptureDriver()
        let selectingTimeout = ScreenCaptureService(driver: selectingDriver, temporaryDirectory: folder, selectionTimeout: 0.02)
        selectingTimeout.chooseContent()
        try await waitUntil { selectingTimeout.errorMessage != nil }
        expect(!selectingTimeout.isSelecting && !selectingTimeout.isCapturing, "Picker timeout stops its request")
        expect(selectingTimeout.errorMessage?.contains("选择器") == true, "Picker timeout identifies the waiting stage")
        selectingDriver.succeed(syntheticImage)
        expect(selectingTimeout.previewURL == nil, "Timed-out picker cannot later restore a screenshot")
        let captureDriver = SyntheticScreenCaptureDriver()
        let captureTimeout = ScreenCaptureService(driver: captureDriver, temporaryDirectory: folder, captureTimeout: 0.02)
        captureTimeout.chooseContent()
        captureDriver.requests[0].selected()
        try await waitUntil { captureTimeout.errorMessage != nil }
        expect(!captureTimeout.isSelecting && !captureTimeout.isCapturing, "Single capture timeout stops its request")
        expect(captureTimeout.errorMessage?.contains("单次截图") == true, "Capture timeout identifies the waiting stage")
        captureDriver.requests[0].completed(.success(syntheticImage))
        expect(captureTimeout.previewURL == nil, "Timed-out capture result cannot write a screenshot")
        print("PASS independent selection/capture timeouts and no late writes")

        expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 2_560, height: 1_440), pointPixelScale: 2) == CGSize(width: 2_560, height: 1_440), "5K Retina content is bounded before capture")
        expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 900, height: 1_600), pointPixelScale: 2) == CGSize(width: 1_440, height: 2_560), "Portrait aspect ratio stays intact")
        expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 96, height: 64), pointPixelScale: 1) == CGSize(width: 96, height: 64), "Small content is not upscaled")
        expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 0.25, height: 0.5), pointPixelScale: 1) == CGSize(width: 1, height: 1), "Subpixel content has positive integer output")
        for size in [CGSize.zero, CGSize(width: -1, height: 2), CGSize(width: 2, height: 0), CGSize(width: Double.nan, height: 2), CGSize(width: 2, height: Double.infinity)] {
            expect(ScreenCaptureService.boundedSize(contentSize: size, pointPixelScale: 1) == nil, "Invalid content geometry rejected")
        }
        for scale in [0.0, -1, Double.nan, Double.infinity] {
            expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 20, height: 20), pointPixelScale: scale) == nil, "Invalid pixel scaling rejected")
        }
        expect(ScreenCaptureService.boundedSize(contentSize: CGSize(width: 1e308, height: 10), pointPixelScale: 2) == nil, "Pixel multiplication overflow rejected")
        print("PASS allocation geometry and aspect-ratio bounds")

        let lifetimeDriver = SyntheticScreenCaptureDriver()
        var lifetime: ScreenCaptureService? = ScreenCaptureService(driver: lifetimeDriver, temporaryDirectory: folder)
        lifetime?.chooseContent()
        lifetimeDriver.succeed(syntheticImage)
        let lifetimeURL = lifetime!.previewURL!
        lifetime = nil
        expect(!FileManager.default.fileExists(atPath: lifetimeURL.path), "Releasing the service deletes its private screenshot")
        lifetimeDriver.requests[0].completed(.success(syntheticImage))
        expect(!FileManager.default.fileExists(atPath: lifetimeURL.path), "Callbacks after service release cannot recreate it")
        service.clear()
        selectingTimeout.clear()
        captureTimeout.clear()
        blockedStorage.clear()
        expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "All synthetic screenshots and private directories are removed")
        print("All \(assertions) ScreenCapture assertions passed. No real picker, authorization or screen capture was invoked.")
    }
}
