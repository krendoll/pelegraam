//
//  HiddenChatView.swift
//  HiddenAreaUI  (pelegram)
//
//  Telegram-styled message thread for a relay conversation, with text and media
//  bubbles (spec point 3). Media is rendered straight from the encrypted store.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import SwiftUI
import HiddenCore

@available(iOS 15.0, *)
private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

@available(iOS 15.0, *)
struct HiddenChatView: View {
    @ObservedObject var model: HiddenViewModel
    let convId: String
    var onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var showPhotoPicker = false
    @State private var showDocPicker = false
    @State private var exportCandidate: MediaRef?
    @State private var exportItem: ExportItem?

    private var conv: Conversation? { model.conversation(convId) }
    private var messages: [StoredMessage] { model.messages(for: convId) }

    var body: some View {
        VStack(spacing: 0) {
            HiddenNavBar(
                title: conv?.title ?? "Chat",
                subtitle: statusText,
                leadingText: "Back",
                onLeading: onBack) { EmptyView() }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages, id: \.id) { m in
                            bubble(m).id(m.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            inputBar
        }
        .sheet(isPresented: $showPhotoPicker) {
            MediaPicker { picked in send(picked) }
        }
        .sheet(isPresented: $showDocPicker) {
            DocumentPicker { picked in send(picked) }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url], cleanupURL: item.url)
        }
        .confirmationDialog("Export this file? The decrypted copy will leave the encrypted area.",
                            isPresented: Binding(get: { exportCandidate != nil },
                                                 set: { if !$0 { exportCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Export", role: .destructive) {
                if let ref = exportCandidate,
                   let url = HiddenExport.temporaryURL(for: ref, session: model.session) {
                    exportItem = ExportItem(url: url)
                }
                exportCandidate = nil
            }
            Button("Cancel", role: .cancel) { exportCandidate = nil }
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(_ m: StoredMessage) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if m.outgoing { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 4) {
                if let media = m.media { mediaView(media) }
                if !m.text.isEmpty {
                    Text(m.text).font(.body).fixedSize(horizontal: false, vertical: true)
                }
                Text(HiddenChatRow.time(m.timestamp))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(HiddenTheme.bubble(m.outgoing, scheme))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if !m.outgoing { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: m.outgoing ? .trailing : .leading)
    }

    @ViewBuilder
    private func mediaView(_ media: MediaRef) -> some View {
        switch media.kind {
        case .image:
            EncryptedImageView(ref: media, session: model.session)
        case .video, .audio:
            EncryptedVideoView(ref: media, session: model.session)
        case .file:
            Button(action: { exportCandidate = media }) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.title3).foregroundColor(HiddenTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.filename).font(.subheadline).lineLimit(1)
                        Text(Self.sizeString(media.size)).font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                Button { showDocPicker = true } label: { Label("File", systemImage: "paperclip") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26)).foregroundColor(HiddenTheme.accent)
            }
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .onSubmit(sendText)
            Button(action: sendText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(canSend ? HiddenTheme.accent : .secondary)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendText() {
        let text = draft
        draft = ""
        model.sendText(text, to: convId)
    }

    private func send(_ picked: PickedMedia) {
        model.sendMedia(data: picked.data, filename: picked.filename, mime: picked.mime,
                        width: picked.width, height: picked.height, durationMs: picked.durationMs,
                        to: convId)
    }

    private var statusText: String {
        switch model.status(for: convId) {
        case .idle: return "offline"
        case .connecting: return "connecting…"
        case .online: return "online"
        case .reconnecting: return "reconnecting…"
        case .authError: return "auth error"
        }
    }

    static func sizeString(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
