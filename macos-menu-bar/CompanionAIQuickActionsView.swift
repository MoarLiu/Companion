import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIQuickActionBar: View {
    let actions: [CompanionAIQuickAction]
    let selectedAction: CompanionAIQuickAction
    let isLoading: Bool
    let selectAction: (CompanionAIQuickAction) -> Void
    let addAction: (String, String) -> Void
    let updateAction: (CompanionAIQuickAction, String, String) -> Void
    let deleteAction: (CompanionAIQuickAction) -> Void
    let moveAction: (CompanionAIQuickAction, Int) -> Void
    let togglePinAction: (CompanionAIQuickAction) -> Void
    let exportTemplates: () throws -> Data
    let importTemplates: (Data) throws -> Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(actions) { quickAction in
                    Button {
                        selectAction(quickAction)
                    } label: {
                        Text(quickAction.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(selectedAction == quickAction ? XiaoHuaErTheme.tint : Color.primary)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(selectedAction == quickAction ? XiaoHuaErTheme.tint.opacity(0.18) : XiaoHuaErTheme.glassWhitewash))
                            .overlay(
                                Capsule()
                                    .stroke(selectedAction == quickAction ? XiaoHuaErTheme.tint.opacity(0.4) : XiaoHuaErTheme.subtleBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading && selectedAction == quickAction)
                    .contextMenu {
                        if quickAction.isCustom {
                            Button(CompanionL10n.text("Edit Action")) {
                                openEditor(for: quickAction)
                            }
                            Button(quickAction.isPinned ? CompanionL10n.text("Unpin Action") : CompanionL10n.text("Pin Action")) {
                                togglePinAction(quickAction)
                            }
                            Button(CompanionL10n.text("Move Left")) {
                                moveAction(quickAction, -1)
                            }
                            Button(CompanionL10n.text("Move Right")) {
                                moveAction(quickAction, 1)
                            }
                            Divider()
                            Button(CompanionL10n.text("Delete Action")) {
                                deleteAction(quickAction)
                            }
                        }
                    }
                }

                Button {
                    openEditor(for: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(XiaoHuaErTheme.tint)
                        .background(XiaoHuaErTheme.actionFill(XiaoHuaErTheme.tint), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help(CompanionL10n.text("Add Custom Action"))

                Menu {
                    Button(CompanionL10n.text("Import Templates")) {
                        importTemplateFile()
                    }
                    Button(CompanionL10n.text("Export Templates")) {
                        exportTemplateFile()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.secondary)
                        .background(XiaoHuaErTheme.glassWhitewash, in: Circle())
                        .overlay(Circle().stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .disabled(isLoading)
                .help(CompanionL10n.text("Custom Action Templates"))
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
        .background(TranslationStyle.sectionBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(XiaoHuaErTheme.glassHairline, lineWidth: 1)
        )
    }

    private func openEditor(for action: CompanionAIQuickAction?) {
        let initialTitle = action?.title ?? ""
        let initialPrompt = action?.systemPrompt ?? CompanionL10n.text("Please complete the task based on the content below:\n\n{{text}}")
        guard let result = AIQuickActionEditorPanel.run(
            isEditing: action != nil,
            initialTitle: initialTitle,
            initialPrompt: initialPrompt
        ) else {
            return
        }

        if let action {
            updateAction(action, result.title, result.prompt)
        } else {
            addAction(result.title, result.prompt)
        }
    }

    private func importTemplateFile() {
        let panel = NSOpenPanel()
        panel.title = CompanionL10n.text("Import AI Action Templates")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let count = try importTemplates(Data(contentsOf: url))
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("AI Action Templates Imported"),
                informativeText: CompanionL10n.format("Imported %d templates.", count),
                tone: .success
            )
        } catch {
            NSSound.beep()
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Import Failed"),
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }

    private func exportTemplateFile() {
        let panel = NSSavePanel()
        panel.title = CompanionL10n.text("Export AI Action Templates")
        panel.nameFieldStringValue = "companion-ai-action-templates.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try exportTemplates()
            try data.write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
            CompanionNonBlockingAlert.present(
                messageText: CompanionL10n.text("Export Failed"),
                informativeText: error.localizedDescription,
                tone: .warning
            )
        }
    }
}

private enum AIQuickActionEditorPanel {
    static func run(
        isEditing: Bool,
        initialTitle: String,
        initialPrompt: String
    ) -> (title: String, prompt: String)? {
        let panelTitle = isEditing ? CompanionL10n.text("Edit Custom Action") : CompanionL10n.text("Custom Action")
        let panel = CompanionModalPanelStyle.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 450),
            title: panelTitle
        )
        panel.becomesKeyOnlyIfNeeded = false

        var result: (title: String, prompt: String)?
        let content = AIQuickActionEditorPanelView(
            title: panelTitle,
            initialTitle: initialTitle,
            initialPrompt: initialPrompt,
            saveAction: { title, prompt in
                result = (title, prompt)
                NSApp.stopModal(withCode: .OK)
            },
            cancelAction: {
                NSApp.stopModal(withCode: .cancel)
            }
        )

        let hostingView = CompanionInteractiveHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        CompanionModalPanelStyle.installGlassContent(hostingView, in: panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.close()
        return response == .OK ? result : nil
    }
}

private struct AIQuickActionEditorPanelView: View {
    let title: String
    let saveAction: (String, String) -> Void
    let cancelAction: () -> Void

    @State private var actionTitle: String
    @State private var prompt: String
    @State private var errorMessage = ""
    @FocusState private var isTitleFocused: Bool

    init(
        title: String,
        initialTitle: String,
        initialPrompt: String,
        saveAction: @escaping (String, String) -> Void,
        cancelAction: @escaping () -> Void
    ) {
        self.title = title
        self.saveAction = saveAction
        self.cancelAction = cancelAction
        _actionTitle = State(initialValue: initialTitle)
        _prompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(XiaoHuaErTheme.tint.opacity(0.16))
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(XiaoHuaErTheme.tint)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(CompanionL10n.text("Use {{text}} for the selected text. If omitted, Companion sends the selected text as the user message."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField(CompanionL10n.text("Action name, e.g. Polite Reply"), text: $actionTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 13)
                .frame(height: 42)
                .companionGlassField(radius: 13)
                .focused($isTitleFocused)
                .onSubmit(save)

            VStack(alignment: .leading, spacing: 7) {
                Text(CompanionL10n.text("Prompt"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .padding(8)
                    .frame(height: 156)
                    .companionGlassField(radius: 14)
            }

            Text(errorMessage.isEmpty ? " " : errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(XiaoHuaErTheme.coral)
                .frame(height: 16, alignment: .leading)

            HStack(spacing: 10) {
                Spacer()
                Button(CompanionL10n.text("Cancel"), action: cancelAction)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .neutral, minWidth: 78, height: 34))
                    .keyboardShortcut(.cancelAction)
                Button(CompanionL10n.text("Save"), action: save)
                    .buttonStyle(CompanionGlassButtonStyle(tone: .primary, minWidth: 88, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .companionGlassPanel(radius: 28, liquidOpacity: 0.18, shadowRadius: 28, shadowOpacity: 0.36)
        .onAppear {
            isTitleFocused = true
        }
    }

    private func save() {
        let trimmedTitle = actionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = CompanionL10n.text("Name this action first.")
            return
        }
        guard !trimmedPrompt.isEmpty else {
            errorMessage = CompanionL10n.text("Fill in a prompt template.")
            return
        }
        saveAction(trimmedTitle, trimmedPrompt)
    }
}
