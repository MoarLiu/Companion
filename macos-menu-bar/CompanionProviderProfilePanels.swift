import AppKit
import Foundation
import SwiftUI

enum CompanionProviderProfilePanels {
    struct AssetUploadS3Input {
        var name: String
        var endpoint: String
        var region: String
        var bucket: String
        var pathPrefix: String
        var publicBaseURL: String
        var usePathStyle: Bool
        var accessKeyID: String
        var secretAccessKey: String
        var maxSizeMB: Int
        var defaultOutputFormat: CompanionAssetUploadOutputFormat
    }

    struct AssetUploadCustomHTTPInput {
        var name: String
        var uploadURL: String
        var method: CompanionAssetUploadProfile.CustomHTTPConfig.Method
        var bodyMode: CompanionAssetUploadProfile.CustomHTTPConfig.BodyMode
        var fileFieldName: String
        var additionalHeaders: [String: String]
        var responseURLJSONPath: String
        var publicBaseURL: String
        var maxSizeMB: Int
        var defaultOutputFormat: CompanionAssetUploadOutputFormat
    }

    static func showAssetUploadS3Profile(
        initialProfile: CompanionAssetUploadProfile?,
        initialCredentials: CompanionAssetUploadS3Credentials?
    ) -> AssetUploadS3Input? {
        let initial = AssetUploadS3FormView.Initial(profile: initialProfile, credentials: initialCredentials)
        return AssetUploadS3ProfilePanelController(initial: initial).runModal()
    }

    static func showAssetUploadCustomHTTPProfile(
        initialProfile: CompanionAssetUploadProfile?
    ) -> AssetUploadCustomHTTPInput? {
        var result: AssetUploadCustomHTTPInput?
        let initial = AssetUploadCustomHTTPFormView.Initial(profile: initialProfile)
        CompanionGlassModalHost.runModal(width: 600, fallbackHeight: 820, title: CompanionL10n.text("Asset Upload")) {
            AssetUploadCustomHTTPFormView(
                initial: initial,
                onSave: { input in
                    result = input
                    NSApp.stopModal(withCode: .OK)
                },
                onCancel: {
                    NSApp.stopModal(withCode: .cancel)
                }
            )
        }
        return result
    }
}

private final class AssetUploadS3ProfilePanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let initialAccessKeyID: String
    private let hasStoredCredentials: Bool
    private var result: CompanionProviderProfilePanels.AssetUploadS3Input?

    private let nameField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "Blog Assets")
    private let endpointField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "https://s3.amazonaws.com")
    private let regionField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "us-east-1")
    private let bucketField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "my-bucket")
    private let pathPrefixField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "companion")
    private let publicBaseURLField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "https://cdn.example.com/my-bucket")
    private let maxSizeField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "25")
    private let accessKeyField = AssetUploadS3ProfilePanelController.makeTextField(placeholder: "AKIA...")
    private let secretKeyField = AssetUploadS3ProfilePanelController.makeSecureField(placeholder: "")
    private let outputFormatControl = NSSegmentedControl(labels: ["URL", "Markdown", "HTML"], trackingMode: .selectOne, target: nil, action: nil)
    private let pathStyleCheckbox = NSButton(checkboxWithTitle: CompanionL10n.text("Use path-style S3 URLs"), target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: " ")

    init(initial: AssetUploadS3FormView.Initial) {
        self.initialAccessKeyID = initial.accessKeyID
        self.hasStoredCredentials = initial.hasStoredCredentials
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        nameField.stringValue = initial.name
        endpointField.stringValue = initial.endpoint
        regionField.stringValue = initial.region
        bucketField.stringValue = initial.bucket
        pathPrefixField.stringValue = initial.pathPrefix
        publicBaseURLField.stringValue = initial.publicBaseURL
        maxSizeField.stringValue = initial.maxSizeMB
        accessKeyField.stringValue = initial.accessKeyID
        secretKeyField.placeholderString = initial.hasStoredCredentials
            ? CompanionL10n.text("Leave blank to keep stored secret")
            : CompanionL10n.text("Paste secret access key")
        pathStyleCheckbox.state = initial.usePathStyle ? .on : .off
        outputFormatControl.selectedSegment = Self.segmentIndex(for: initial.defaultOutputFormat)

        configurePanel()
    }

    func runModal() -> CompanionProviderProfilePanels.AssetUploadS3Input? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nameField)
        let response = NSApp.runModal(for: panel)
        panel.close()
        return response == .OK ? result : nil
    }

    private func configurePanel() {
        panel.title = CompanionL10n.text("Asset Upload")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 14
        form.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 18, right: 24)
        form.translatesAutoresizingMaskIntoConstraints = false

        form.addArrangedSubview(makeHeader())
        form.addArrangedSubview(makeFieldGroup(label: CompanionL10n.text("Profile Name"), field: nameField))
        form.addArrangedSubview(makeFieldGroup(label: CompanionL10n.text("Endpoint"), field: endpointField))
        form.addArrangedSubview(makeTwoColumnRow(
            makeFieldGroup(label: CompanionL10n.text("Region"), field: regionField, width: 274),
            makeFieldGroup(label: CompanionL10n.text("Bucket"), field: bucketField, width: 274)
        ))
        form.addArrangedSubview(makeTwoColumnRow(
            makeFieldGroup(label: CompanionL10n.text("Path Prefix"), field: pathPrefixField, width: 274),
            makeFieldGroup(label: CompanionL10n.text("Max Size (MB)"), field: maxSizeField, width: 274)
        ))
        form.addArrangedSubview(makeFieldGroup(label: CompanionL10n.text("Public Base URL"), field: publicBaseURLField))
        form.addArrangedSubview(makeOutputFormatGroup())
        form.addArrangedSubview(makeFieldGroup(label: CompanionL10n.text("Access Key ID"), field: accessKeyField))
        form.addArrangedSubview(makeFieldGroup(label: CompanionL10n.text("Secret Access Key"), field: secretKeyField))
        pathStyleCheckbox.font = .systemFont(ofSize: 13)
        form.addArrangedSubview(pathStyleCheckbox)

        scrollView.documentView = form
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(makeFooter())

        panel.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            form.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 520)
        ])
    }

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: CompanionL10n.text("Asset Upload"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor

        let message = NSTextField(wrappingLabelWithString: CompanionL10n.text("Configure the default S3-compatible target used by Finder right-click upload and companion.asset.upload."))
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return stack
    }

    private func makeOutputFormatGroup() -> NSView {
        outputFormatControl.translatesAutoresizingMaskIntoConstraints = false
        outputFormatControl.heightAnchor.constraint(equalToConstant: 28).isActive = true
        outputFormatControl.widthAnchor.constraint(equalToConstant: 250).isActive = true
        return makeFieldGroup(label: CompanionL10n.text("Default Output Format"), field: outputFormatControl)
    }

    private func makeFooter() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .systemRed
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: CompanionL10n.text("Cancel"), target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true

        let save = NSButton(title: CompanionL10n.text("Save"), target: self, action: #selector(saveAction))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.translatesAutoresizingMaskIntoConstraints = false
        save.widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [statusLabel, spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 16, right: 24)

        let footer = NSStackView(views: [separator, buttons])
        footer.orientation = .vertical
        footer.spacing = 0
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return footer
    }

    private func makeFieldGroup(label: String, field: NSView, width: CGFloat = 560) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .semibold)
        labelView.textColor = .secondaryLabelColor

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true

        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeTwoColumnRow(_ left: NSView, _ right: NSView) -> NSView {
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        left.widthAnchor.constraint(equalToConstant: 274).isActive = true
        right.widthAnchor.constraint(equalToConstant: 274).isActive = true

        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func cancelAction() {
        result = nil
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func saveAction() {
        let input = CompanionProviderProfilePanels.AssetUploadS3Input(
            name: trimmed(nameField),
            endpoint: trimmed(endpointField),
            region: trimmed(regionField),
            bucket: trimmed(bucketField),
            pathPrefix: trimmed(pathPrefixField),
            publicBaseURL: trimmed(publicBaseURLField),
            usePathStyle: pathStyleCheckbox.state == .on,
            accessKeyID: trimmed(accessKeyField),
            secretAccessKey: trimmed(secretKeyField),
            maxSizeMB: Int(trimmed(maxSizeField)) ?? 0,
            defaultOutputFormat: Self.outputFormat(for: outputFormatControl.selectedSegment)
        )

        let canReuseStoredSecret = hasStoredCredentials
            && input.secretAccessKey.isEmpty
            && input.accessKeyID == initialAccessKeyID
        guard !input.name.isEmpty,
              !input.endpoint.isEmpty,
              !input.region.isEmpty,
              !input.bucket.isEmpty,
              !input.pathPrefix.isEmpty,
              !input.accessKeyID.isEmpty,
              (!input.secretAccessKey.isEmpty || canReuseStoredSecret)
        else {
            setStatus(CompanionL10n.text("Name, endpoint, region, bucket, prefix, and S3 keys are required."))
            return
        }
        guard input.maxSizeMB > 0 && input.maxSizeMB <= CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes else {
            setStatus(CompanionL10n.format("Max size must be between 1 and %d MB.", CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes))
            return
        }
        let normalizedEndpoint = input.endpoint.contains("://") ? input.endpoint : "https://\(input.endpoint)"
        guard let url = URL(string: normalizedEndpoint), url.host != nil else {
            setStatus(CompanionL10n.text("Endpoint must be a valid URL or host."))
            return
        }

        result = input
        NSApp.stopModal(withCode: .OK)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        result = nil
        NSApp.stopModal(withCode: .cancel)
        return true
    }

    private func setStatus(_ value: String) {
        statusLabel.stringValue = value
    }

    private func trimmed(_ field: NSTextField) -> String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeTextField(placeholder: String) -> NSTextField {
        let field = FormTextField(placeholder: placeholder)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return field
    }

    private static func makeSecureField(placeholder: String) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 40).isActive = true
        field.menu = CompanionFormEditMenu.make()
        return field
    }

    private static func segmentIndex(for format: CompanionAssetUploadOutputFormat) -> Int {
        switch format {
        case .url: return 0
        case .markdown: return 1
        case .html: return 2
        }
    }

    private static func outputFormat(for selectedSegment: Int) -> CompanionAssetUploadOutputFormat {
        switch selectedSegment {
        case 1: return .markdown
        case 2: return .html
        default: return .url
        }
    }
}

// MARK: - Asset upload S3 form

private struct AssetUploadS3FormView: View {
    struct Initial {
        let name: String
        let endpoint: String
        let region: String
        let bucket: String
        let pathPrefix: String
        let publicBaseURL: String
        let usePathStyle: Bool
        let accessKeyID: String
        let secretAccessKey: String
        let maxSizeMB: String
        let defaultOutputFormat: CompanionAssetUploadOutputFormat
        let hasStoredCredentials: Bool

        init(profile: CompanionAssetUploadProfile?, credentials: CompanionAssetUploadS3Credentials?) {
            name = profile?.name ?? "S3 Assets"
            endpoint = profile?.s3?.endpoint ?? ""
            region = profile?.s3?.region ?? "us-east-1"
            bucket = profile?.s3?.bucket ?? ""
            pathPrefix = profile?.s3?.pathPrefix ?? "companion"
            publicBaseURL = profile?.s3?.publicBaseURL ?? ""
            usePathStyle = profile?.s3?.usePathStyle ?? false
            accessKeyID = credentials?.accessKeyID ?? profile?.s3?.accessKeyID ?? ""
            secretAccessKey = ""
            maxSizeMB = String(max(1, (profile?.limits.maxSizeBytes ?? CompanionAssetUploadProfile.Limits.defaultMaxSizeBytes) / (1024 * 1024)))
            defaultOutputFormat = profile?.resolvedDefaultOutputFormat ?? .url
            hasStoredCredentials = credentials != nil
        }
    }

    let onSave: (CompanionProviderProfilePanels.AssetUploadS3Input) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var endpoint: String
    @State private var region: String
    @State private var bucket: String
    @State private var pathPrefix: String
    @State private var publicBaseURL: String
    @State private var usePathStyle: Bool
    @State private var accessKeyID: String
    @State private var secretAccessKey: String
    @State private var maxSizeMB: String
    @State private var defaultOutputFormat: CompanionAssetUploadOutputFormat
    @State private var statusText: String = ""
    @State private var statusTone: CompanionFormStatusTone = .neutral
    @FocusState private var nameFocused: Bool
    private let initialAccessKeyID: String
    private let hasStoredCredentials: Bool

    init(
        initial: Initial,
        onSave: @escaping (CompanionProviderProfilePanels.AssetUploadS3Input) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial.name)
        _endpoint = State(initialValue: initial.endpoint)
        _region = State(initialValue: initial.region)
        _bucket = State(initialValue: initial.bucket)
        _pathPrefix = State(initialValue: initial.pathPrefix)
        _publicBaseURL = State(initialValue: initial.publicBaseURL)
        _usePathStyle = State(initialValue: initial.usePathStyle)
        _accessKeyID = State(initialValue: initial.accessKeyID)
        _secretAccessKey = State(initialValue: initial.secretAccessKey)
        _maxSizeMB = State(initialValue: initial.maxSizeMB)
        _defaultOutputFormat = State(initialValue: initial.defaultOutputFormat)
        initialAccessKeyID = initial.accessKeyID
        hasStoredCredentials = initial.hasStoredCredentials
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompanionModalHeader(
                icon: "arrow.up.doc.fill",
                title: CompanionL10n.text("Asset Upload"),
                message: CompanionL10n.text("Configure the default S3-compatible target used by Finder right-click upload and companion.asset.upload.")
            )

            field(label: CompanionL10n.text("Profile Name"), placeholder: "Blog Assets", text: $name)
            field(label: CompanionL10n.text("Endpoint"), placeholder: "https://s3.amazonaws.com", text: $endpoint)

            HStack(spacing: 12) {
                field(label: CompanionL10n.text("Region"), placeholder: "us-east-1", text: $region)
                field(label: CompanionL10n.text("Bucket"), placeholder: "my-bucket", text: $bucket)
            }

            HStack(spacing: 12) {
                field(label: CompanionL10n.text("Path Prefix"), placeholder: "companion", text: $pathPrefix)
                field(label: CompanionL10n.text("Max Size (MB)"), placeholder: "25", text: $maxSizeMB)
            }

            field(label: CompanionL10n.text("Public Base URL"), placeholder: "https://cdn.example.com/my-bucket", text: $publicBaseURL)
            VStack(alignment: .leading, spacing: 7) {
                CompanionModalFieldLabel(text: CompanionL10n.text("Default Output Format"))
                Picker("", selection: $defaultOutputFormat) {
                    Text("URL").tag(CompanionAssetUploadOutputFormat.url)
                    Text("Markdown").tag(CompanionAssetUploadOutputFormat.markdown)
                    Text("HTML").tag(CompanionAssetUploadOutputFormat.html)
                }
                .pickerStyle(.segmented)
            }
            field(label: CompanionL10n.text("Access Key ID"), placeholder: "AKIA...", text: $accessKeyID)
            secureField(
                label: CompanionL10n.text("Secret Access Key"),
                placeholder: hasStoredCredentials ? CompanionL10n.text("Leave blank to keep stored secret") : CompanionL10n.text("Paste secret access key"),
                text: $secretAccessKey
            )

            Toggle(CompanionL10n.text("Use path-style S3 URLs"), isOn: $usePathStyle)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))

            Text(statusText.isEmpty ? " " : statusText)
                .font(.system(size: 12))
                .foregroundStyle(statusTone.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 16, alignment: .leading)

            HStack(spacing: 10) {
                Spacer()
                Button(CompanionL10n.text("Cancel"), action: onCancel)
                    .frame(minWidth: 78)
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(CompanionL10n.text("Save"), action: save)
                    .frame(minWidth: 88)
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .tint(XiaoHuaErTheme.tint)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .companionModalFormBody()
        .onAppear { nameFocused = true }
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompanionModalFieldLabel(text: label)
            TextField(placeholder, text: text)
                .companionModalFieldChrome()
        }
    }

    private func secureField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompanionModalFieldLabel(text: label)
            SecureField(placeholder, text: text)
                .companionModalFieldChrome()
        }
    }

    private func save() {
        let input = CompanionProviderProfilePanels.AssetUploadS3Input(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            pathPrefix: pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            publicBaseURL: publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            usePathStyle: usePathStyle,
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            maxSizeMB: Int(maxSizeMB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            defaultOutputFormat: defaultOutputFormat
        )

        let canReuseStoredSecret = hasStoredCredentials
            && input.secretAccessKey.isEmpty
            && input.accessKeyID == initialAccessKeyID
        guard !input.name.isEmpty,
              !input.endpoint.isEmpty,
              !input.region.isEmpty,
              !input.bucket.isEmpty,
              !input.pathPrefix.isEmpty,
              !input.accessKeyID.isEmpty,
              (!input.secretAccessKey.isEmpty || canReuseStoredSecret)
        else {
            setStatus(CompanionL10n.text("Name, endpoint, region, bucket, prefix, and S3 keys are required."), .error)
            return
        }
        guard input.maxSizeMB > 0 && input.maxSizeMB <= CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes else {
            setStatus(
                CompanionL10n.format("Max size must be between 1 and %d MB.", CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes),
                .error
            )
            return
        }
        let normalizedEndpoint = input.endpoint.contains("://") ? input.endpoint : "https://\(input.endpoint)"
        guard let url = URL(string: normalizedEndpoint), url.host != nil else {
            setStatus(CompanionL10n.text("Endpoint must be a valid URL or host."), .error)
            return
        }
        onSave(input)
    }

    private func setStatus(_ text: String, _ tone: CompanionFormStatusTone) {
        statusText = text
        statusTone = tone
    }
}

// MARK: - Asset upload Custom HTTP form

private struct AssetUploadCustomHTTPFormView: View {
    struct Initial {
        let name: String
        let uploadURL: String
        let method: CompanionAssetUploadProfile.CustomHTTPConfig.Method
        let bodyMode: CompanionAssetUploadProfile.CustomHTTPConfig.BodyMode
        let fileFieldName: String
        let headersText: String
        let storedSensitiveHeaderNames: Set<String>
        let responseURLJSONPath: String
        let publicBaseURL: String
        let maxSizeMB: String
        let defaultOutputFormat: CompanionAssetUploadOutputFormat

        init(profile: CompanionAssetUploadProfile?) {
            let config = profile?.customHTTP
            name = profile?.name ?? "HTTP Assets"
            uploadURL = config?.uploadURL ?? ""
            method = config?.method ?? .post
            bodyMode = config?.bodyMode ?? .multipart
            fileFieldName = config?.fileFieldName ?? "file"
            responseURLJSONPath = config?.responseURLJSONPath ?? "url"
            publicBaseURL = config?.publicBaseURL ?? ""
            maxSizeMB = String(max(1, (profile?.limits.maxSizeBytes ?? CompanionAssetUploadProfile.Limits.defaultMaxSizeBytes) / (1024 * 1024)))
            defaultOutputFormat = profile?.resolvedDefaultOutputFormat ?? .url
            let storedSensitive = config?.sensitiveHeaderReferences ?? [:]
            storedSensitiveHeaderNames = Set(storedSensitive.keys)
            var headerLines = (config?.additionalHeaders ?? [:])
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key): \($0.value)" }
            for key in storedSensitive.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if config?.additionalHeaders[key] == nil {
                    headerLines.append("\(key):")
                }
            }
            headersText = headerLines.joined(separator: "\n")
        }
    }

    let onSave: (CompanionProviderProfilePanels.AssetUploadCustomHTTPInput) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var uploadURL: String
    @State private var method: CompanionAssetUploadProfile.CustomHTTPConfig.Method
    @State private var bodyMode: CompanionAssetUploadProfile.CustomHTTPConfig.BodyMode
    @State private var fileFieldName: String
    @State private var headersText: String
    @State private var responseURLJSONPath: String
    @State private var publicBaseURL: String
    @State private var maxSizeMB: String
    @State private var defaultOutputFormat: CompanionAssetUploadOutputFormat
    @State private var statusText: String = ""
    @State private var statusTone: CompanionFormStatusTone = .neutral
    @FocusState private var nameFocused: Bool
    private let storedSensitiveHeaderNames: Set<String>

    init(
        initial: Initial,
        onSave: @escaping (CompanionProviderProfilePanels.AssetUploadCustomHTTPInput) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial.name)
        _uploadURL = State(initialValue: initial.uploadURL)
        _method = State(initialValue: initial.method)
        _bodyMode = State(initialValue: initial.bodyMode)
        _fileFieldName = State(initialValue: initial.fileFieldName)
        _headersText = State(initialValue: initial.headersText)
        _responseURLJSONPath = State(initialValue: initial.responseURLJSONPath)
        _publicBaseURL = State(initialValue: initial.publicBaseURL)
        _maxSizeMB = State(initialValue: initial.maxSizeMB)
        _defaultOutputFormat = State(initialValue: initial.defaultOutputFormat)
        storedSensitiveHeaderNames = initial.storedSensitiveHeaderNames
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CompanionModalHeader(
                icon: "arrow.up.doc.fill",
                title: CompanionL10n.text("Asset Upload"),
                message: CompanionL10n.text("Configure the default Custom HTTP upload target used by companion.asset.upload.")
            )

            field(label: CompanionL10n.text("Profile Name"), placeholder: "HTTP Assets", text: $name)
            field(label: CompanionL10n.text("Upload URL"), placeholder: "https://api.example.com/upload", text: $uploadURL)

            HStack(spacing: 12) {
                picker(label: CompanionL10n.text("Method"), selection: $method) {
                    Text("POST").tag(CompanionAssetUploadProfile.CustomHTTPConfig.Method.post)
                    Text("PUT").tag(CompanionAssetUploadProfile.CustomHTTPConfig.Method.put)
                }
                picker(label: CompanionL10n.text("Body"), selection: $bodyMode) {
                    Text("Multipart").tag(CompanionAssetUploadProfile.CustomHTTPConfig.BodyMode.multipart)
                    Text("Raw File").tag(CompanionAssetUploadProfile.CustomHTTPConfig.BodyMode.rawFile)
                }
            }

            HStack(spacing: 12) {
                field(label: CompanionL10n.text("File Field"), placeholder: "file", text: $fileFieldName)
                field(label: CompanionL10n.text("Max Size (MB)"), placeholder: "25", text: $maxSizeMB)
            }

            field(label: CompanionL10n.text("Response URL Path"), placeholder: "data.url", text: $responseURLJSONPath)
            field(label: CompanionL10n.text("Public Base URL"), placeholder: "https://cdn.example.com", text: $publicBaseURL)

            VStack(alignment: .leading, spacing: 7) {
                CompanionModalFieldLabel(text: CompanionL10n.text("Headers"))
                TextEditor(text: $headersText)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .frame(minHeight: 78, maxHeight: 110)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 7) {
                CompanionModalFieldLabel(text: CompanionL10n.text("Default Output Format"))
                Picker("", selection: $defaultOutputFormat) {
                    Text("URL").tag(CompanionAssetUploadOutputFormat.url)
                    Text("Markdown").tag(CompanionAssetUploadOutputFormat.markdown)
                    Text("HTML").tag(CompanionAssetUploadOutputFormat.html)
                }
                .pickerStyle(.segmented)
            }

            Text(statusText.isEmpty ? " " : statusText)
                .font(.system(size: 12))
                .foregroundStyle(statusTone.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 16, alignment: .leading)

            HStack(spacing: 10) {
                Spacer()
                Button(CompanionL10n.text("Cancel"), action: onCancel)
                    .frame(minWidth: 78)
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button(CompanionL10n.text("Save"), action: save)
                    .frame(minWidth: 88)
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .tint(XiaoHuaErTheme.tint)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .companionModalFormBody()
        .onAppear { nameFocused = true }
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompanionModalFieldLabel(text: label)
            TextField(placeholder, text: text)
                .companionModalFieldChrome()
        }
    }

    private func picker<Selection: Hashable, Content: View>(
        label: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompanionModalFieldLabel(text: label)
            Picker("", selection: selection, content: content)
                .pickerStyle(.segmented)
        }
    }

    private func save() {
        let parsedHeaders: [String: String]
        do {
            parsedHeaders = try parseHeaders()
        } catch {
            setStatus(error.localizedDescription, .error)
            return
        }

        let input = CompanionProviderProfilePanels.AssetUploadCustomHTTPInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            uploadURL: uploadURL.trimmingCharacters(in: .whitespacesAndNewlines),
            method: method,
            bodyMode: bodyMode,
            fileFieldName: fileFieldName.trimmingCharacters(in: .whitespacesAndNewlines),
            additionalHeaders: parsedHeaders,
            responseURLJSONPath: responseURLJSONPath.trimmingCharacters(in: .whitespacesAndNewlines),
            publicBaseURL: publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            maxSizeMB: Int(maxSizeMB.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            defaultOutputFormat: defaultOutputFormat
        )

        guard !input.name.isEmpty,
              !input.uploadURL.isEmpty,
              !input.responseURLJSONPath.isEmpty,
              !input.fileFieldName.isEmpty
        else {
            setStatus(CompanionL10n.text("Name, upload URL, response path, and file field are required."), .error)
            return
        }
        guard input.maxSizeMB > 0 && input.maxSizeMB <= CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes else {
            setStatus(
                CompanionL10n.format("Max size must be between 1 and %d MB.", CompanionAssetUploadProfile.Limits.maximumSynchronousUploadMegabytes),
                .error
            )
            return
        }
        guard let url = URL(string: input.uploadURL), url.host != nil else {
            setStatus(CompanionL10n.text("Upload URL must be a valid URL."), .error)
            return
        }
        onSave(input)
    }

    private func parseHeaders() throws -> [String: String] {
        var headers: [String: String] = [:]
        var normalizedNames = Set<String>()
        for rawLine in headersText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let separatorIndex = line.firstIndex(of: ":") ?? line.firstIndex(of: "=")
            guard let separatorIndex else {
                throw HeaderParseError(message: CompanionL10n.text("Headers must use Name: Value or Name=Value lines."))
            }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let valueStart = line.index(after: separatorIndex)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw HeaderParseError(message: CompanionL10n.text("Header names cannot be empty."))
            }
            let normalized = name.lowercased()
            guard !normalizedNames.contains(normalized) else {
                throw HeaderParseError(message: CompanionL10n.format("Duplicate header: %@", name))
            }
            normalizedNames.insert(normalized)

            if value.isEmpty {
                if CompanionAssetUploadProfileStore.isSensitiveHeaderName(name),
                   storedSensitiveHeaderNames.contains(name) {
                    headers[name] = ""
                }
                continue
            }
            headers[name] = String(value)
        }
        guard headers.count <= 10 else {
            throw HeaderParseError(message: CompanionL10n.text("Custom HTTP headers are limited to 10."))
        }
        return headers
    }

    private func setStatus(_ text: String, _ tone: CompanionFormStatusTone) {
        statusText = text
        statusTone = tone
    }

    private struct HeaderParseError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
