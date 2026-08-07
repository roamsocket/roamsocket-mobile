import XCTest
@testable import AnyProvCore

final class MarketplaceTests: XCTestCase {
    func testURLNormalizeOwnerRepo() {
        let u = MarketplaceURLNormalizer.normalize("kind365/my-mp")
        XCTAssertEqual(
            u,
            "https://raw.githubusercontent.com/kind365/my-mp/main/catalog.json"
        )
    }

    func testURLNormalizeBlob() {
        let u = MarketplaceURLNormalizer.normalize(
            "https://github.com/o/r/blob/main/marketplace/catalog.json"
        )
        XCTAssertEqual(
            u,
            "https://raw.githubusercontent.com/o/r/main/marketplace/catalog.json"
        )
    }

    func testMergeLaterOverrides() {
        let a = MarketplaceCatalog(
            connectors: [.init(id: "gmail", name: "Gmail Old")],
            metalModels: [
                .init(hubID: "org/a-MLX-4bit", displayName: "A", platforms: ["ios"]),
            ]
        )
        let b = MarketplaceCatalog(
            connectors: [.init(id: "gmail", name: "Gmail New"), .init(id: "notion", name: "Notion")],
            metalModels: [
                .init(hubID: "org/a-MLX-4bit", displayName: "A2", platforms: ["ios", "desktop"]),
            ]
        )
        let m = MarketplaceMerge.merge([a, b])
        XCTAssertEqual(m.connectors.first(where: { $0.id == "gmail" })?.name, "Gmail New")
        XCTAssertNotNil(m.connectors.first(where: { $0.id == "notion" }))
        XCTAssertEqual(m.metalModels.first(where: { $0.hubID == "org/a-MLX-4bit" })?.displayName, "A2")
    }

    func testMetalPlatformFilter() {
        let cat = MarketplaceCatalog(
            metalModels: [
                .init(hubID: "org/phone-MLX-4bit", displayName: "P", platforms: ["ios"]),
                .init(hubID: "org/desk-MLX-4bit", displayName: "D", platforms: ["desktop"]),
                .init(hubID: "org/both-MLX-4bit", displayName: "B"),
            ]
        )
        XCTAssertEqual(cat.metalModels(for: "ios").map(\.hubID).sorted(), [
            "org/both-MLX-4bit",
            "org/phone-MLX-4bit",
        ])
        XCTAssertEqual(cat.metalModels(for: "desktop").map(\.hubID).sorted(), [
            "org/both-MLX-4bit",
            "org/desk-MLX-4bit",
        ])
    }

    func testBundledCatalogNonEmpty() {
        let b = MarketplaceStore.bundledCatalog
        XCTAssertFalse(b.connectors.isEmpty)
        XCTAssertFalse(b.metalModels.isEmpty)
    }
}
