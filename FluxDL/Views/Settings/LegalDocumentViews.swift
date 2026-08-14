import SwiftUI

// MARK: - Shared Renderer

/// Native renderer used by all legal pages. Content comes from the
/// centralized `LegalDocuments` source and is fully offline.
public struct LegalDocumentView: View {
    let document: LegalDocument

    public init(document: LegalDocument) {
        self.document = document
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Effective \(document.effectiveDate)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading)
                            .font(.headline)
                        Text(section.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy Policy

public struct PrivacyPolicyView: View {
    public init() {}

    public var body: some View {
        LegalDocumentView(document: LegalDocuments.privacyPolicy)
    }
}

// MARK: - Terms of Service

public struct TermsOfServiceView: View {
    public init() {}

    public var body: some View {
        LegalDocumentView(document: LegalDocuments.termsOfService)
    }
}

// MARK: - Licenses

public struct LicensesView: View {
    public init() {}

    public var body: some View {
        List(LegalDocuments.licenseEntries) { entry in
            NavigationLink {
                LicenseDetailView(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseDetailView: View {
    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.title3.bold())
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(entry.licenseText)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}