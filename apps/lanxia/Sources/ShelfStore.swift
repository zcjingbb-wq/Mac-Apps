import AppKit
import Combine
import Foundation

struct ShelfItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let storedName: String
    let addedAt: Date
    let sizeBytes: Int64
    let isDirectory: Bool
}

private struct ShelfIndex: Codable {
    let version: Int
    let items: [ShelfItem]
}

private struct ShelfImportResult: Sendable {
    var items: [ShelfItem] = []
    var failures: [String] = []
}

private enum ShelfError: LocalizedError {
    case invalidIndex
    case recursiveImport
    case missingSource
    case brokenLink(String)
    case symbolicLink(String)

    var errorDescription: String? {
        switch self {
        case .invalidIndex: return "暂存清单格式不正确。原清单已保留，请先在访达中备份并检查 index.json，再重新启动应用。"
        case .recursiveImport: return "不能暂存暂存区自身、暂存区里的文件，或包含暂存区的上级文件夹。"
        case .missingSource: return "文件已不存在，或当前没有读取权限。"
        case .brokenLink(let name): return "发现失效的符号链接：\(name)"
        case .symbolicLink(let name): return "暂不支持符号链接「\(name)」，请添加它指向的实际文件，以保留独立副本。"
        }
    }
}

/// Owns independent local copies. Source files are never moved or removed.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var isImporting = false
    @Published var message: String?
    @Published var errorMessage: String?

    let storageURL: URL
    private let indexURL: URL
    private var canMutate = true

    init(root: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageURL = (root ?? appSupport.appendingPathComponent("StashCat/Shelf", isDirectory: true)).standardizedFileURL
        indexURL = storageURL.appendingPathComponent("index.json")
        do {
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index = try JSONDecoder().decode(ShelfIndex.self, from: Data(contentsOf: indexURL))
                guard index.version == 1,
                      Set(index.items.map(\.id)).count == index.items.count,
                      index.items.allSatisfy(Self.isValid) else { throw ShelfError.invalidIndex }
                items = index.items
            }
        } catch {
            canMutate = false
            errorMessage = "未能读取暂存区，已暂停修改以保护现有文件。\n\(error.localizedDescription)\n位置：\(storageURL.path)"
        }
    }

    func url(for item: ShelfItem) -> URL {
        guard Self.isValid(item) else { return storageURL.appendingPathComponent("invalid-item") }
        return storageURL.appendingPathComponent(item.storedName)
    }

    func importWithPanel() {
        guard !isImporting, canMutate else { return }
        let panel = NSOpenPanel()
        panel.title = "添加到蓝匣"
        panel.prompt = "暂存副本"
        panel.message = "文件和文件夹会复制到本机暂存区，原文件会保留。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginInLanxia { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await self.importURLs(urls) }
        }
    }

    func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting, canMutate else { return }
        isImporting = true
        message = nil
        errorMessage = nil
        defer { isImporting = false }
        let root = storageURL
        let result = await Task.detached(priority: .userInitiated) {
            Self.copySources(urls, to: root)
        }.value
        if !result.items.isEmpty {
            let next = result.items + items
            do {
                try save(next)
                items = next
                message = "已暂存 \(result.items.count) 项 · 原文件已保留"
            } catch {
                // Only these newly-created copies are cleaned up; the old index is untouched.
                let folders = result.items.map { root.appendingPathComponent($0.id.uuidString, isDirectory: true) }
                await Task.detached {
                    for folder in folders { try? FileManager.default.removeItem(at: folder) }
                }.value
                errorMessage = "清单保存失败，本次添加已撤回：\(error.localizedDescription)"
            }
        }
        if !result.failures.isEmpty {
            let failures = result.failures.prefix(4).joined(separator: "\n")
            let remaining = result.failures.count > 4 ? "\n以及另外 \(result.failures.count - 4) 项。" : ""
            errorMessage = (errorMessage.map { $0 + "\n" } ?? "") + failures + remaining
        }
    }

    func remove(_ item: ShelfItem) {
        guard !isImporting, canMutate,
              let actual = items.first(where: { $0.id == item.id && $0.storedName == item.storedName }) else { return }
        trash([actual])
    }

    func clear() {
        guard !items.isEmpty, !isImporting, canMutate else { return }
        trash(items)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: item)])
    }

    func copy(_ item: ShelfItem) {
        let fileURL = url(for: item)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = "暂存副本已不存在，请移除这条记录后重新添加。"
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([fileURL as NSURL]) {
            message = "已复制「\(item.name)」，可以粘贴到访达或其他应用"
        } else {
            errorMessage = "无法写入剪贴板，请尝试把文件直接拖出。"
        }
    }

    private func trash(_ selected: [ShelfItem]) {
        isImporting = true
        errorMessage = nil
        message = nil
        let old = items
        let ids = Set(selected.map(\.id))
        let next = old.filter { !ids.contains($0.id) }
        do {
            // Commit the index before touching copies. A write failure leaves every file in place.
            try save(next)
        } catch {
            isImporting = false
            errorMessage = "无法保存清单，文件尚未移除：\(error.localizedDescription)"
            return
        }
        items = next
        let root = storageURL
        Task {
            let failed: [UUID] = await Task.detached(priority: .userInitiated) {
                var failures: [UUID] = []
                for item in selected {
                    let folder = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                    do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
                    catch { failures.append(item.id) }
                }
                return failures
            }.value
            if !failed.isEmpty {
                let failedIDs = Set(failed)
                let restored = old.filter { failedIDs.contains($0.id) } + next
                do {
                    try save(restored)
                    items = restored
                    errorMessage = "有 \(failed.count) 项无法放入废纸篓，已保留在暂存区。"
                } catch {
                    // Preserve their files even if the index cannot be repaired.
                    items = restored
                    canMutate = false
                    errorMessage = "部分副本仍在暂存文件夹中，但清单恢复失败。请先备份暂存区，再重新启动应用。\n\(error.localizedDescription)"
                }
            } else {
                message = "已移除 \(selected.count) 项暂存副本 · 原文件已保留"
            }
            isImporting = false
        }
    }

    private func save(_ value: [ShelfItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ShelfIndex(version: 1, items: value))
        try data.write(to: indexURL, options: .atomic)
    }

    nonisolated private static func isValid(_ item: ShelfItem) -> Bool {
        let components = item.storedName.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2 && components[0] == Substring(item.id.uuidString)
            && !components[1].isEmpty && components[1] != "." && components[1] != ".."
            && !item.name.isEmpty && item.sizeBytes >= 0
    }

    nonisolated private static func includes(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.path
        let b = child.standardizedFileURL.path
        return a == b || b.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    nonisolated private static func validate(_ source: URL, root: URL) throws -> (Bool, Int64) {
        let manager = FileManager.default
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard !includes(canonicalRoot, canonical), !includes(canonical, canonicalRoot) else { throw ShelfError.recursiveImport }
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &directory) else { throw ShelfError.missingSource }
        var size: Int64 = 0
        func inspect(_ candidate: URL) throws {
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                let destination = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard manager.fileExists(atPath: destination.path) else { throw ShelfError.brokenLink(candidate.lastPathComponent) }
                guard !includes(canonicalRoot, destination), !includes(destination, canonicalRoot) else { throw ShelfError.recursiveImport }
                throw ShelfError.symbolicLink(candidate.lastPathComponent)
            }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        try inspect(source)
        if directory.boolValue {
            var enumerationError: Error?
            guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey], options: [], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw ShelfError.missingSource }
            for case let child as URL in enumerator { try inspect(child) }
            if let enumerationError { throw enumerationError }
        }
        return (directory.boolValue, size)
    }

    nonisolated private static func copySources(_ sources: [URL], to root: URL) -> ShelfImportResult {
        var result = ShelfImportResult()
        let manager = FileManager.default
        for source in sources {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                guard source.isFileURL else { throw ShelfError.missingSource }
                let (isDirectory, size) = try validate(source, root: root)
                let name = source.lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { throw ShelfError.missingSource }
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                let destination = folder.appendingPathComponent(name, isDirectory: isDirectory)
                try manager.copyItem(at: source, to: destination)
                result.items.append(ShelfItem(id: id, name: name, storedName: id.uuidString + "/" + name, addedAt: Date(), sizeBytes: size, isDirectory: isDirectory))
            } catch {
                try? manager.removeItem(at: folder)
                result.failures.append("「\(source.lastPathComponent)」：\(error.localizedDescription)")
            }
        }
        return result
    }
}

extension NSUserInterfaceItemIdentifier {
    static let lanxiaPanel = Self("LanxiaMainPanel")
}

extension NSSavePanel {
    @MainActor func beginInLanxia(completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let owner = NSApp.windows.first(where: { $0.identifier == .lanxiaPanel && $0.isVisible }) else {
            begin(completionHandler: completion)
            return
        }
        guard owner.attachedSheet == nil else { completion(.cancel); return }
        owner.makeKey()
        beginSheetModal(for: owner) { response in
            self.orderOut(nil)
            DispatchQueue.main.async { completion(response) }
        }
    }
}
