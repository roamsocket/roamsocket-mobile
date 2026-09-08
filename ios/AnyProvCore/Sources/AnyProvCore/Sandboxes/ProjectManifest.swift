import Foundation

/// What build system / manifest lives at the root of a cloned project.
/// Drives the preset chips in the Sandboxes "Start a run" sheet — only
/// the presets that apply to the detected manifest are shown.
public enum ProjectManifest: String, Codable, Sendable, CaseIterable, Hashable {
    case nodePnpm
    case nodeNpm
    case nodeYarn
    case pythonPyproject
    case pythonRequirements
    case rust
    case go
    case maven
    case gradle
    case ruby
    case unknown

    /// Human-friendly label for the "Detected: …" pill.
    public var displayName: String {
        switch self {
        case .nodePnpm: return "Node.js (pnpm)"
        case .nodeNpm: return "Node.js (npm)"
        case .nodeYarn: return "Node.js (yarn)"
        case .pythonPyproject: return "Python (pyproject)"
        case .pythonRequirements: return "Python (requirements.txt)"
        case .rust: return "Rust (Cargo)"
        case .go: return "Go modules"
        case .maven: return "Maven"
        case .gradle: return "Gradle"
        case .ruby: return "Ruby (Bundler)"
        case .unknown: return "Unknown"
        }
    }

    /// What a "Test" preset should run. `nil` means the project type
    /// has no canonical test command and the user should type one.
    public var testCommand: String? {
        switch self {
        case .nodePnpm: return "pnpm test"
        case .nodeNpm: return "npm test -- --watch=false"
        case .nodeYarn: return "yarn test --non-interactive"
        case .pythonPyproject: return "pip install -e . >/dev/null 2>&1 && pytest -q"
        case .pythonRequirements: return "pip install -r requirements.txt >/dev/null 2>&1 && pytest -q"
        case .rust: return "cargo test --quiet"
        case .go: return "go test ./..."
        case .maven: return "mvn -B -q test"
        case .gradle: return "./gradlew test --console=plain"
        case .ruby: return "bundle install --quiet && bundle exec rspec"
        case .unknown: return nil
        }
    }

    /// What a "Build" preset should run. `nil` when the project has
    /// no separate build step (e.g. a pure test suite).
    public var buildCommand: String? {
        switch self {
        case .nodePnpm: return "pnpm build"
        case .nodeNpm: return "npm run build --silent"
        case .nodeYarn: return "yarn build"
        case .rust: return "cargo build --quiet"
        case .go: return "go build ./..."
        case .maven: return "mvn -B -q package -DskipTests"
        case .gradle: return "./gradlew assemble --console=plain"
        case .pythonPyproject, .pythonRequirements: return nil
        case .ruby: return "bundle install --quiet"
        case .unknown: return nil
        }
    }

    /// What an "Install deps" preset should run. Runs before the
    /// user-facing step in the pipeline.
    public var installCommand: String? {
        switch self {
        case .nodePnpm: return "pnpm install --frozen-lockfile"
        case .nodeNpm: return "npm ci || npm install"
        case .nodeYarn: return "yarn install --frozen-lockfile"
        case .pythonPyproject: return "pip install -e ."
        case .pythonRequirements: return "pip install -r requirements.txt"
        case .rust: return "cargo fetch"
        case .go: return "go mod download"
        case .maven: return "mvn -B -q dependency:resolve"
        case .gradle: return "./gradlew dependencies --console=plain"
        case .ruby: return "bundle install"
        case .unknown: return nil
        }
    }

    /// What a "Lint" preset should run. `nil` when the project has no
    /// conventional linter wired up.
    public var lintCommand: String? {
        switch self {
        case .nodePnpm: return "pnpm lint"
        case .nodeNpm: return "npm run lint --silent"
        case .nodeYarn: return "yarn lint"
        case .rust: return "cargo clippy --quiet"
        case .go: return "go vet ./..."
        case .pythonPyproject, .pythonRequirements: return "ruff check ."
        case .maven, .gradle, .ruby, .unknown: return nil
        }
    }

    /// The set of manifest files that signal this manifest. Mirrors
    /// `detectDefaultCommand` in `desktop-server/src/e2b/runner.ts`
    /// so the two stay in sync.
    public var manifestFiles: [String] {
        switch self {
        case .nodePnpm: return ["pnpm-lock.yaml"]
        case .nodeNpm: return ["package.json"]
        case .nodeYarn: return ["yarn.lock"]
        case .pythonPyproject: return ["pyproject.toml"]
        case .pythonRequirements: return ["requirements.txt"]
        case .rust: return ["Cargo.toml"]
        case .go: return ["go.mod"]
        case .maven: return ["pom.xml"]
        case .gradle: return ["build.gradle"]
        case .ruby: return ["Gemfile"]
        case .unknown: return []
        }
    }
}

/// Inspect a set of filenames (typically the root contents of a
/// freshly-cloned repo) and return the most specific manifest that
/// matches. Order of checks mirrors the desktop runner so a repo with
/// both `package.json` and `pnpm-lock.yaml` is classified as pnpm.
public enum ProjectManifestDetector {
    public static func detect(files: Set<String>) -> ProjectManifest {
        // Specific lockfiles first so we don't down-classify.
        if files.contains("pnpm-lock.yaml") { return .nodePnpm }
        if files.contains("yarn.lock") { return .nodeYarn }
        if files.contains("package.json") { return .nodeNpm }
        if files.contains("pyproject.toml") { return .pythonPyproject }
        if files.contains("requirements.txt") { return .pythonRequirements }
        if files.contains("Cargo.toml") { return .rust }
        if files.contains("go.mod") { return .go }
        if files.contains("pom.xml") { return .maven }
        if files.contains("build.gradle") { return .gradle }
        if files.contains("Gemfile") { return .ruby }
        return .unknown
    }

    /// Test-friendly entry: accepts an array of paths and returns the
    /// manifest after taking only the basename. Mirrors what a real
    /// `ls /code` would yield.
    public static func detect(paths: [String]) -> ProjectManifest {
        let basenames = Set(paths.map { ($0 as NSString).lastPathComponent })
        return detect(files: basenames)
    }
}
