//
//  ClipboardPreviewPanel.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// Unsaved preview edits, kept by entry id.
///
/// The panel is handed its entry by the coordinator, so an edit can be interrupted by
/// something outside the panel's control: previewing a different tile, the notch closing, the
/// tab changing. Any of those used to drop the typing with no trace. Stashing it means the
/// edit is still there — with the "Unsaved edit" footer explaining it — when that entry comes
/// back. Cleared the moment the edit is resolved, either way.
@MainActor
final class ClipboardDraftStore {
    static let shared = ClipboardDraftStore()

    private var drafts: [UUID: String] = [:]

    func stash(_ draft: String, for id: UUID) { drafts[id] = draft }
    func draft(for id: UUID) -> String? { drafts[id] }
    func clear(_ id: UUID) { drafts[id] = nil }
}

struct ClipboardPreviewPanel: View {
    let entry: ClipboardEntry
    let onDismiss: () -> Void
    @EnvironmentObject private var vm: BoringViewModel
    @State private var didCopy = false
    @State private var showDeleteConfirm = false

    @State private var draft = ""
    @State private var baseline = ""
    @State private var showCloseGuard = false
    @State private var revertedSnapshot: String?
    @State private var revertNoticeTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    private var editableText: String? {
        if case .text(let str) = entry.content { return str }
        return nil
    }

    private var isDirty: Bool { editableText != nil && draft != baseline }

    /// Capture skips whitespace-only text, so an edit must not be able to write one either.
    private var canSave: Bool {
        isDirty && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // No background — the black island surface is the background.
        // A 0.5pt separator is drawn by the caller above this panel.
        ZStack(alignment: .topTrailing) {
            if editableText != nil {
                editableContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                contentView
                    .padding(.leading, 10)
                    .padding(.trailing, 56)
                    .padding(.vertical, 8)
            }

            HStack(spacing: 6) {
                // While an edit is in flight this copies the DRAFT, not the stored text:
                // copying something other than what is on screen is never what was meant.
                Button {
                    if isDirty {
                        copyDraft()
                    } else {
                        ClipboardManager.shared.copy(entry)
                        flashCopied()
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                        .foregroundStyle(didCopy ? Color.green : Color.white.opacity(0.75))
                        .animation(.spring(response: 0.3), value: didCopy)
                }
                .buttonStyle(.plain)

                Button {
                    requestClipboardDelete(confirm: $showDeleteConfirm, onDelete: deleteEntry)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(HoverActionBackdrop(tint: Color.red.opacity(0.30)))
                        .foregroundStyle(.red.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Delete")

                Button(action: requestDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isDirty ? Color.warningTint.opacity(0.22) : Color.white.opacity(0.13)))
                        .foregroundStyle(isDirty ? Color.warningTint : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
        .clipboardDeleteConfirmation(isPresented: $showDeleteConfirm, onDelete: deleteEntry)
        .onAppear { adoptEntryText() }
        // The entry can be swapped underneath the panel by previewing another tile
        .onChange(of: entry.id) { previousID, _ in
            if isDirty { ClipboardDraftStore.shared.stash(draft, for: previousID) }
            cancelRevertNotice()
            showCloseGuard = false
            adoptEntryText()
        }
        // A save rewrites the entry and the coordinator hands the panel the new value back,
        // so the baseline has to follow it or the footer would stay dirty forever.
        .onChange(of: editableText ?? "") { _, newValue in
            guard newValue != baseline else { return }
            if draft == baseline { draft = newValue }
            baseline = newValue
        }
        // Covers every exit the buttons do not: the notch closing, the entry being deleted,
        // the tab changing. Leaving either flag set would strand the keyboard or the island.
        .onDisappear {
            if isDirty { ClipboardDraftStore.shared.stash(draft, for: entry.id) }
            revertNoticeTask?.cancel()
            setNotchTextEditing(false)
            vm.isModalDialogActive = false
        }
    }

    /// `remove(id:)` clears the previewed entry when it matches, so the island collapses on
    /// its own — animated here so it rides the same spring as a manual dismiss.
    private func deleteEntry() {
        // Before the removal, so the teardown that follows sees a clean draft and does not
        // stash an edit for an entry that no longer exists
        draft = baseline
        ClipboardDraftStore.shared.clear(entry.id)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            ClipboardManager.shared.remove(id: entry.id)
        }
    }

    // MARK: - Editing

    private func adoptEntryText() {
        let text = editableText ?? ""
        baseline = text
        draft = ClipboardDraftStore.shared.draft(for: entry.id) ?? text
        // A restored edit has to hold the island open exactly as a live one does
        if isDirty { vm.isModalDialogActive = true }
    }

    /// The notch panel refuses key status by default, so a text view inside it would render
    /// perfectly and never see a keystroke. This is what lends it the keyboard.
    private func setNotchTextEditing(_ editing: Bool) {
        NotificationCenter.default.post(
            name: .notchTextEditingChanged,
            object: nil,
            userInfo: ["editing": editing]
        )
    }

    /// Bootstraps focus for a click the text view could not act on itself: it can be made
    /// first responder in a non-key window, but only key status delivers keystrokes to it.
    private func beginEditing() {
        guard editableText != nil, !editorFocused else { return }
        editorFocused = true
    }

    private func endEditing() {
        editorFocused = false
        // An unsaved draft still has to hold the island open, or a stray cursor move closes
        // the notch and takes the edit with it.
        vm.isModalDialogActive = isDirty
        vm.beginCloseGrace()
    }

    private func save() {
        guard canSave else { return }
        cancelRevertNotice()
        ClipboardDraftStore.shared.clear(entry.id)
        ClipboardManager.shared.updateText(draft, for: entry.id)
        baseline = draft
        endEditing()
    }

    private func saveAndCopy() {
        copyDraft()
        save()
    }

    /// Deliberately not `copy(_:)` — that records a new history entry, which is precisely
    /// what "just copy this edit" must not do.
    private func copyDraft() {
        cancelRevertNotice()
        ClipboardManager.shared.copyWithoutRecording([draft as NSString])
        flashCopied()
    }

    private func flashCopied() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.25)) { didCopy = false }
        }
    }

    private func revert() {
        guard isDirty else { return }
        ClipboardDraftStore.shared.clear(entry.id)
        let discarded = draft
        withAnimation(.easeInOut(duration: 0.18)) {
            draft = baseline
            revertedSnapshot = discarded
        }
        endEditing()
        revertNoticeTask?.cancel()
        revertNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { revertedSnapshot = nil }
        }
    }

    private func undoRevert() {
        guard let snapshot = revertedSnapshot else { return }
        cancelRevertNotice()
        ClipboardDraftStore.shared.stash(snapshot, for: entry.id)
        withAnimation(.easeInOut(duration: 0.18)) { draft = snapshot }
        vm.isModalDialogActive = true
    }

    private func cancelRevertNotice() {
        revertNoticeTask?.cancel()
        revertNoticeTask = nil
        if revertedSnapshot != nil {
            withAnimation(.easeOut(duration: 0.2)) { revertedSnapshot = nil }
        }
    }

    /// An unsaved edit is never dropped silently. The confirmation is inline rather than an
    /// alert because an alert is its own window: it would take focus from the editor and
    /// pull the cursor off the island.
    private func requestDismiss() {
        guard isDirty else {
            dismiss()
            return
        }
        editorFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showCloseGuard = true }
    }

    private func dismiss() {
        setNotchTextEditing(false)
        vm.isModalDialogActive = false
        onDismiss()
    }

    private func discardAndDismiss() {
        ClipboardDraftStore.shared.clear(entry.id)
        draft = baseline
        dismiss()
    }

    private func saveAndDismiss() {
        guard canSave else { return }
        ClipboardDraftStore.shared.clear(entry.id)
        ClipboardManager.shared.updateText(draft, for: entry.id)
        baseline = draft
        dismiss()
    }

    // MARK: - Editable text

    private var editableContent: some View {
        VStack(spacing: 6) {
            editor
                .padding(.trailing, 46)

            if isDirty || showCloseGuard || revertedSnapshot != nil {
                footer
                    .frame(height: 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isDirty)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showCloseGuard)
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(editorFocused ? 0.06 : 0.03))
            )
            .overlay(alignment: .leading) {
                // A single soft edge rather than an outline — a saturated rectangle reads as
                // a foreign object inside the island.
                if editorFocused {
                    Capsule()
                        .fill(Color.notchHighlight.opacity(0.8))
                        .frame(width: 2.5)
                        .padding(.vertical, 3)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: editorFocused)
            // Scrolling a long entry — reading it or editing it — must not be reinterpreted
            // as the island's close gesture. Horizontal is left alone so tab switching works.
            .ownsScrolling(axis: .vertical)
            // Simultaneous rather than `onTapGesture`: a consuming tap would swallow the
            // click the text view needs to place its caret.
            .simultaneousGesture(TapGesture().onEnded { beginEditing() })
            .onChange(of: editorFocused) { _, focused in
                setNotchTextEditing(focused)
                if focused {
                    cancelRevertNotice()
                    vm.isModalDialogActive = true
                    if showCloseGuard {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showCloseGuard = false }
                    }
                }
            }
            .onExitCommand { endEditing() }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            statusIndicator

            Spacer(minLength: 8)

            if showCloseGuard {
                plainButton("Keep editing") { beginEditing() }
                capsuleButton("Discard", fill: Color.red.opacity(0.22), tint: .red.opacity(0.95), action: discardAndDismiss)
                capsuleButton("Save & close", icon: "checkmark", fill: Color.notchHighlight, tint: .white, action: saveAndDismiss)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
            } else if isDirty {
                plainButton("Revert", action: revert)
                capsuleButton("Copy", icon: "doc.on.doc", fill: Color.white.opacity(0.10), tint: .white.opacity(0.85), action: copyDraft)
                    .keyboardShortcut("c", modifiers: [.command, .option])
                saveButton
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if let snapshot = revertedSnapshot, !isDirty {
            HStack(spacing: 6) {
                Text("Reverted")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Undo") { undoRevert() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.notchHighlight)
            }
            .help("Restore \(snapshot.prefix(40))")
        } else if isDirty {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.warningTint)
                Text("Unsaved edit")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    /// One capsule, two hit zones: the label saves, the chevron offers the variant.
    private var saveButton: some View {
        HStack(spacing: 0) {
            Button(action: save) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                    Text("Save").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Update this entry in place (⌘↩)")
            .disabled(!canSave)

            Rectangle()
                .fill(Color.black.opacity(0.22))
                .frame(width: 1, height: 16)

            Menu {
                Button("Save to History", action: save)
                Button("Save & Copy", action: saveAndCopy)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!canSave)
            .frame(width: 22)
            .padding(.vertical, 5)
        }
        .background(Capsule().fill(Color.notchHighlight))
        .opacity(canSave ? 1 : 0.4)
    }

    private func plainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func capsuleButton(
        _ title: String,
        icon: String? = nil,
        fill: Color,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                }
                Text(title).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contentView: some View {
        switch entry.content {
        case .text(let str):
            ScrollView {
                Text(str)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fileURLs(let urls) where urls.isEmpty:
            Text("No files")
                .font(.caption)
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .fileURLs(let urls):
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(urls, id: \.absoluteString) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: ClipboardFileIcon.image(for: url))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .ownsScrolling(axis: .vertical)
        }
    }
}

private extension Color {
    /// The one amber used by the unsaved-edit state, kept off `.yellow` so it stays legible
    /// against the island's black.
    static let warningTint = Color(red: 1.0, green: 0.72, blue: 0.23)
}
