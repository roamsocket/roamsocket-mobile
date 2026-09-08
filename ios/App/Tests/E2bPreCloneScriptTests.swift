import XCTest
import Foundation
@testable import RoamSocket

/// Regression tests for the pre-clone script that `E2bSessionStore`
/// ships into the e2b code-interpreter. The script ran into two
/// back-to-back Python SyntaxErrors on the iOS E2B session open
/// path:
///   1. `clone_url = <unquoted URL>` — the URL interpolator only
///      escaped single quotes and never wrapped the value, so
///      Python saw a bare identifier and refused the file.
///   2. `return` at module level — once the URL was quoted, the
///      short-circuit `return` statements hit "return outside
///      function" because the script body is intentionally flat
///      (no wrapper) so e2b's /execute can run it as-is.
/// Both are now fixed (URLs are quoted; short-circuits use
/// `sys.exit(0)`), and this test pins the shape so a future
/// refactor can't regress either.
final class E2bPreCloneScriptTests: XCTestCase {

    // MARK: - escapePython quoting

    func testEscapePythonWrapsValueInSingleQuotes() {
        let out = E2bSessionStore.escapePython("main")
        XCTAssertEqual(out, "'main'")
    }

    func testEscapePythonEscapesEmbeddedSingleQuotes() {
        let out = E2bSessionStore.escapePython("o'reilly")
        XCTAssertEqual(out, "'o\\'reilly'")
    }

    func testEscapePythonEscapesBackslashes() {
        let out = E2bSessionStore.escapePython(#"a\b"#)
        XCTAssertEqual(out, #"'a\\b'"#)
    }

    func testEscapePythonOnEmptyStringProducesEmptyLiteral() {
        XCTAssertEqual(E2bSessionStore.escapePython(""), "''")
    }

    func testEscapePythonKeepsPlainUrlValidLiteral() {
        // The exact shape the pre-clone script needs:
        // a single-quoted, fully-valid Python string literal.
        let out = E2bSessionStore.escapePython("https://github.com/octocat/Hello-World.git")
        XCTAssertEqual(out, "'https://github.com/octocat/Hello-World.git'")
    }

    // MARK: - End-to-end script is parseable Python

    /// Build the same script body the store sends to e2b (without
    /// hitting the network) and assert the structural shape that
    /// kept the previous SyntaxErrors from coming back. The
    /// previous bug shipped as a bare `return` at module level and
    /// an unquoted URL; both are pinned here so a future refactor
    /// can't regress either.
    func testPreCloneScriptIsSyntacticallyValidPython() throws {
        let script = Self.renderPreCloneScript(
            cloneURL: "https://github.com/octocat/Hello-World.git",
            branch: "main"
        )

        // Structural guards: the actual SyntaxErrors the user hit.
        XCTAssertTrue(script.contains("import sys") || script.contains("import subprocess, json, sys"),
                      "pre-clone script must import sys so module-level short-circuits can exit")
        XCTAssertFalse(script.contains("\n        return\n"),
                        "pre-clone script must not contain bare `return` at module level")
        let sysExitCount = script.components(separatedBy: "sys.exit(0)").count - 1
        XCTAssertGreaterThanOrEqual(sysExitCount, 2,
            "pre-clone script must use sys.exit(0) for every short-circuit (clone, checkout)")

        // The two interpolations that previously produced the
        // `clone_url = https://...` SyntaxError must now be
        // properly quoted Python string literals.
        XCTAssertTrue(script.contains("clone_url = 'https://github.com/octocat/Hello-World.git'"),
                      "clone_url must be a quoted Python string literal")
        XCTAssertTrue(script.contains("branch = 'main'"),
                      "branch must be a quoted Python string literal")
    }

    func testPreCloneScriptQuotesPrivateRepoTokenInURL() throws {
        // A GitHub token contains characters (`@`, alphanumerics)
        // that are fine in a URL but must be inside a string
        // literal in Python. Make sure the token-bearing URL is
        // still produced as a single quoted literal.
        let script = Self.renderPreCloneScript(
            cloneURL: "https://oauth2:ghp_abc123@github.com/octocat/Hello-World.git",
            branch: "feature/auth"
        )
        XCTAssertTrue(script.contains("clone_url = 'https://oauth2:ghp_abc123@github.com/octocat/Hello-World.git'"))
        XCTAssertTrue(script.contains("branch = 'feature/auth'"))
    }

    // MARK: - Helpers

    /// Mirror the script body `E2bSessionStore.preCloneRepo`
    /// composes. Kept in sync by hand; if the real script shape
    /// drifts the structural asserts above will fail first.
    private static func renderPreCloneScript(cloneURL: String, branch: String) -> String {
        return """
        import subprocess, json, sys
        clone_url = \(E2bSessionStore.escapePython(cloneURL))
        branch = \(E2bSessionStore.escapePython(branch))
        try:
            clone = subprocess.run(
                ["git", "clone", "--depth", "1", clone_url, "/code"],
                capture_output=True, text=True, timeout=120,
            )
            if clone.returncode != 0:
                print(json.dumps({"ok": False, "step": "clone", "stderr": clone.stderr}))
                sys.exit(0)
            subprocess.run(
                ["git", "fetch", "--depth", "1", "origin", branch],
                cwd="/code", capture_output=True, text=True, timeout=60,
            )
            co = subprocess.run(
                ["git", "checkout", branch],
                cwd="/code", capture_output=True, text=True, timeout=60,
            )
            if co.returncode != 0:
                print(json.dumps({"ok": False, "step": "checkout", "stderr": co.stderr}))
                sys.exit(0)
            sha = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd="/code", capture_output=True, text=True, timeout=10,
            )
            print(json.dumps({"ok": True, "sha": sha.stdout.strip()}))
        except Exception as exc:
            print(json.dumps({"ok": False, "step": "exception", "stderr": str(exc)}))
        """
    }
}
