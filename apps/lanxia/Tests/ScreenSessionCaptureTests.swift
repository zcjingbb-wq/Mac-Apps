import Foundation
import AppKit
import ImageIO

@MainActor
private final class SyntheticSessionDriver: ScreenSessionCaptureDriver {
    struct Request {
        let selected: (ScreenWindowTarget?) -> Void
        let started: () -> Void
        let frame: (CGImage, Date, ScreenWindowTarget?) -> Void
        let idle: (Date, ScreenWindowTarget?) -> Void
        let stopped: (ScreenSessionFailure?) -> Void
    }
    private(set) var requests: [Request] = []
    private(set) var stops = 0
    var holdStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?

    func chooseContent(onSelection: @escaping (ScreenWindowTarget?) -> Void, onStarted: @escaping () -> Void,
                       onFrame: @escaping (CGImage, Date, ScreenWindowTarget?) -> Void,
                       onIdle: @escaping (Date, ScreenWindowTarget?) -> Void,
                       onStopped: @escaping (ScreenSessionFailure?) -> Void) {
        requests.append(Request(selected: onSelection, started: onStarted, frame: onFrame, idle: onIdle, stopped: onStopped))
    }
    func stop() async {
        stops += 1
        if holdStop { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func releaseStop() { holdStop = false; let waiter = stopWaiter; stopWaiter = nil; waiter?.resume() }
}

@main
struct ScreenSessionCaptureTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1
    }
    @MainActor private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Synthetic session lifecycle timed out")
    }
    private static func image(black: Bool = false, width: Int = 96, height: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor((black ? NSColor.black : NSColor.white).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StashCat-ScreenSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let white = image(), black = image(black: true)
        let clock = Date(timeIntervalSince1970: 1_792_570_000)
        let target = ScreenWindowTarget(pid: 123, windowID: 321, frame: CGRect(x: 90, y: 60, width: 900, height: 600), appName: "Synthetic App")
        let driver = SyntheticSessionDriver()
        let capture = ScreenSessionCapture(driver: driver, temporaryDirectory: directory)
        expect(driver.requests.isEmpty && driver.stops == 0, "Initialization never opens a picker or capture")
        expect(capture.latestFrame == nil && !capture.isRunning && !capture.isSelecting && !capture.isStopping, "Idle initial state")
        do { _ = try capture.leaseScreenshot(); preconditionFailure("Unselected session leased an image") }
        catch { expect(error as? ScreenSessionFailure == .noFrame, "No lease before user-selected observation") }
        capture.chooseContent()
        expect(capture.isSelecting && driver.requests.count == 1 && !capture.isRunning, "Explicit user choice starts exactly one picker")
        driver.requests[0].started()
        driver.requests[0].frame(white, clock, target)
        expect(!capture.isRunning && capture.latestFrame == nil, "Started/frame callbacks without a confirmed selection cannot observe")
        driver.requests[0].selected(target)
        driver.requests[0].started()
        expect(capture.isRunning && !capture.isSelecting && !capture.isStopping, "Confirmed system choice and started stream enable observation")
        driver.requests[0].frame(white, clock, target)
        let first = capture.latestFrame!
        expect(first.windowTarget == target && first.capturedAt == clock, "Selected window metadata remains associated with frame")
        expect(first.imageURL.pathExtension == "png", "Latest frame is one temporary PNG")
        let file = try FileManager.default.attributesOfItem(atPath: first.imageURL.path)
        let folder = try FileManager.default.attributesOfItem(atPath: first.imageURL.deletingLastPathComponent().path)
        expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Frame file owner-only")
        expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Frame directory owner-only")
        expect((try Data(contentsOf: first.imageURL)).count <= ScreenSessionCapture.maximumPNGBytes, "Encoded frame bounded")
        driver.requests[0].frame(black, clock.addingTimeInterval(1), target)
        expect(capture.latestFrame == first, "Frames are throttled to once every two seconds")
        driver.requests[0].frame(white, clock.addingTimeInterval(2), target)
        let same = capture.latestFrame!
        expect(same.id == first.id && same.sessionID == first.sessionID && same.imageURL == first.imageURL, "Unchanged content retains version ID and PNG without accumulating files")
        expect(same.capturedAt == clock.addingTimeInterval(2), "Repeated actual frame updates freshness")

        let lease = try capture.leaseScreenshot()
        expect(lease.id == same.id && lease.sessionID == same.sessionID && lease.windowTarget == target, "Lease preserves analyzed version/session/window identity")
        expect(lease.imageURL != same.imageURL && lease.imageURL.deletingLastPathComponent() != same.imageURL.deletingLastPathComponent(), "Lease owns a separate stable directory")
        expect(try Data(contentsOf: lease.imageURL) == Data(contentsOf: same.imageURL), "Lease pixels match analyzed frame")
        let leaseFile = try FileManager.default.attributesOfItem(atPath: lease.imageURL.path)
        let leaseDirectory = try FileManager.default.attributesOfItem(atPath: lease.imageURL.deletingLastPathComponent().path)
        expect((leaseFile[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (leaseDirectory[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Lease file/directory are private")
        driver.requests[0].frame(black, clock.addingTimeInterval(4), target)
        let changed = capture.latestFrame!
        expect(changed.id != first.id && changed.sessionID == first.sessionID, "Changed content gets a new version in same session")
        expect(changed.imageURL != first.imageURL && !FileManager.default.fileExists(atPath: first.imageURL.path), "Replacing a frame removes only the old original")
        expect(FileManager.default.fileExists(atPath: lease.imageURL.path), "In-flight analysis lease survives frame replacement")
        expect(try FileManager.default.contentsOfDirectory(atPath: changed.imageURL.deletingLastPathComponent().path).count == 1, "Only latest original PNG is retained")
        print("PASS explicit session selection, local 2-second throttle, stable content IDs and private bounded latest-only frame")

        driver.holdStop = true
        capture.stop()
        expect(capture.isStopping && !capture.isRunning && capture.latestFrame == nil, "Stop immediately disables observations and frame use")
        try await until { driver.stops == 1 }
        expect(FileManager.default.fileExists(atPath: changed.imageURL.path), "Original retained until stopCapture has actually completed")
        driver.requests[0].frame(white, clock.addingTimeInterval(6), target)
        expect(capture.latestFrame == nil, "Late frame after stop cannot return")
        driver.releaseStop()
        try await until { !capture.isStopping }
        expect(!FileManager.default.fileExists(atPath: changed.imageURL.path), "Original PNG deleted after complete stop")
        expect(FileManager.default.fileExists(atPath: lease.imageURL.path), "Stopping does not remove caller-owned analysis lease")
        expect(!capture.isRunning && !capture.isSelecting, "Completed stop remains idle")
        try FileManager.default.removeItem(at: lease.imageURL.deletingLastPathComponent())

        capture.chooseContent()
        expect(driver.requests.count == 2, "Restart requires a new system picker")
        driver.requests[0].selected(target); driver.requests[0].started()
        driver.requests[0].frame(white, clock.addingTimeInterval(8), target)
        expect(capture.latestFrame == nil && !capture.isRunning, "Prior-session callbacks cannot restart new session")
        driver.requests[1].selected(nil); driver.requests[1].started()
        driver.requests[1].frame(white, clock.addingTimeInterval(10), nil)
        let display = capture.latestFrame!
        expect(display.sessionID != first.sessionID && display.id != first.id, "Restart gets fresh session/content identities even for same pixels")
        expect(display.windowTarget == nil, "Display observation works without selected-application metadata")
        driver.holdStop = true
        capture.chooseContent()
        try await until { driver.stops == 2 }
        expect(capture.isStopping && driver.requests.count == 2, "Reselect waits for complete old stream stop before a new picker")
        driver.releaseStop()
        try await until { capture.isSelecting && driver.requests.count == 3 }
        expect(!FileManager.default.fileExists(atPath: display.imageURL.path), "Reselect clears the old original after stopping")
        driver.requests[2].stopped(.permissionDenied)
        try await until { !capture.isStopping }
        expect(!capture.isRunning && capture.latestFrame == nil, "Permission failure fully ends the session")
        expect(capture.errorMessage?.contains("屏幕与系统音频录制") == true, "Permission failure gives actionable settings path")
        print("PASS full asynchronous stop ordering, leases, reselect and strict session callback isolation")

        capture.chooseContent()
        driver.requests[3].selected(target); driver.requests[3].started()
        driver.requests[3].frame(white, clock.addingTimeInterval(12), target)
        let beforeClosed = capture.latestFrame!.imageURL
        driver.requests[3].stopped(.unavailable)
        try await until { !capture.isStopping }
        expect(!capture.isRunning && capture.latestFrame == nil && !FileManager.default.fileExists(atPath: beforeClosed.path), "System stop or closed window fully stops capture and deletes originals")
        capture.chooseContent()
        driver.requests[4].stopped(.cancelled)
        try await until { !capture.isStopping }
        expect(capture.errorMessage == nil && !capture.isRunning, "Human picker cancellation stops without error")
        capture.chooseContent()
        driver.requests[5].selected(target); driver.requests[5].started()
        driver.requests[5].frame(image(width: 2_561, height: 1), clock.addingTimeInterval(14), target)
        try await until { !capture.isStopping }
        expect(capture.latestFrame == nil && capture.errorMessage == ScreenSessionFailure.invalidContent.localizedDescription, "Oversized frame fails closed and stops session")

        let timedDriver = SyntheticSessionDriver()
        let timed = ScreenSessionCapture(driver: timedDriver, temporaryDirectory: directory, selectionTimeout: 0.02, startupTimeout: 0.02)
        timed.chooseContent()
        try await until { timed.errorMessage != nil && !timed.isStopping }
        expect(!timed.isSelecting && !timed.isRunning, "Selection timeout stops driver and goes idle")
        timedDriver.requests[0].selected(target); timedDriver.requests[0].started()
        timedDriver.requests[0].frame(white, clock, target)
        expect(timed.latestFrame == nil, "Timed-out session cannot produce a frame later")
        timed.chooseContent()
        timedDriver.requests[1].selected(target)
        try await until { timed.errorMessage != nil && !timed.isStopping }
        expect(!timed.isRunning && timed.latestFrame == nil, "Selected but never started stream times out")
        expect(ScreenSessionFailure.captureError(NSError(domain: "Synthetic", code: -3801)) == .permissionDenied, "TCC declined error translated")
        expect(ScreenSessionFailure.captureError(NSError(domain: "Synthetic", code: -1)) == .unavailable, "Other system stop errors translated without raw private details")
        print("PASS system stop, closed window, cancellation, capture bounds and selection/startup timeouts")

        let idleDriver = SyntheticSessionDriver()
        let idleSession = ScreenSessionCapture(driver: idleDriver, temporaryDirectory: directory)
        idleSession.chooseContent()
        idleDriver.requests[0].selected(target); idleDriver.requests[0].started()
        idleDriver.requests[0].idle(clock, target)
        expect(idleSession.latestFrame == nil, "Idle callback before a complete image cannot invent pixels")
        idleDriver.requests[0].frame(white, clock, target)
        let staticFrame = idleSession.latestFrame!
        let originalPNG = try Data(contentsOf: staticFrame.imageURL)
        let originalModification = try FileManager.default.attributesOfItem(atPath: staticFrame.imageURL.path)[.modificationDate] as? Date
        idleDriver.requests[0].idle(clock.addingTimeInterval(2), target)
        expect(idleSession.latestFrame?.id == staticFrame.id && idleSession.latestFrame?.imageURL == staticFrame.imageURL, "Valid real idle callback retains content identity and original PNG")
        expect(idleSession.latestFrame?.capturedAt == clock.addingTimeInterval(2), "Real idle callback refreshes observation timestamp")
        expect(try Data(contentsOf: staticFrame.imageURL) == originalPNG, "Idle does not rewrite PNG bytes")
        expect(try FileManager.default.attributesOfItem(atPath: staticFrame.imageURL.path)[.modificationDate] as? Date == originalModification, "Idle does not re-encode or touch the PNG")
        for _ in 0..<5 { await Task.yield() }
        expect(idleSession.latestFrame?.capturedAt == clock.addingTimeInterval(2), "No sample callback means no artificial freshness update")
        idleDriver.requests[0].idle(clock.addingTimeInterval(3), target)
        expect(idleSession.latestFrame?.capturedAt == clock.addingTimeInterval(2), "Idle callback obeys the same two-second throttle")
        idleSession.stop()
        try await until { !idleSession.isStopping }
        idleDriver.requests[0].idle(clock.addingTimeInterval(4), target)
        expect(idleSession.latestFrame == nil, "Old idle callback cannot restore a stopped session")

        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedParent)
        let failedDriver = SyntheticSessionDriver()
        let failedStorage = ScreenSessionCapture(driver: failedDriver, temporaryDirectory: blockedParent)
        failedStorage.chooseContent()
        failedDriver.requests[0].selected(nil); failedDriver.requests[0].started()
        failedDriver.requests[0].frame(white, clock, nil)
        try await until { !failedStorage.isStopping }
        expect(failedStorage.latestFrame == nil && !failedStorage.isRunning, "Disk failure stops capture instead of retaining an unsafe partial frame")
        expect(failedStorage.errorMessage == ScreenSessionFailure.storageFailed.localizedDescription, "Disk failure has a recoverable explanation")
        try FileManager.default.removeItem(at: blockedParent)
        print("PASS real idle freshness without re-encoding or timer fabrication, and storage failure cleanup")

        expect(ScreenSessionCapture.boundedSize(CGSize(width: 2_560, height: 1_440), scale: 2) == CGSize(width: 2_560, height: 1_440), "Retina allocation capped preserving aspect")
        expect(ScreenSessionCapture.boundedSize(CGSize(width: 96, height: 64), scale: 1) == CGSize(width: 96, height: 64), "Small frames are not upscaled")
        expect(ScreenSessionCapture.boundedSize(CGSize(width: 900, height: 1_600), scale: 2) == CGSize(width: 1_440, height: 2_560), "Portrait allocation capped")
        for invalid in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: Double.infinity, height: 10), CGSize(width: 10, height: Double.nan)] {
            expect(ScreenSessionCapture.boundedSize(invalid, scale: 1) == nil, "Invalid geometry rejected")
        }
        for invalid in [0.0, -1, .infinity, .nan] { expect(ScreenSessionCapture.boundedSize(CGSize(width: 10, height: 10), scale: invalid) == nil, "Invalid scale rejected") }
        capture.stop(); timed.stop(); idleSession.stop(); failedStorage.stop()
        try await until { !capture.isStopping && !timed.isStopping && !idleSession.isStopping && !failedStorage.isStopping }
        expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "No session originals or leases remain after callers clean up")
        print("All \(checks) ScreenSessionCapture checks passed. No real picker, screen capture, authorization or input events were used.")
    }
}
