import SwiftUI

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var applyingSelection = false

    var body: some View {
        Page(title: L10n.s("notes.title"), subtitle: L10n.s("notes.subtitle")) {
            Button(action: create) {
                Label(L10n.s("notes.new"), systemImage: "plus")
            }
            .buttonStyle(SoftButtonStyle())
        } content: {
            NoteDestinationPicker()
                .card(padding: 14)
            if state.notes.isEmpty {
                EmptyHint(
                    icon: "note.text",
                    title: L10n.s("notes.emptyTitle"),
                    text: L10n.s("notes.emptyBody")
                )
                .card()
            } else {
                editor
                    .card(padding: 0)
            }
        }
        .onAppear {
            if let id = state.noteToOpen {
                select(id)
                state.noteToOpen = nil
            } else if selectedID == nil {
                select(state.notes.first?.id)
            }
        }
        .onChange(of: state.noteToOpen) { _, id in
            guard let id else { return }
            select(id)
            state.noteToOpen = nil
        }
        .onChange(of: state.notes.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                select(state.notes.first?.id)
            } else if selectedID == nil {
                select(state.notes.first?.id)
            }
        }
    }

    private var filtered: [FlowNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return state.notes }
        return state.notes.filter {
            $0.title.lowercased().contains(needle) || $0.body.lowercased().contains(needle)
        }
    }

    private var editor: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SearchField(text: $query, placeholder: L10n.s("notes.search"))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        if filtered.isEmpty {
                            Text(L10n.s("notes.noResults"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        ForEach(filtered) { note in
                            noteRow(note)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .frame(width: 260)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if selectedID != nil {
                    TextField(L10n.s("notes.titlePlaceholder"), text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                    ZStack(alignment: .topLeading) {
                        if draftBody.isEmpty {
                            Text(L10n.s("notes.bodyPlaceholder"))
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draftBody)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                    }
                    HStack(spacing: 8) {
                        Button(L10n.s("notes.copy")) {
                            state.copy(draftBody)
                        }
                        .buttonStyle(SoftButtonStyle())
                        Spacer()
                        Button(role: .destructive, action: deleteSelected) {
                            Label(L10n.s("notes.delete"), systemImage: "trash")
                        }
                        .buttonStyle(SoftButtonStyle())
                        .foregroundStyle(.red)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 520)
        .onChange(of: draftTitle) { _, title in commit(title: title, body: draftBody) }
        .onChange(of: draftBody) { _, body in commit(title: draftTitle, body: body) }
    }

    private func noteRow(_ note: FlowNote) -> some View {
        let selected = note.id == selectedID
        let heading = note.listTitle.isEmpty ? L10n.s("notes.untitled") : note.listTitle
        return Button {
            select(note.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.relative(note.updated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.violet.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ id: UUID?) {
        applyingSelection = true
        selectedID = id
        if let note = state.notes.first(where: { $0.id == id }) {
            draftTitle = note.title
            draftBody = note.body
        } else {
            draftTitle = ""
            draftBody = ""
        }
        DispatchQueue.main.async { applyingSelection = false }
    }

    private func commit(title: String, body: String) {
        guard !applyingSelection, let selectedID else { return }
        state.updateNote(id: selectedID, title: title, body: body)
    }

    private func create() {
        query = ""
        select(state.createNote())
    }

    private func deleteSelected() {
        guard let selectedID else { return }
        let next = state.notes.first { $0.id != selectedID }?.id
        state.deleteNote(selectedID)
        select(state.notes.contains(where: { $0.id == next }) ? next : state.notes.first?.id)
    }
}

struct NoteDestinationPicker: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.s("menu.noteDestination"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: selection) {
                    Text(L10n.s("notes.destination.flow")).tag(FlowConfig.noteDestinationFlow)
                    ForEach(folders) { folder in
                        Text(folder.menuTitle).tag(folder.id)
                    }
                    Text(L10n.s("notes.destination.pickApple")).tag(FlowConfig.noteDestinationPickApple)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Text(L10n.s("notes.destination.hint"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = state.appleNotesStatus, !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if AppleNotesFolder.decode(state.config.noteDestination) != nil, state.appleNoteFolders.isEmpty {
                state.refreshAppleNoteFolders()
            }
        }
    }

    private var folders: [AppleNotesFolder] {
        var items = state.appleNoteFolders
        if let current = AppleNotesFolder.decode(state.config.noteDestination),
           !items.contains(where: { $0.id == current.id }) {
            items.insert(current, at: 0)
        }
        return items
    }

    private var selection: Binding<String> {
        Binding(
            get: { state.config.noteDestination },
            set: { next in
                if next == FlowConfig.noteDestinationPickApple {
                    state.refreshAppleNoteFolders()
                    return
                }
                state.config.noteDestination = next
            }
        )
    }
}
