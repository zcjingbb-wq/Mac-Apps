import Combine
import Darwin
import Foundation

/// Creates a ZIP from explicitly selected items. The originals are opened only
/// for reading; a completed archive is published without replacing any file.
@MainActor
final class ArchiveService: ObservableObject {
    static let shared = ArchiveService()

    @Published private(set) var isCompressing = false
    @Published private(set) var statusText = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputURL: URL?

    private var operationID: UUID?
    private var operation: ArchiveOperation?

    func compress(urls: [URL], destination: URL) async {
        guard !isCompressing, !Task.isCancelled else { return }
        let id = UUID()
        let state = ArchiveOperation()
        operationID = id
        operation = state
        isCompressing = true
        statusText = "正在准备压缩…"
        errorMessage = nil
        outputURL = nil

        let progress: @Sendable (String) -> Void = { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id, !state.isCancelled else { return }
                self.statusText = phase
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            try ArchiveWorker.create(sources: urls, destination: destination, operation: state, progress: progress)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                state.cancel()
            }
            guard operationID == id else { return }
            outputURL = result
            statusText = "已生成「\(ArchiveWorker.label(result.lastPathComponent))」· 原文件已保留"
        } catch {
            guard operationID == id else { return }
            if state.isCancelled || error is CancellationError {
                statusText = "已取消压缩"
            } else {
                statusText = "压缩未完成"
                errorMessage = String(error.localizedDescription.prefix(500))
            }
        }
        guard operationID == id else { return }
        operationID = nil
        operation = nil
        isCompressing = false
    }

    func cancel() {
        guard let operation else { return }
        if operation.cancel() { statusText = "正在取消压缩…" }
    }

    func clearFeedback() {
        guard !isCompressing else { return }
        statusText = ""
        errorMessage = nil
        outputURL = nil
    }
}

/// Shared with the background copy/process worker. Publishing and cancellation
/// use the same lock: cancellation can never leave a partially published ZIP.
private final class ArchiveOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var published = false
    private var process: Process?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    @discardableResult
    func cancel() -> Bool {
        let active: Process? = lock.withLock {
            guard !published else { return nil }
            cancelled = true
            return process
        }
        if let active, active.isRunning {
            active.terminate()
            // bsdtar normally exits on SIGTERM. Bound cancellation even if a
            // filesystem operation delays its normal termination handler.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, active] in
                guard let self else { return }
                self.lock.withLock {
                    guard self.cancelled, self.process === active, active.isRunning else { return }
                    _ = Darwin.kill(active.processIdentifier, SIGKILL)
                }
            }
        }
        return isCancelled
    }

    func run(_ child: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try child.run()
            process = child
        }
        child.waitUntilExit()
        lock.withLock { if process === child { process = nil } }
        try checkCancellation()
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            throw ArchiveFailure.compressionFailed
        }
    }

    func publish(_ staged: URL, to destination: URL) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            let result = staged.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else {
                if errno == EEXIST { throw ArchiveFailure.destinationExists }
                throw ArchiveFailure.cannotSave
            }
            published = true
        }
    }
}

private enum ArchiveFailure: LocalizedError {
    case noSources
    case invalidSource(String)
    case unreadable(String)
    case symbolicLink(String)
    case specialFile(String)
    case changed(String)
    case destinationExists
    case invalidDestination
    case recursiveDestination
    case cannotStage
    case cannotSave
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .noSources: return "请先选择要压缩的文件或文件夹。"
        case .invalidSource(let name): return "「\(name)」已不存在，或不是可读取的本地文件。"
        case .unreadable(let name): return "无法完整读取「\(name)」。请检查读取权限后重试。"
        case .symbolicLink(let name): return "「\(name)」是符号链接。请改选它指向的实际文件；包含符号链接的文件夹也暂不支持。"
        case .specialFile(let name): return "「\(name)」不是普通文件或文件夹，暂不支持压缩。"
        case .changed(let name): return "压缩时「\(name)」发生了变化，请等文件保存完成后重试。"
        case .destinationExists: return "保存位置已存在同名项目，请换一个名称。现有文件未被覆盖。"
        case .invalidDestination: return "保存位置不可用，请选择一个已有且可写的文件夹。"
        case .recursiveDestination: return "压缩包不能保存到正在压缩的文件夹内部，也不能使用原文件的位置。请另选保存位置。"
        case .cannotStage: return "无法准备压缩副本，请检查目标磁盘空间和写入权限。原文件已保留。"
        case .cannotSave: return "无法保存压缩包，请检查目标磁盘空间和写入权限。原文件已保留。"
        case .compressionFailed: return "系统未能完成 ZIP 压缩，请检查磁盘空间后重试。原文件已保留。"
        }
    }
}

private enum ArchiveWorker {
    private struct Input {
        let url: URL
        let name: String
        let metadata: stat
    }

    static func create(
        sources: [URL], destination: URL, operation: ArchiveOperation,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        guard !sources.isEmpty else { throw ArchiveFailure.noSources }
        try operation.checkCancellation()
        let accessed = sources.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let destinationAccessed = destination.startAccessingSecurityScopedResource()
        defer {
            for (url, active) in accessed where active { url.stopAccessingSecurityScopedResource() }
            if destinationAccessed { destination.stopAccessingSecurityScopedResource() }
        }

        let target = try outputLocation(destination)
        let inputs = try sources.map { source -> Input in
            try operation.checkCancellation()
            guard source.isFileURL, !source.lastPathComponent.isEmpty,
                  !["/", ".", ".."].contains(source.lastPathComponent) else {
                throw ArchiveFailure.invalidSource(label(source.lastPathComponent))
            }
            let source = source.standardizedFileURL
            let metadata = try inspect(path: source.path, name: source.lastPathComponent)
            let canonical = source.resolvingSymlinksInPath().standardizedFileURL.path
            guard target.path != canonical,
                  !(kind(metadata) == S_IFDIR && includes(parent: canonical, child: target.path)) else {
                throw ArchiveFailure.recursiveDestination
            }
            return Input(url: source, name: source.lastPathComponent, metadata: metadata)
        }

        let manager = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent(".StashCat-archive-" + UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw ArchiveFailure.cannotStage }
        defer { try? manager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("contents", isDirectory: true)
        do {
            try manager.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw ArchiveFailure.cannotStage }

        var reservedNames: Set<String> = []
        var entryNames: [String] = []
        for (index, input) in inputs.enumerated() {
            try operation.checkCancellation()
            progress("正在准备副本 \(index + 1)/\(inputs.count)：\(label(input.name))")
            let unique = uniqueName(input.name, isDirectory: kind(input.metadata) == S_IFDIR, reserved: &reservedNames)
            entryNames.append(unique)
            let fd = input.url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard fd >= 0 else { throw openFailure(name: input.name) }
            defer { Darwin.close(fd) }
            try copyNode(fd: fd, expected: input.metadata, to: contents.appendingPathComponent(unique), name: input.name, depth: 0, operation: operation)
        }

        try operation.checkCancellation()
        progress("正在生成 ZIP 压缩包…")
        let payload = staging.appendingPathComponent("archive.zip")
        let entries = staging.appendingPathComponent("entries")
        var entryData = Data()
        for name in entryNames {
            entryData.append(contentsOf: name.utf8)
            entryData.append(0)
        }
        do {
            try entryData.write(to: entries, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entries.path)
        } catch { throw ArchiveFailure.cannotStage }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        child.arguments = [
            "-c", "--format=zip", "--options", "zip:hdrcharset=UTF-8",
            "--no-mac-metadata", "--no-acls", "--no-xattrs", "--no-fflags",
            "-f", payload.path, "-C", contents.path, "--null", "-T", entries.path
        ]
        child.currentDirectoryURL = contents
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // macOS ditto writes UTF-8 names without ZIP's UTF-8 flag, which generic
        // readers decode as CP437. The system libarchive ZIP writer sets the
        // flag explicitly. A NUL-separated input list preserves literal names
        // (including '-C' or newlines) without shell/argument interpretation.
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try operation.run(child)
        try operation.checkCancellation()
        guard manager.fileExists(atPath: payload.path) else { throw ArchiveFailure.compressionFailed }
        do { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path) }
        catch { throw ArchiveFailure.cannotSave }
        try operation.publish(payload, to: target)
        return target
    }

    private static func outputLocation(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.lastPathComponent.isEmpty,
              !["/", ".", ".."].contains(url.lastPathComponent) else { throw ArchiveFailure.invalidDestination }
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        var metadata = stat()
        guard parent.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              kind(metadata) == S_IFDIR,
              FileManager.default.isWritableFile(atPath: parent.path) else { throw ArchiveFailure.invalidDestination }
        let result = parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL
        var existing = stat()
        let exists = result.path.withCString { Darwin.lstat($0, &existing) }
        guard exists != 0 else { throw ArchiveFailure.destinationExists }
        guard errno == ENOENT else { throw ArchiveFailure.invalidDestination }
        return result
    }

    private static func inspect(path: String, name: String) throws -> stat {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else { throw ArchiveFailure.invalidSource(label(name)) }
        try validateKind(metadata, name: name)
        return metadata
    }

    private static func validateKind(_ metadata: stat, name: String) throws {
        if kind(metadata) == S_IFLNK { throw ArchiveFailure.symbolicLink(label(name)) }
        guard kind(metadata) == S_IFREG || kind(metadata) == S_IFDIR else { throw ArchiveFailure.specialFile(label(name)) }
        guard metadata.st_mode & 0o444 != 0 else { throw ArchiveFailure.unreadable(label(name)) }
    }

    /// Directories are traversed through open descriptors; descendants are
    /// lstat/openat checked rather than following links during a recursive copy.
    private static func copyNode(fd: Int32, expected: stat, to destination: URL, name: String, depth: Int, operation: ArchiveOperation) throws {
        try operation.checkCancellation()
        guard depth < 256 else { throw ArchiveFailure.unreadable(label(name)) }
        var initial = stat()
        guard Darwin.fstat(fd, &initial) == 0 else { throw ArchiveFailure.unreadable(label(name)) }
        try validateKind(initial, name: name)
        guard sameSnapshot(expected, initial) else { throw ArchiveFailure.changed(label(name)) }

        if kind(initial) == S_IFDIR {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } catch { throw ArchiveFailure.cannotStage }
            let names = try childNames(fd: fd, name: name, operation: operation)
            for childName in names {
                try operation.checkCancellation()
                var childMetadata = stat()
                guard childName.withCString({ Darwin.fstatat(fd, $0, &childMetadata, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    throw ArchiveFailure.changed(label(childName))
                }
                try validateKind(childMetadata, name: childName)
                let childFD = childName.withCString { Darwin.openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
                guard childFD >= 0 else { throw openFailure(name: childName) }
                defer { Darwin.close(childFD) }
                try copyNode(fd: childFD, expected: childMetadata, to: destination.appendingPathComponent(childName), name: childName, depth: depth + 1, operation: operation)
            }
            let outputFD = destination.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC) }
            guard outputFD >= 0 else { throw ArchiveFailure.cannotStage }
            defer { Darwin.close(outputFD) }
            try preserveTimes(initial, fd: outputFD)
        } else {
            try copyFile(fd: fd, metadata: initial, to: destination, name: name, operation: operation)
        }
        var final = stat()
        guard Darwin.fstat(fd, &final) == 0, sameSnapshot(initial, final) else { throw ArchiveFailure.changed(label(name)) }
    }

    private static func copyFile(fd: Int32, metadata: stat, to destination: URL, name: String, operation: ArchiveOperation) throws {
        let outputFD = destination.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard outputFD >= 0 else { throw ArchiveFailure.cannotStage }
        defer { Darwin.close(outputFD) }
        let capacity = 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            try operation.checkCancellation()
            let count = Darwin.read(fd, buffer, capacity)
            if count < 0 {
                if errno == EINTR { continue }
                throw ArchiveFailure.unreadable(label(name))
            }
            if count == 0 { break }
            guard total <= metadata.st_size, Int64(count) <= metadata.st_size - total else { throw ArchiveFailure.changed(label(name)) }
            var written = 0
            while written < count {
                try operation.checkCancellation()
                let amount = Darwin.write(outputFD, buffer.advanced(by: written), count - written)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw ArchiveFailure.cannotStage }
                written += amount
            }
            total += Int64(count)
        }
        guard total == metadata.st_size else { throw ArchiveFailure.changed(label(name)) }
        // Keep copies private while preserving whether a selected file executes.
        guard Darwin.fchmod(outputFD, (metadata.st_mode & 0o111) | 0o600) == 0 else { throw ArchiveFailure.cannotStage }
        try preserveTimes(metadata, fd: outputFD)
    }

    private static func preserveTimes(_ metadata: stat, fd: Int32) throws {
        var times = [
            timeval(tv_sec: metadata.st_atimespec.tv_sec, tv_usec: Int32(metadata.st_atimespec.tv_nsec / 1_000)),
            timeval(tv_sec: metadata.st_mtimespec.tv_sec, tv_usec: Int32(metadata.st_mtimespec.tv_nsec / 1_000))
        ]
        guard times.withUnsafeMutableBufferPointer({ Darwin.futimes(fd, $0.baseAddress) }) == 0 else { throw ArchiveFailure.cannotStage }
    }

    private static func childNames(fd: Int32, name: String, operation: ArchiveOperation) throws -> [String] {
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0 else { throw ArchiveFailure.unreadable(label(name)) }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ArchiveFailure.unreadable(label(name))
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while true {
            try operation.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw ArchiveFailure.unreadable(label(name)) }
                break
            }
            let child: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let child else { throw ArchiveFailure.unreadable(label(name)) }
            if child != ".", child != ".." { names.append(child) }
        }
        return names.sorted()
    }

    private static func sameSnapshot(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode
            && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func uniqueName(_ name: String, isDirectory: Bool, reserved: inout Set<String>) -> String {
        let suffix = isDirectory ? "" : (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var index = 2
        while !reserved.insert(nameKey(candidate)).inserted {
            candidate = stem + " \(index)" + (suffix.isEmpty ? "" : "." + suffix)
            index += 1
        }
        return candidate
    }

    private static func nameKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func kind(_ metadata: stat) -> mode_t { metadata.st_mode & S_IFMT }

    private static func includes(parent: String, child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func openFailure(name: String) -> ArchiveFailure {
        errno == ELOOP ? .symbolicLink(label(name)) : .unreadable(label(name))
    }

    static func label(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(0x20)! : $0
        }).prefix(100))
    }
}
