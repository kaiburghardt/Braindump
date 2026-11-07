import SwiftUI

struct SettingsView: View {
    let model: NotesModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
            Tab("Connections", systemImage: "link") {
                ConnectionSettings(links: model.links, ai: model.ai)
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: NotesModel

    /// Installed font families that aren't in the short lists above (hidden system fonts left out).
    private static let otherFamilies: [String] = {
        let listed = Set(EditorFont.monospacedChoices + EditorFont.proportionalChoices)
        return NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") && !listed.contains($0) }.sorted()
    }()

    private var displayPath: String {
        model.fileURL.path(percentEncoded: false)
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), with: "~/")
            .replacingOccurrences(of: "~//", with: "~/")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Another File…") { model.chooseFile() }
                    Button("Show in Finder") { model.revealInFinder() }
                    Spacer()
                    if model.fileURL != NotesModel.defaultURL {
                        Button("Default") { model.switchFile(to: NotesModel.defaultURL) }
                    }
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Your notes live in this file as readable JSON: per note its type, title, detail lines, when it was created and (for radar items) when you last checked. Archived to-dos go to “…-Archive.json” next to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HistorySettings(history: model.history)

            Section("Radar") {
                Stepper(value: $model.checkIntervalDays, in: 1...30) {
                    Text("Remind me after \(model.checkIntervalDays) \(model.checkIntervalDays == 1 ? "day" : "days")")
                }
            }

            Section("Editor") {
                Picker("Font", selection: $model.fontFamily) {
                    Section("Monospaced") {
                        ForEach(EditorFont.monospacedChoices.filter(EditorFont.isAvailable), id: \.self) { Text($0) }
                    }
                    Section("Proportional") {
                        ForEach(EditorFont.proportionalChoices.filter(EditorFont.isAvailable), id: \.self) { Text($0) }
                    }
                    Section("All Fonts") {
                        ForEach(Self.otherFamilies, id: \.self) { Text($0) }
                    }
                }
                Slider(value: $model.fontSize, in: 11...22, step: 1) {
                    Text("Size")
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }
                Text("Pick up the parcel – 4 posts 9 × 9 cm")
                    .font(Font(model.editorFont.font()))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Suggest to-dos and radar items", isOn: $model.aiEnabled)
                LabeledContent("Status", value: model.engine.statusText)
            } header: {
                Text("AI")
            } footer: {
                Text("With an AI server (Connections tab), suggestions come from the model you picked there. Otherwise Apple Intelligence is used if it's available, or a tiny model of Braindump's own that is trained entirely on your Mac and learns from your clicks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HistorySettings: View {
    @Bindable var history: HistoryStore

    var body: some View {
        Section {
            Picker("Keep History For", selection: $history.retentionHours) {
                ForEach(HistoryStore.retentionChoices, id: \.self) { hours in
                    Text(hours == 1 ? "1 hour" : hours < 48 ? "\(hours) hours" : "\(hours / 24) days").tag(hours)
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Braindump keeps every version of your notes from this time (Note → Show History, ⌘Y) – including text you deleted – and always at least the last \(HistoryStore.minimumEntries.formatted(.number.locale(Locale(identifier: "en_US")))) versions, however old. Older ones are removed automatically; the daily backups are separate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionSettings: View {
    let links: LinkPreviewService
    let ai: AIService

    @State private var jiraSite = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var jiraResult: String?
    @State private var notionToken = ""
    @State private var notionResult: String?
    @State private var busy = false

    var body: some View {
        Form {
            AISettings(ai: ai)

            Section {
                TextField("Jira Site", text: $jiraSite, prompt: Text("company.atlassian.net"))
                TextField("Email", text: $jiraEmail, prompt: Text("you@company.com"))
                SecureField("API Token", text: $jiraToken, prompt: Text(links.hasJiraToken ? "saved – only fill in to change" : "Paste token"))
                HStack {
                    Button("Save & Test") {
                        busy = true
                        Task {
                            jiraResult = await links.saveJira(site: jiraSite, email: jiraEmail, token: jiraToken)
                            jiraToken = ""
                            busy = false
                        }
                    }
                    .disabled(busy)
                    Link("Create Token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    Spacer()
                    if links.hasJiraToken {
                        Button("Remove", role: .destructive) { links.removeJira(); jiraResult = nil }
                    }
                }
                if let jiraResult { Text(jiraResult).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("Jira")
            } footer: {
                Text("Shows title and status of Jira links right in your notes. The token is stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Integration Token", text: $notionToken, prompt: Text(links.hasNotionToken ? "saved – only fill in to change" : "ntn_…"))
                HStack {
                    Button("Save & Test") {
                        busy = true
                        Task {
                            notionResult = await links.saveNotion(token: notionToken)
                            notionToken = ""
                            busy = false
                        }
                    }
                    .disabled(busy)
                    Link("Create Integration", destination: URL(string: "https://www.notion.so/profile/integrations")!)
                    Spacer()
                    if links.hasNotionToken {
                        Button("Remove", role: .destructive) { links.removeNotion(); notionResult = nil }
                    }
                }
                if let notionResult { Text(notionResult).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("Notion")
            } footer: {
                Text("Create an internal integration and paste its token here. Then give your pages access: open a page → ••• → Connections → your integration. Doing this on a top-level page covers all pages below it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            jiraSite = links.jiraSite.isEmpty ? links.suggestedJiraSite : links.jiraSite
            jiraEmail = links.jiraEmail
        }
    }
}

/// The AI server: any OpenAI-compatible chat API (a LiteLLM proxy, OpenAI, a local model server).
/// Nothing is preset – the address, key and model are all yours to fill in.
private struct AISettings: View {
    let ai: AIService

    @State private var server = ""
    @State private var key = ""
    @State private var typedModel = ""
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        Section {
            TextField("Server", text: $server, prompt: Text("https://llm.example.com"))
            SecureField("API Key", text: $key, prompt: Text(ai.hasKey ? "saved – only fill in to change" : "Paste key (if the server needs one)"))
            HStack {
                Button("Save & Test") {
                    busy = true
                    Task {
                        result = await ai.save(baseURL: server, key: key)
                        server = ai.baseURL
                        key = ""
                        busy = false
                    }
                }
                .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if !ai.baseURL.isEmpty || ai.hasKey {
                    Button("Remove", role: .destructive) {
                        ai.remove()
                        server = ""
                        typedModel = ""
                        result = nil
                    }
                }
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
            if !ai.baseURL.isEmpty {
                if ai.models.isEmpty {
                    HStack {
                        TextField("Model", text: $typedModel, prompt: Text("model name"))
                            .onSubmit { ai.setModel(typedModel) }
                        Button("Use") { ai.setModel(typedModel) }
                            .disabled(typedModel.trimmingCharacters(in: .whitespaces) == ai.model)
                    }
                } else {
                    Picker("Model", selection: Binding(get: { ai.model }, set: { ai.setModel($0) })) {
                        Text("Choose a model …").tag("")
                        if !ai.model.isEmpty && !ai.models.contains(ai.model) { Text(ai.model).tag(ai.model) }
                        ForEach(ai.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        } header: {
            Text("AI Server")
        } footer: {
            Text("Any OpenAI-compatible server, for example a LiteLLM proxy. Pick a small, fast model. Braindump sends note text there for suggestions and for the AI actions you click (Tidy Up, Extract To-Dos, Ask). The key is stored in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            server = ai.baseURL
            typedModel = ai.model
            if !ai.baseURL.isEmpty && ai.models.isEmpty { Task { await ai.loadModels() } }
        }
    }
}
