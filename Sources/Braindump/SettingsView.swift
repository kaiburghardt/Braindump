import SwiftUI

struct SettingsView: View {
    let model: NotesModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(model: model)
            }
            Tab("Connections", systemImage: "link") {
                ConnectionSettings(links: model.links)
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: NotesModel

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

            Section("Radar") {
                Stepper(value: $model.checkIntervalDays, in: 1...30) {
                    Text("Remind me after \(model.checkIntervalDays) \(model.checkIntervalDays == 1 ? "day" : "days")")
                }
            }

            Section("Editor") {
                Slider(value: $model.fontSize, in: 12...22, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }
            }

            Section {
                Toggle("Suggest to-dos and radar items", isOn: $model.aiEnabled)
                LabeledContent("Status", value: model.engine.statusText)
            } header: {
                Text("AI")
            } footer: {
                Text("Without Apple Intelligence, Braindump uses a tiny model of its own that is trained entirely on your Mac and learns from your clicks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ConnectionSettings: View {
    let links: LinkPreviewService

    @State private var jiraSite = ""
    @State private var jiraEmail = ""
    @State private var jiraToken = ""
    @State private var jiraResult: String?
    @State private var notionToken = ""
    @State private var notionResult: String?
    @State private var busy = false

    var body: some View {
        Form {
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
