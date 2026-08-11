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

    // MARK: - Install mapping

    func testSkillContentUsesInstructionsWhenPresent() {
        let s = MarketplaceSkillListing(
            id: "x", name: "x", description: "d",
            instructions: "# Real\nBody"
        )
        XCTAssertEqual(s.skillContent, "# Real\nBody")
    }

    func testSkillContentSynthesisesWhenMissing() {
        let s = MarketplaceSkillListing(id: "my", name: "my", description: "Does things")
        XCTAssertEqual(s.skillContent, "# my\n\nDoes things\n")
    }

    func testToSkillMapsAllFields() {
        let s = MarketplaceSkillListing(
            id: "mcp-builder",
            name: "mcp-builder",
            description: "Guide for creating high-quality MCP servers",
            category: "devops",
            source: "official",
            featured: true,
            instructions: "# MCP Builder\nBody"
        )
        let skill = s.toSkill()
        XCTAssertEqual(skill.id, "mcp-builder")
        XCTAssertEqual(skill.name, "mcp-builder")
        XCTAssertEqual(skill.description, "Guide for creating high-quality MCP servers")
        XCTAssertEqual(skill.content, "# MCP Builder\nBody")
        XCTAssertEqual(skill.category, .devops)
        XCTAssertEqual(skill.source, .official)
        XCTAssertEqual(skill.frontmatter["name"], "mcp-builder")
        XCTAssertEqual(skill.frontmatter["description"], "Guide for creating high-quality MCP servers")
    }

    func testToSkillCategoryFallback() {
        let s = MarketplaceSkillListing(id: "x", name: "x", description: "d", category: "unknown-cat")
        XCTAssertEqual(s.toSkill().category, .other)
    }

    func testToSkillCategoryNilDefaultsOther() {
        let s = MarketplaceSkillListing(id: "x", name: "x", description: "d")
        XCTAssertEqual(s.toSkill().category, .other)
    }

    func testToSkillSourceFallback() {
        let s = MarketplaceSkillListing(id: "x", name: "x", description: "d", source: "unknown")
        XCTAssertEqual(s.toSkill().source, .community)
    }

    func testBundledSkillsHaveInstructions() {
        for s in MarketplaceStore.bundledCatalog.skills {
            XCTAssertNotNil(s.instructions, "skill \(s.id) should have instructions for install")
            XCTAssertFalse(s.instructions!.isEmpty, "skill \(s.id) instructions should not be empty")
        }
    }

    func testSkillCategoryFromMapping() {
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: "devops"), .devops)
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: "frontend"), .frontend)
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: "documentation"), .documentation)
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: "design"), .design)
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: nil), .other)
        XCTAssertEqual(SkillCategory.from(marketplaceCategory: "bogus"), .other)
    }

    func testSkillSourceFromMapping() {
        XCTAssertEqual(SkillSource.from(marketplaceSource: "official"), .official)
        XCTAssertEqual(SkillSource.from(marketplaceSource: "community"), .community)
        XCTAssertEqual(SkillSource.from(marketplaceSource: "custom"), .custom)
        XCTAssertEqual(SkillSource.from(marketplaceSource: nil), .community)
        XCTAssertEqual(SkillSource.from(marketplaceSource: "bogus"), .community)
    }
}
