import XCTest
@testable import AnyProvCore

final class ProjectManifestTests: XCTestCase {
    // MARK: - Detection

    func testDetectsPnpmOverPlainPackageJson() {
        // pnpm-lock.yaml should win over package.json — mirrors
        // the order in `detectDefaultCommand` on the desktop runner.
        XCTAssertEqual(
            ProjectManifestDetector.detect(files: ["package.json", "pnpm-lock.yaml", "README.md"]),
            .nodePnpm
        )
    }

    func testDetectsYarn() {
        XCTAssertEqual(
            ProjectManifestDetector.detect(files: ["package.json", "yarn.lock"]),
            .nodeYarn
        )
    }

    func testFallsBackToNpm() {
        XCTAssertEqual(
            ProjectManifestDetector.detect(files: ["package.json", "README.md"]),
            .nodeNpm
        )
    }

    func testDetectsPyprojectOverRequirements() {
        XCTAssertEqual(
            ProjectManifestDetector.detect(files: ["pyproject.toml", "requirements.txt"]),
            .pythonPyproject
        )
    }

    func testDetectsPythonRequirementsOnly() {
        XCTAssertEqual(
            ProjectManifestDetector.detect(files: ["requirements.txt", "README.md"]),
            .pythonRequirements
        )
    }

    func testDetectsRust() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["Cargo.toml"]), .rust)
    }

    func testDetectsGo() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["go.mod", "main.go"]), .go)
    }

    func testDetectsMaven() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["pom.xml"]), .maven)
    }

    func testDetectsGradle() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["build.gradle"]), .gradle)
    }

    func testDetectsRuby() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["Gemfile", "app.rb"]), .ruby)
    }

    func testReturnsUnknownForUnrecognizedRepo() {
        XCTAssertEqual(ProjectManifestDetector.detect(files: ["README.md", "Makefile"]), .unknown)
    }

    func testDetectorAcceptsPathsAndStripsDirectories() {
        XCTAssertEqual(
            ProjectManifestDetector.detect(paths: ["some/repo/Cargo.toml", "some/repo/src/main.rs"]),
            .rust
        )
    }

    // MARK: - Preset commands

    func testEveryManifestHasEitherTestOrInstallCommand() {
        // Sanity: every recognized manifest should at least be runnable
        // somehow. `unknown` is the exception — the user types a command.
        for manifest in ProjectManifest.allCases where manifest != .unknown {
            XCTAssertNotNil(manifest.testCommand, "missing test command for \(manifest)")
        }
    }

    func testInstallCommandSensibleForNodeManifests() {
        XCTAssertEqual(ProjectManifest.nodeNpm.installCommand, "npm ci || npm install")
        XCTAssertEqual(ProjectManifest.nodePnpm.installCommand, "pnpm install --frozen-lockfile")
        XCTAssertEqual(ProjectManifest.nodeYarn.installCommand, "yarn install --frozen-lockfile")
    }

    func testPythonHasNoBuildCommand() {
        // No canonical "build" step for a Python package.
        XCTAssertNil(ProjectManifest.pythonPyproject.buildCommand)
        XCTAssertNil(ProjectManifest.pythonRequirements.buildCommand)
    }

    func testUnknownManifestHasNoPresets() {
        XCTAssertNil(ProjectManifest.unknown.testCommand)
        XCTAssertNil(ProjectManifest.unknown.buildCommand)
        XCTAssertNil(ProjectManifest.unknown.installCommand)
        XCTAssertNil(ProjectManifest.unknown.lintCommand)
    }

    func testManifestFilesRoundTripWithDetector() {
        for manifest in ProjectManifest.allCases where manifest != .unknown {
            let files = Set(manifest.manifestFiles)
            XCTAssertFalse(files.isEmpty, "\(manifest) has no manifest files")
            XCTAssertEqual(ProjectManifestDetector.detect(files: files), manifest)
        }
    }
}
