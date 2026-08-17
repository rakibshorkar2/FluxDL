import XCTest
@testable import FluxDL

final class SemanticVersionTests: XCTestCase {
    func testParsesPlainVersion() {
        XCTAssertEqual(SemanticVersion(rawValue: "2.0.1"), SemanticVersion(major: 2, minor: 0, patch: 1))
    }

    func testParsesVariantTagPrefixes() {
        for tag in ["v2.0.1", "V2.0.1", "FluxDL-v2.0.1", "fluxdl-2.0.1"] {
            XCTAssertEqual(
                SemanticVersion(rawValue: tag),
                SemanticVersion(major: 2, minor: 0, patch: 1),
                "Failed to parse tag \(tag)"
            )
        }
    }

    func testParsesShortForms() {
        XCTAssertEqual(SemanticVersion(rawValue: "2"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion(rawValue: "2.1"), SemanticVersion(major: 2, minor: 1, patch: 0))
    }

    func testCIBuildTagBuildMetadataIgnored() {
        let tag = SemanticVersion(rawValue: "v2.0.1.456")
        XCTAssertEqual(tag, SemanticVersion(major: 2, minor: 0, patch: 1))
        XCTAssertEqual(tag?.display, "2.0.1")
    }

    func testRejectsInvalidVersions() {
        XCTAssertNil(SemanticVersion(rawValue: ""))
        XCTAssertNil(SemanticVersion(rawValue: "abc"))
        XCTAssertNil(SemanticVersion(rawValue: "v"))
        XCTAssertNil(SemanticVersion(rawValue: "FluxDL-"))
        XCTAssertNil(SemanticVersion(rawValue: ".."))
    }

    // MARK: - Comparison (requirement scenarios A–E)

    func testScenarioA_equalVersionsAreNotNewer() {
        let installed = SemanticVersion(rawValue: "2.0.1")!
        let latest = SemanticVersion(rawValue: "v2.0.1")!
        XCTAssertFalse(latest > installed)
        XCTAssertEqual(latest, installed)
    }

    func testScenarioB_patchUpdateIsNewer() {
        XCTAssertTrue(SemanticVersion(rawValue: "2.0.2")! > SemanticVersion(rawValue: "2.0.1")!)
    }

    func testScenarioC_minorUpdateIsNewer() {
        XCTAssertTrue(SemanticVersion(rawValue: "2.1.0")! > SemanticVersion(rawValue: "2.0.1")!)
    }

    func testScenarioD_majorUpdateIsNewer() {
        XCTAssertTrue(SemanticVersion(rawValue: "3.0.0")! > SemanticVersion(rawValue: "2.0.1")!)
    }

    func testScenarioE_higherPatchWinsOverOlder() {
        XCTAssertTrue(SemanticVersion(rawValue: "2.0.10")! > SemanticVersion(rawValue: "2.0.9")!)
    }

    func testSemanticOrderingAcrossMinor() {
        XCTAssertTrue(SemanticVersion(rawValue: "2.0.1")! > SemanticVersion(rawValue: "1.9.9")!)
        XCTAssertTrue(SemanticVersion(rawValue: "2.10.0")! > SemanticVersion(rawValue: "2.9.99")!)
    }

    func testPrereleaseSortsBeforeRelease() {
        XCTAssertLessThan(SemanticVersion(rawValue: "2.0.2-beta.1")!, SemanticVersion(rawValue: "2.0.2")!)
        XCTAssertGreaterThan(SemanticVersion(rawValue: "2.0.2-beta.1")!, SemanticVersion(rawValue: "2.0.1")!)
    }

    func testCIBuildTagWithManyComponents() {
        let oldBuild = SemanticVersion(rawValue: "v1.0.0.123")!
        let newVersion = SemanticVersion(rawValue: "v2.0.1.456")!
        XCTAssertLessThan(oldBuild, newVersion)
        XCTAssertEqual(oldBuild.display, "1.0.0")
        XCTAssertEqual(newVersion.display, "2.0.1")
    }

    func testDisplayIgnoresBuildMetadata() {
        XCTAssertEqual(SemanticVersion(rawValue: "v2.0.1.99")?.display, "2.0.1")
    }
}
