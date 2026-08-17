import SwiftUI

// MARK: - AddEditProxySheet
//
// Manual proxy configuration UI. Validates every field before saving or
// testing — invalid configurations are never silently accepted.

public struct AddEditProxySheet: View {
    @ObservedObject public var viewModel: ProxyViewModel
    public let profile: ProxyProfile?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedType: ProxyType = .socks5
    @State private var host = ""
    @State private var port = ""
    @State private var authenticationEnabled = false
    @State private var username = ""
    @State private var password = ""
    @State private var fieldErrors: [String: String] = [:]

    @State private var isTesting = false
    @State private var testResultMessage: String?
    @State private var isTestResultPresented = false
    @State private var showClearConfirmation = false

    private let haptics = ServiceContainer.shared.hapticService

    public init(viewModel: ProxyViewModel, profile: ProxyProfile?) {
        self.viewModel = viewModel
        self.profile = profile
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Proxy Name", text: $name)
                        .textContentType(.nickname)
                        .accessibilityIdentifier("proxy.form.name")
                    if let error = fieldErrors["name"] {
                        fieldError(error)
                    }
                } header: {
                    Text("Name")
                }

                Section {
                    Picker("Type", selection: $selectedType) {
                        ForEach(ProxyType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("proxy.form.type")

                    TextField("Host / IP Address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.none)
                        .accessibilityIdentifier("proxy.form.host")
                    if let error = fieldErrors["host"] {
                        fieldError(error)
                    }

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("proxy.form.port")
                    if let error = fieldErrors["port"] {
                        fieldError(error)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("SOCKS5, SOCKS4, HTTP and HTTPS proxies are supported.")
                }

                Section {
                    if selectedType != .socks4 {
                        Toggle(isOn: $authenticationEnabled) {
                            Label("Authentication", systemImage: "lock.fill")
                        }
                        .tint(Color.accentColor)
                        .accessibilityIdentifier("proxy.form.authToggle")
                    } else {
                        Label("Authentication", systemImage: "lock.slash")
                            .foregroundStyle(.secondary)
                    }

                    if authenticationEnabled {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .accessibilityIdentifier("proxy.form.username")
                        if let error = fieldErrors["username"] {
                            fieldError(error)
                        }

                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("proxy.form.password")
                        if let error = fieldErrors["password"] {
                            fieldError(error)
                        }
                    }
                } header: {
                    Text("Credentials")
                } footer: {
                    if profile != nil {
                        Text("Leave the password field empty to keep the existing password.")
                    }
                }

                Section {
                    testConnectionButton
                    clearButton
                } header: {
                    Text("Actions")
                }
            }
            .navigationTitle(profile == nil ? "Add Proxy" : "Edit Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("proxy.form.save")
                }
            }
            .onAppear(perform: prefill)
            .interactiveDismissDisabled(isTesting)
            .scrollDismissesKeyboard(.interactively)
            .confirmationDialog(
                "Clear All Fields?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { clearFields() }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Test Result",
                isPresented: $isTestResultPresented,
                presenting: testResultMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - Sections

    private func fieldError(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("proxy.form.fieldError")
    }

    private var testConnectionButton: some View {
        Button {
            testConnection()
        } label: {
            HStack {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                }
                Text(isTesting ? "Testing..." : "Test Connection")
            }
        }
        .disabled(isTesting)
        .accessibilityIdentifier("proxy.form.test")
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            showClearConfirmation = true
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .disabled(isTesting)
        .accessibilityIdentifier("proxy.form.clear")
    }

    // MARK: - Actions

    private func prefill() {
        guard let profile = profile else { return }
        let configuration = profile.configuration
        name = configuration.name
        selectedType = configuration.type
        host = configuration.host
        port = "\(configuration.port)"
        authenticationEnabled = configuration.authenticationEnabled && configuration.type != .socks4
        username = configuration.username
        password = ""
    }

    private func clearFields() {
        name = ""
        selectedType = .socks5
        host = ""
        port = ""
        authenticationEnabled = false
        username = ""
        password = ""
        fieldErrors = [:]
        haptics.selectionChanged()
    }

    /// Validates fields; returns a configuration or nil (errors shown inline).
    private func validatedConfiguration() -> ProxyConfiguration? {
        var errors: [String: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            errors["name"] = "Name is required"
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if let hostIssue = ProxyConfigurationValidator.validateHost(trimmedHost) {
            errors["host"] = hostIssue
        }

        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        if trimmedPort.isEmpty {
            errors["port"] = "Port is required"
        } else if let portInt = Int(trimmedPort) {
            if let portIssue = ProxyConfigurationValidator.validatePort(portInt) {
                errors["port"] = portIssue
            }
        } else {
            errors["port"] = "Port must be a number"
        }

        // SOCKS4 has no challenge mechanism — credentials are meaningless.
        let effectiveAuth = authenticationEnabled && selectedType != .socks4
        // Editing a profile with a password already in the Keychain: an empty
        // password field means "keep the stored value", so it must not fail.
        let keepExistingPassword: Bool
        if let profile, password.isEmpty {
            keepExistingPassword = viewModel.service.password(forProfileID: profile.id) != nil
        } else {
            keepExistingPassword = false
        }
        if effectiveAuth {
            if username.trimmingCharacters(in: .whitespaces).isEmpty {
                errors["username"] = "Username is required"
            }
            if password.isEmpty && !keepExistingPassword {
                errors["password"] = "Password is required"
            }
        }

        fieldErrors = errors
        guard errors.isEmpty, let portInt = Int(trimmedPort) else { return nil }

        // An empty password while editing keeps the Keychain-stored value.
        let resolvedPassword: String?
        if password.isEmpty, let profile = profile, effectiveAuth {
            resolvedPassword = viewModel.service.password(forProfileID: profile.id)
        } else {
            resolvedPassword = password
        }

        return ProxyConfiguration(
            id: profile?.id ?? UUID(),
            name: trimmedName,
            type: selectedType,
            host: trimmedHost,
            port: portInt,
            authenticationEnabled: effectiveAuth,
            username: username.trimmingCharacters(in: .whitespaces),
            password: resolvedPassword
        )
    }

    private func save() {
        guard let configuration = validatedConfiguration() else {
            haptics.notificationOccurred(.error)
            return
        }
        if let profile = profile {
            viewModel.service.updateProfile(ProxyProfile(configuration: configuration))
        } else {
            viewModel.service.addProfile(configuration)
        }
        haptics.notificationOccurred(.success)
        dismiss()
    }

    private func testConnection() {
        guard let configuration = validatedConfiguration() else {
            haptics.notificationOccurred(.error)
            return
        }
        isTesting = true
        Task {
            do {
                let result = try await viewModel.service.test(configuration)
                isTesting = false
                if result.success, let latencyMs = result.latencyMs {
                    testResultMessage = "Connected \u{2022} \(latencyMs) ms"
                    haptics.notificationOccurred(.success)
                } else {
                    testResultMessage = result.failure?.userMessage ?? "Connection failed"
                    haptics.notificationOccurred(.error)
                }
                isTestResultPresented = true
            } catch {
                isTesting = false
                testResultMessage = "Connection failed"
                isTestResultPresented = true
            }
        }
    }
}
