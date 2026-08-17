import XCTest
@testable import FluxDL

// MARK: - Legal documents (data source integrity)

final class SettingsAboutTests: XCTestCase {

    // MARK: Privacy Policy

    func testPrivacyPolicyMetadata() {
        let doc = LegalDocuments.privacyPolicy
        XCTAssertEqual(doc.title, "Privacy Policy")
        XCTAssertEqual(doc.effectiveDate, LegalDocuments.effectiveDate)
        XCTAssertEqual(doc.effectiveDate, "August 14, 2026")
    }

    func testPrivacyPolicyHasAllSections() {
        let doc = LegalDocuments.privacyPolicy
        XCTAssertEqual(doc.sections.count, 14)
        XCTAssertEqual(doc.sections.first?.heading, "1. Overview")
        XCTAssertEqual(doc.sections.last?.heading, "14. Contact")
        for section in doc.sections {
            XCTAssertFalse(section.heading.isEmpty, "Section heading must not be empty")
            XCTAssertFalse(section.body.isEmpty, "Section body must not be empty")
        }
    }

    func testPrivacyPolicyDescribesRealBehavior() {
        let body = LegalDocuments.privacyPolicy.sections.map(\.body).joined(separator: "\n")
        XCTAssertTrue(body.contains("Keychain"), "Policy must mention Keychain key storage")
        XCTAssertTrue(body.contains("libtorrent"), "Policy must mention the torrent engine")
        XCTAssertTrue(body.contains("Gemini"), "Policy must mention the optional Gemini service")
        XCTAssertTrue(body.contains("rakibshorkar2/FluxDL"), "Policy must link the real repository")
    }

    // MARK: Terms of Service

    func testTermsMetadata() {
        let doc = LegalDocuments.termsOfService
        XCTAssertEqual(doc.title, "Terms of Service")
        XCTAssertEqual(doc.effectiveDate, LegalDocuments.effectiveDate)
    }

    func testTermsHasAllSections() {
        let doc = LegalDocuments.termsOfService
        XCTAssertEqual(doc.sections.count, 14)
        XCTAssertEqual(doc.sections.first?.heading, "1. Acceptance of These Terms")
        XCTAssertEqual(doc.sections.last?.heading, "14. Contact")
        for section in doc.sections {
            XCTAssertFalse(section.heading.isEmpty, "Section heading must not be empty")
            XCTAssertFalse(section.body.isEmpty, "Section body must not be empty")
        }
    }

    func testTermsDoNotEndorseUnlawfulDownloads() {
        let body = LegalDocuments.termsOfService.sections.map(\.body).joined(separator: "\n")
        XCTAssertTrue(body.contains("authorized"), "Terms must require authorization for downloads")
        XCTAssertFalse(body.lowercased().contains("you may download anything"), "Terms must not waive responsibility")
    }

    // MARK: Licenses

    func testLicensesListCoversAllBundledDependencies() {
        let names = LegalDocuments.licenseEntries.map(\.name)
        XCTAssertEqual(names, ["libtorrent", "LibTorrent-Swift", "Yams", "Boost", "OpenSSL"])
    }

    func testEveryLicenseHasSummaryAndFullText() {
        for entry in LegalDocuments.licenseEntries {
            XCTAssertFalse(entry.summary.isEmpty, "\(entry.name) must have a summary")
            XCTAssertFalse(entry.licenseText.isEmpty, "\(entry.name) must have license text")
            XCTAssertGreaterThan(entry.licenseText.count, 200, "\(entry.name) license text must be the full text")
        }
    }

    func testLicenseTextsContainExpectedLicenseMarkers() {
        let entries = Dictionary(uniqueKeysWithValues: LegalDocuments.licenseEntries.map { ($0.id, $0.licenseText) })
        XCTAssertTrue(entries["libtorrent"]!.contains("Arvid Norberg"))
        XCTAssertTrue(entries["libtorrent"]!.contains("Redistribution and use in source and binary forms"))
        XCTAssertTrue(entries["LibTorrent-Swift"]!.contains("Norio Nomura"))
        XCTAssertTrue(entries["Yams"]!.contains("JP Simard"))
        XCTAssertTrue(entries["Boost"]!.contains("Boost Software License - Version 1.0"))
        XCTAssertTrue(entries["OpenSSL"]!.contains("Apache License"))
    }

    func testLicenseTextsAreSelectableAndReadable() {
        // Guard against accidental empty/whitespace-only lines corrupting
        // the rendered footnotes.
        for entry in LegalDocuments.licenseEntries {
            for line in entry.licenseText.split(separator: "\n") {
                XCTAssertTrue(line.count <= 200, "\(entry.name) has an over-long line: \(line.prefix(60))…")
            }
        }
    }
}