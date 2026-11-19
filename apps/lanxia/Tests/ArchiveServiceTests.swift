import Darwin
import Foundation

private struct ArchiveTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ArchiveServiceTests {
    @MainActor private static var assertions = 0

    @MainActor
    static func main() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("StashCatArchiveTests-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let sources = base.appendingPathComponent("sources", isDirectory: true)
        let outputs = base.appendingPathComponent("outputs", isDirectory: true)
        try manager.createDirectory(at: sources, withIntermediateDirectories: false)
        try manager.createDirectory(at: outputs, withIntermediateDirectories: false)
        let first = sources.appendingPathComponent("first", isDirectory: true)
        let second = sources.appendingPathComponent("second", isDirectory: true)
        try manager.createDirectory(at: first, withIntermediateDirectories: false)
        try manager.createDirectory(at: second, withIntermediateDirectories: false)

        let alpha = first.appendingPathComponent("学习笔记.txt")
        let beta = second.appendingPathComponent("学习笔记.txt")
        let alphaData = Data("微积分：∫ x² dx = x³/3 + C\n原文件保留。".utf8)
        let betaData = Data("另一个同名文件，不能被覆盖。".utf8)
        try alphaData.write(to: alpha)
        try betaData.write(to: beta)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.setAttributes([.modificationDate: originalDate], ofItemAtPath: alpha.path)

        let folder = first.appendingPathComponent("资料", isDirectory: true)
        let nested = folder.appendingPathComponent("第 一章", isDirectory: true)
        let empty = folder.appendingPathComponent("空文件夹", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        let binary = nested.appendingPathComponent("内容.bin")
        let binaryData = Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 * 13) })
        try binaryData.write(to: binary)
        try Data("hidden settings".utf8).write(to: folder.appendingPathComponent(".隐藏配置"))
        let rootEmpty = first.appendingPathComponent("只有空目录", isDirectory: true)
        try manager.createDirectory(at: rootEmpty, withIntermediateDirectories: false)
        let secondFolder = second.appendingPathComponent("资料", isDirectory: true)
        try manager.createDirectory(at: secondFolder, withIntermediateDirectories: false)
        try Data("第二个文件夹".utf8).write(to: secondFolder.appendingPathComponent("条目.txt"))
        let dash = first.appendingPathComponent("-选项不能执行.txt")
        let dashData = Data("literal filename".utf8)
        try dashData.write(to: dash)
        let optionName = first.appendingPathComponent("-C")
        let newLine = first.appendingPathComponent("line\nbreak.txt")
        try dashData.write(to: optionName)
        try dashData.write(to: newLine)

        let service = ArchiveService()
        try require(!service.isCompressing && service.statusText.isEmpty && service.errorMessage == nil && service.outputURL == nil, "Initial feedback must be empty")
        let archive = outputs.appendingPathComponent("打包资料.zip")
        await service.compress(urls: [alpha, beta, folder, secondFolder, rootEmpty, dash, optionName, newLine], destination: archive)
        try require(!service.isCompressing && service.errorMessage == nil && service.outputURL?.standardizedFileURL == archive.resolvingSymlinksInPath().standardizedFileURL, "A real ZIP operation must finish successfully")
        let attributes = try manager.attributesOfItem(atPath: archive.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Published ZIP must be owner-only")
        let extracted = base.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let expectedRoot = ["学习笔记.txt", "学习笔记 2.txt", "资料", "资料 2", "只有空目录", "-选项不能执行.txt", "-C", "line\nbreak.txt"].sorted()
        try require(try manager.contentsOfDirectory(atPath: extracted.path).sorted() == expectedRoot, "ZIP root must contain user filenames, not UUID or staging wrapper directories")
        try require(try Data(contentsOf: extracted.appendingPathComponent("学习笔记.txt")) == alphaData, "First duplicate must preserve bytes")
        try require(try Data(contentsOf: extracted.appendingPathComponent("学习笔记 2.txt")) == betaData, "Second duplicate must be deterministically renamed with intact extension")
        try require(try Data(contentsOf: extracted.appendingPathComponent("资料/第 一章/内容.bin")) == binaryData, "Nested Unicode paths and binary bytes must round-trip")
        try require(try Data(contentsOf: extracted.appendingPathComponent("资料/.隐藏配置")) == Data("hidden settings".utf8), "Hidden files must be included")
        try require(try manager.contentsOfDirectory(atPath: extracted.appendingPathComponent("资料/空文件夹").path).isEmpty, "Nested empty folders must survive ZIP extraction")
        try require(try manager.contentsOfDirectory(atPath: extracted.appendingPathComponent("只有空目录").path).isEmpty, "Selected empty folders must survive ZIP extraction")
        try require(try Data(contentsOf: extracted.appendingPathComponent("资料 2/条目.txt")) == Data("第二个文件夹".utf8), "Duplicate folder basenames must remain separate")
        try require(try Data(contentsOf: extracted.appendingPathComponent(dash.lastPathComponent)) == dashData, "Names starting with a dash must be treated as literal filenames")
        try require(try Data(contentsOf: extracted.appendingPathComponent("-C")) == dashData, "A literal tar option must not be parsed from the filename list")
        try require(try Data(contentsOf: extracted.appendingPathComponent("line\nbreak.txt")) == dashData, "Newlines in filenames must survive the NUL-separated input list")
        let extractedDate = try manager.attributesOfItem(atPath: extracted.appendingPathComponent(alpha.lastPathComponent).path)[.modificationDate] as? Date
        try require(extractedDate.map { abs($0.timeIntervalSince(originalDate)) <= 2 } == true, "ZIP must preserve original modification dates within ZIP timestamp precision")
        let listing = try output("/usr/bin/unzip", ["-Z1", archive.path])
        try require(!listing.contains(base.path) && !listing.contains(".StashCat-archive-") && !listing.contains("__MACOSX"), "ZIP entries must not leak application paths, UUID wrappers, or metadata sidecars")
        // Python is a development-only independent ZIP reader here; the shipped
        // application uses only macOS's built-in tar/libarchive executable.
        let pythonCheck = try output("/usr/bin/env", ["python3", "-c", """
        import json, sys, zipfile
        with zipfile.ZipFile(sys.argv[1]) as archive:
            assert archive.testzip() is None
            infos = archive.infolist()
            print(json.dumps({
                "names": [info.filename for info in infos],
                "unicodeFlagged": all(info.flag_bits & 0x800 for info in infos if not info.filename.isascii())
            }))
        """, archive.path])
        let pythonResult = try JSONSerialization.jsonObject(with: Data(pythonCheck.utf8)) as? [String: Any]
        let pythonNames = pythonResult?["names"] as? [String]
        try require(pythonNames?.contains("学习笔记.txt") == true && pythonNames?.contains("学习笔记 2.txt") == true, "Generic ZIP readers must decode Chinese names correctly, without CP437 mojibake")
        try require(pythonNames?.contains("资料/第 一章/内容.bin") == true && pythonNames?.contains("只有空目录/") == true, "Generic ZIP readers must retain nested Unicode and empty-directory names")
        try require(pythonResult?["unicodeFlagged"] as? Bool == true, "Every non-ASCII ZIP entry must carry the standard UTF-8 encoding flag")
        try require(try Data(contentsOf: alpha) == alphaData && Data(contentsOf: beta) == betaData && Data(contentsOf: binary) == binaryData, "Every source must retain original bytes")
        let retainedDate = try manager.attributesOfItem(atPath: alpha.path)[.modificationDate] as? Date
        try require(retainedDate == originalDate, "Source timestamps must not be modified")
        try require(try noStagingRemains(in: outputs), "Successful compression must clean private staging")
        service.clearFeedback()
        try require(service.statusText.isEmpty && service.outputURL == nil && service.errorMessage == nil, "Feedback can be dismissed after completion")

        // Existing files, directories and broken symlinks are all protected.
        let sentinel = Data("existing file must survive".utf8)
        let existing = outputs.appendingPathComponent("existing.zip")
        try sentinel.write(to: existing)
        await service.compress(urls: [alpha], destination: existing)
        try require(service.errorMessage != nil && service.outputURL == nil, "Existing destinations must be rejected")
        try require(try Data(contentsOf: existing) == sentinel, "Existing destination bytes must remain untouched")
        let existingDirectory = outputs.appendingPathComponent("existing-directory.zip", isDirectory: true)
        try manager.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        await service.compress(urls: [alpha], destination: existingDirectory)
        try require(service.errorMessage != nil && service.outputURL == nil, "A directory at the destination must be rejected")
        let brokenDestination = outputs.appendingPathComponent("broken-destination.zip")
        try manager.createSymbolicLink(at: brokenDestination, withDestinationURL: outputs.appendingPathComponent("absent"))
        await service.compress(urls: [alpha], destination: brokenDestination)
        try require(service.errorMessage != nil && service.outputURL == nil, "Dangling destination links must not be replaced")
        try require(try manager.destinationOfSymbolicLink(atPath: brokenDestination.path) == outputs.appendingPathComponent("absent").path, "Dangling destination links must be preserved")

        let rejected = outputs.appendingPathComponent("must-not-exist.zip")
        await expectFailure(service, urls: [], destination: rejected, containing: "选择")
        await expectFailure(service, urls: [sources.appendingPathComponent("missing")], destination: rejected)
        await expectFailure(service, urls: [URL(string: "https://example.invalid/file")!], destination: rejected)
        await expectFailure(service, urls: [alpha], destination: outputs.appendingPathComponent("no-parent/file.zip"))
        await expectFailure(service, urls: [folder], destination: folder.appendingPathComponent("inside.zip"), containing: "内部")
        await expectFailure(service, urls: [alpha], destination: alpha)
        try require(try Data(contentsOf: alpha) == alphaData, "Rejecting output equal to source must preserve source bytes")
        let linkedOutputFolder = outputs.appendingPathComponent("linked-output", isDirectory: true)
        try manager.createSymbolicLink(at: linkedOutputFolder, withDestinationURL: folder)
        await expectFailure(service, urls: [folder], destination: linkedOutputFolder.appendingPathComponent("inside.zip"), containing: "内部")

        let fileLink = first.appendingPathComponent("file-link")
        try manager.createSymbolicLink(at: fileLink, withDestinationURL: alpha)
        await expectFailure(service, urls: [fileLink], destination: rejected, containing: "符号链接")
        let brokenLink = first.appendingPathComponent("broken-link")
        try manager.createSymbolicLink(at: brokenLink, withDestinationURL: first.appendingPathComponent("missing-target"))
        await expectFailure(service, urls: [brokenLink], destination: rejected, containing: "符号链接")
        let linkedTree = first.appendingPathComponent("nested-links", isDirectory: true)
        try manager.createDirectory(at: linkedTree, withIntermediateDirectories: false)
        try Data("valid before link".utf8).write(to: linkedTree.appendingPathComponent("a-valid.txt"))
        try manager.createSymbolicLink(at: linkedTree.appendingPathComponent("z-link"), withDestinationURL: folder)
        await expectFailure(service, urls: [linkedTree], destination: rejected, containing: "符号链接")
        let fifo = first.appendingPathComponent("pipe")
        try require(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0, "FIFO test fixture must be created")
        await expectFailure(service, urls: [fifo], destination: rejected, containing: "普通文件")
        let unreadable = first.appendingPathComponent("unreadable.txt")
        try Data("private".utf8).write(to: unreadable)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        await expectFailure(service, urls: [unreadable], destination: rejected, containing: "读取")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        try require(try noStagingRemains(in: outputs), "Rejected inputs must not leave partial archives or private staging")

        // Sparse contents make a large cancellable copy/deflate fixture without
        // downloading data or constructing a large in-memory allocation.
        let large = first.appendingPathComponent("large.bin")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()
        let cancelledOutput = outputs.appendingPathComponent("cancelled.zip")
        let cancelling = Task { await service.compress(urls: [large], destination: cancelledOutput) }
        try await waitUntilBusy(service)
        let busyStatus = service.statusText
        service.clearFeedback()
        try require(service.isCompressing && !service.statusText.isEmpty && !busyStatus.isEmpty, "Dismissing feedback must not hide an active operation")
        let ignored = outputs.appendingPathComponent("overlapping.zip")
        await service.compress(urls: [alpha], destination: ignored)
        try require(!manager.fileExists(atPath: ignored.path), "A second operation must not run concurrently")
        service.cancel()
        await cancelling.value
        try require(!service.isCompressing && service.errorMessage == nil && service.outputURL == nil && service.statusText.contains("取消"), "Cancelling copy must finish without an error alert")
        try require(!manager.fileExists(atPath: cancelledOutput.path), "Cancelled copy must not publish output")
        try require(try noStagingRemains(in: outputs), "Cancelled copy must clean staging")

        let childCancelledOutput = outputs.appendingPathComponent("child-cancelled.zip")
        let childCancelling = Task { await service.compress(urls: [large], destination: childCancelledOutput) }
        try await waitUntilGenerating(service)
        try await Task.sleep(for: .milliseconds(20))
        service.cancel()
        await childCancelling.value
        try require(!service.isCompressing && service.errorMessage == nil && service.outputURL == nil && service.statusText.contains("取消"), "Cancelling ZIP generation must finish without an error alert")
        try require(!manager.fileExists(atPath: childCancelledOutput.path), "Cancelled ZIP generation must not publish output")
        try require(try noStagingRemains(in: outputs), "Cancelled child process must clean staging")

        let raced = outputs.appendingPathComponent("race.zip")
        let racing = Task { await service.compress(urls: [large], destination: raced) }
        try await waitUntilGenerating(service)
        try sentinel.write(to: raced, options: .withoutOverwriting)
        await racing.value
        try require(service.outputURL == nil && service.errorMessage?.contains("同名") == true, "A destination created during compression must cause a safe failure")
        try require(try Data(contentsOf: raced) == sentinel, "Exclusive publication must never overwrite a racing destination")
        try require(try noStagingRemains(in: outputs), "Failed exclusive publication must clean staging")

        let recovered = outputs.appendingPathComponent("recovered.zip")
        await service.compress(urls: [alpha], destination: recovered)
        try await Task.sleep(for: .milliseconds(30))
        try require(service.outputURL?.lastPathComponent == recovered.lastPathComponent && service.errorMessage == nil && service.statusText.contains("已生成"), "A fresh operation must work after cancellation/failure and ignore old progress callbacks")
        try require(try manager.attributesOfItem(atPath: large.path)[.size] as? NSNumber == NSNumber(value: 128 * 1_024 * 1_024), "Cancellation must not truncate or remove the large source")
        print("PASS: \(assertions) archive checks; real ZIP/extraction, Unicode/binary/hidden/empty directories, duplicate names, timestamps, original preservation, link/special-file/recursion rejection, cancellation during copy and ZIP generation, exclusive destination publication and recovery")
    }

    @MainActor
    private static func expectFailure(_ service: ArchiveService, urls: [URL], destination: URL, containing text: String? = nil) async {
        await service.compress(urls: urls, destination: destination)
        assertions += 1
        precondition(!service.isCompressing && service.outputURL == nil && service.errorMessage != nil, "Expected rejection for \(destination.lastPathComponent)")
        if let text {
            assertions += 1
            precondition(service.errorMessage?.contains(text) == true, "Expected rejection mentioning \(text)")
        }
        if destination.lastPathComponent == "must-not-exist.zip" {
            assertions += 1
            precondition(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @MainActor
    private static func waitUntilBusy(_ service: ArchiveService) async throws {
        for _ in 0..<10_000 {
            if service.isCompressing { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ArchiveTestFailure(description: "Archive operation did not begin")
    }

    @MainActor
    private static func waitUntilGenerating(_ service: ArchiveService) async throws {
        try await waitUntilBusy(service)
        for _ in 0..<10_000 {
            if service.statusText == "正在生成 ZIP 压缩包…" { return }
            if !service.isCompressing { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ArchiveTestFailure(description: "Archive operation never reached ZIP generation: \(service.statusText) \(service.errorMessage ?? "")")
    }

    private static func noStagingRemains(in directory: URL) throws -> Bool {
        try !FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".StashCat-archive-") }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        _ = try output(executable, arguments)
    }

    private static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationReason == .exit && child.terminationStatus == 0 else {
            throw ArchiveTestFailure(description: "Fixture command failed: \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw ArchiveTestFailure(description: message) }
    }
}
