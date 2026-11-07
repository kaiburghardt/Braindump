import SwiftUI

struct ContentView: View {
    let model: NotesModel
    @AppStorage("showInspector") private var showSidebar = true
    /// The sidebar's width from the last launch, read once.
    @State private var initialSidebarWidth: Double = {
        let stored = UserDefaults.standard.double(forKey: "sidebarWidth")
        return stored >= 250 ? stored : 300
    }()
    /// The sidebar's width is measured from the outside (window − editor): measuring the
    /// inspector's content (onGeometryChange) made it ignore `ideal` and open at its default width.
    @State private var widths = Widths()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Like Xcode's inspector: the sidebar is a full-height column on the right with its own part
        // of the toolbar (just the toggle, at the far right); the note actions sit left of it, above
        // the editor. This needs the editor's toolbar inside a NavigationStack and the sidebar's
        // toolbar inside the inspector – declared on the outside, the inspector sits under one
        // undivided toolbar.
        NavigationStack {
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
                    .overlay(alignment: .bottom) {
                        if let notice = model.aiNotice {
                            AINoticeView(text: notice) { model.dismissAINotice() }
                                .padding(.bottom, 14)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy, value: model.aiNotice)
            }
            .sheet(isPresented: Bindable(model).askPresented) {
                AskView(model: model)
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { widths.editor = $0; saveSidebarWidth() }
            .toolbar { noteActions }
            .navigationTitle("Braindump")
            .navigationSubtitle("\(model.fileURL.lastPathComponent) · saves automatically")
        }
        .inspector(isPresented: $showSidebar) {
            SidebarView(model: model)
                .inspectorColumnWidth(min: 250, ideal: initialSidebarWidth, max: 480)
                // Stays in the toolbar while the sidebar is hidden, like Xcode's inspector button.
                .toolbar {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showSidebar.toggle()
                        } label: {
                            Label("Radar, To-Dos & Suggestions", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the sidebar (⌥⌘I)")
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { widths.window = $0; saveSidebarWidth() }
    }

    private final class Widths {
        var window = 0.0
        var editor = 0.0
    }

    /// Kept for the next launch. Not while the sidebar slides in or out.
    private func saveSidebarWidth() {
        let width = (widths.window - widths.editor).rounded()
        guard showSidebar, (250...480).contains(width) else { return }
        UserDefaults.standard.set(width, forKey: "sidebarWidth")
    }

    @ToolbarContentBuilder
    private var noteActions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleTodoAtSelection()
            } label: {
                Label("To-Do", systemImage: model.cursorNoteType == .todo ? "checkmark.circle" : "circle")
            }
            .help(model.cursorNoteType == .todo ? "Check off this to-do (⌘↩)" : "Make this note a to-do (⌘↩)")
            .disabled(model.cursorNoteType == nil)

            Button {
                model.toggleRadarAtSelection()
            } label: {
                Label("Radar", systemImage: "scope")
            }
            .help(model.cursorNoteType == .radar ? "Take this note off the radar (⇧⌘↩)" : "Put this note on the radar (⇧⌘↩)")
            .disabled(model.cursorNoteType == nil)
        }
        if model.ai.isConfigured {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.tidyUpAtSelection()
                } label: {
                    Label("Tidy Up", systemImage: "wand.and.sparkles")
                }
                .help("Tidy up this note with AI: short title, clean details (⌃⌘T)")
                .disabled(model.cursorNoteType == nil)

                Button {
                    model.extractAtSelection()
                } label: {
                    Label("Extract To-Dos", systemImage: "list.bullet.indent")
                }
                .help("Turn the selected text or this note into separate to-dos and radar items with AI (⌃⌘E)")
                .disabled(model.cursorNoteType == nil)

                Button {
                    model.askPresented = true
                } label: {
                    Label("Ask Braindump", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Ask a question about all your notes (⌘K)")
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "history")
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("What changed recently – bring back deleted notes (⌘Y)")
        }
    }
}

/// Short message about an AI action, floating over the bottom of the editor.
private struct AINoticeView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text(text)
                .lineLimit(2)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 20)
    }
}
