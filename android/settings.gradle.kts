pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

// Allow Gradle to auto-provision JDK 17 from foojay when the local
// toolchain resolver can't find one. This is the fallback for
// machines that don't have a system JDK 17 installed (CI, fresh dev
// boxes). Hosts with a system JDK 17 are unaffected — the explicit
// `org.gradle.java.installations.paths` in `gradle.properties` still
// wins.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "RoamSocket"

include(":app")
include(":RoamSocketCore")
