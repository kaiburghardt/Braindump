import SwiftUI

struct ContentView: View {
    let model: NotesModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            if case .failed(let message) = model.saveStatus {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Choose Another File…") { model.chooseFile() }
                        .controlSize(.small)
                }
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.85))
            }
            EditorView(model: model)
        }
        .inspector(isPresented: $showInspector) {
            SidebarView(model: model)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Radar, To-Dos & Suggestions", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the sidebar (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .navigationTitle("Braindump")
        .navigationSubtitle("\(model.fileURL.lastPathComponent) · saves automatically")
    }
}
