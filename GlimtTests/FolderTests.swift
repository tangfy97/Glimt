import XCTest
@testable import Glimt

final class FolderTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let folder = try Fixtures.temporaryFolder()
        try Fixtures.image(at: folder.appendingPathComponent("b.jpg"), width: 200, height: 100)
        try Fixtures.image(at: folder.appendingPathComponent("a.png"), width: 50, height: 50, type: .png)
        try Fixtures.image(at: folder.appendingPathComponent("IMG_10.jpg"))
        try Fixtures.image(at: folder.appendingPathComponent("IMG_9.jpg"))
        try Fixtures.image(at: folder.appendingPathComponent(".hidden.jpg"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub/Deeper"), withIntermediateDirectories: true)
        try Fixtures.image(at: folder.appendingPathComponent("Sub/Deeper/c.jpg"))
        return folder
    }

    func testScanFindsImagesAndFoldersButNotHiddenOrOtherFiles() async throws {
        let items = await FolderScanner.items(in: try makeFolder(), recursive: false)
        XCTAssertEqual(Set(items.map(\.name)), ["b.jpg", "a.png", "IMG_10.jpg", "IMG_9.jpg", "Sub"])
        XCTAssertEqual(items.first { $0.name == "Sub" }?.kind, .folder)
        XCTAssertEqual(items.first { $0.name == "a.png" }?.kind, .image)
    }

    func testRecursiveScanListsNestedImagesWithoutFolders() async throws {
        let items = await FolderScanner.items(in: try makeFolder(), recursive: true)
        XCTAssertTrue(items.contains { $0.name == "c.jpg" })
        XCTAssertFalse(items.contains { $0.kind == .folder })
    }

    @MainActor
    func testModelSortsLikeFinderAndFilters() async throws {
        let model = FolderModel()
        model.sortKey = .name
        model.ascending = true
        await model.load(try makeFolder())
        XCTAssertEqual(model.media.map(\.name), ["a.png", "b.jpg", "IMG_9.jpg", "IMG_10.jpg"], "numbers sort naturally")
        XCTAssertEqual(model.folders.map(\.name), ["Sub"])

        model.searchText = "img"
        XCTAssertEqual(model.media.map(\.name), ["IMG_9.jpg", "IMG_10.jpg"])
        model.searchText = ""

        model.sortKey = .kind
        XCTAssertEqual(model.media.first?.name, "b.jpg", "public.jpeg sorts before public.png")
        model.sortKey = .name
    }

    @MainActor
    func testSiblingsFindRAWPartnersByBaseName() async throws {
        let folder = try Fixtures.temporaryFolder()
        try Fixtures.image(at: folder.appendingPathComponent("DSC_1.jpg"))
        try Fixtures.image(at: folder.appendingPathComponent("DSC_1.png"), type: .png)
        try Fixtures.image(at: folder.appendingPathComponent("DSC_2.jpg"))
        let model = FolderModel()
        await model.load(folder)
        let siblings = model.siblings(of: folder.appendingPathComponent("DSC_1.jpg")).map(\.lastPathComponent)
        XCTAssertEqual(siblings, ["DSC_1.png"])
    }
}
