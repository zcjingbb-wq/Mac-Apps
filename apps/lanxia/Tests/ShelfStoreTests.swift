import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

@main
struct ShelfStoreTests {
    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("StashCatShelfTests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let sources = base.appendingPathComponent("sources", isDirectory: true)
        let shelf = base.appendingPathComponent("shelf", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let original = sources.appendingPathComponent("笔记.txt")
        let originalData = Data("Hello, 暂存喵\n原件不能被修改。".utf8)
        try originalData.write(to: original)

        let store = ShelfStore(root: shelf)
        try require(store.items.isEmpty, "New shelf should be empty")
        await store.importURLs([original, original])
        try require(store.items.count == 2, "Duplicate names must create distinct copies")
        try require(Set(store.items.map(\.storedName)).count == 2, "Duplicate copies must have unique storage paths")
        try require(try Data(contentsOf: original) == originalData, "Import must preserve source bytes")
        for item in store.items {
            try require(try Data(contentsOf: store.url(for: item)) == originalData, "Stored bytes must match source")
        }
        try Data("原件后来被编辑".utf8).write(to: original)
        try require(try Data(contentsOf: store.url(for: store.items[0])) == originalData, "Copies must be independent of later source edits")

        let folder = sources.appendingPathComponent("资料夹", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: folder.appendingPathComponent("data.bin"))
        await store.importURLs([folder])
        try require(store.items.count == 3 && store.items[0].isDirectory, "Folders must be copied")
        try require(store.items[0].sizeBytes == 4, "Folder size should total regular files")
        try require(try Data(contentsOf: store.url(for: store.items[0]).appendingPathComponent("data.bin")) == Data([1, 2, 3, 4]), "Folder children must be copied")

        let reopened = ShelfStore(root: shelf)
        try require(reopened.items == store.items, "Relaunch must preserve ordering and metadata")
        let victim = reopened.items[1]
        let victimURL = reopened.url(for: victim)
        reopened.remove(victim)
        await waitUntilIdle(reopened)
        try require(reopened.items.count == 2, "Removal must update in-memory index")
        try require(!fm.fileExists(atPath: victimURL.path), "Removal must trash the stored copy")
        try require(fm.fileExists(atPath: original.path), "Removal must preserve original")
        let afterRemoval = ShelfStore(root: shelf)
        try require(afterRemoval.items.count == 2, "Removal must persist across relaunch")

        let beforeRecursive = afterRemoval.items
        await afterRemoval.importURLs([shelf, base, afterRemoval.url(for: afterRemoval.items[0])])
        try require(afterRemoval.items == beforeRecursive, "Self, descendants and ancestors must be rejected")
        try require(afterRemoval.errorMessage != nil, "Rejected recursive import must explain the failure")

        let badFolder = sources.appendingPathComponent("broken-folder", isDirectory: true)
        try fm.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: badFolder.appendingPathComponent("broken-link"), withDestinationURL: sources.appendingPathComponent("missing-target"))
        let foldersBeforeFailure = try fm.contentsOfDirectory(atPath: shelf.path).sorted()
        await afterRemoval.importURLs([badFolder])
        try require(afterRemoval.items == beforeRecursive, "Broken nested links must reject the import")
        try require(try fm.contentsOfDirectory(atPath: shelf.path).sorted() == foldersBeforeFailure, "Failed imports must not leave partial copies")

        let validLink = sources.appendingPathComponent("valid-link")
        try fm.createSymbolicLink(at: validLink, withDestinationURL: original)
        await afterRemoval.importURLs([validLink])
        try require(afterRemoval.items == beforeRecursive, "Valid symbolic links must be rejected rather than misrepresented as independent copies")
        try require(afterRemoval.errorMessage?.contains("符号链接") == true, "Symbolic-link rejection should give useful guidance")

        afterRemoval.clear()
        await waitUntilIdle(afterRemoval)
        try require(afterRemoval.items.isEmpty, "Clear must remove every stored copy")
        try require(ShelfStore(root: shelf).items.isEmpty, "Clear must persist across relaunch")
        try require(fm.fileExists(atPath: folder.path) && fm.fileExists(atPath: original.path), "Clear must preserve all original files and folders")

        let corruptRoot = base.appendingPathComponent("corrupt", isDirectory: true)
        try fm.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("index.json")
        let corruptData = Data("{truncated old index".utf8)
        try corruptData.write(to: corruptURL)
        let corrupt = ShelfStore(root: corruptRoot)
        try require(corrupt.errorMessage != nil, "Corrupt index must be visible")
        await corrupt.importURLs([original])
        corrupt.clear()
        try require(try Data(contentsOf: corruptURL) == corruptData, "Corrupt state must not be silently overwritten")
        try require(try fm.contentsOfDirectory(atPath: corruptRoot.path) == ["index.json"], "Locked corrupt shelf must not create new copies")

        print("PASS: file/folder copies, duplicate names, independent source bytes, relaunch, trash removal and clear, recursion rejection, symbolic-link rejection, broken-link cleanup, corrupt-index preservation")
    }

    @MainActor
    private static func waitUntilIdle(_ store: ShelfStore) async {
        while store.isImporting { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure.failed(message) }
    }
}
