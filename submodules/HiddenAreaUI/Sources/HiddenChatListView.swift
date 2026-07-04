//
//  HiddenChatListView.swift
//  HiddenAreaUI  (pelegram)
//
//  Telegram-styled chat list for the hidden area. Three sections (spec point 2):
//  secret relay chats with people, chats with local-PC apps, and hidden normal
//  Telegram chats.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import SwiftUI
import HiddenCore

@available(iOS 15.0, *)
struct HiddenChatListView: View {
    @ObservedObject var model: HiddenViewModel
    var onOpen: (Conversation) -> Void
    var onSettings: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HiddenNavBar(
                title: "Hidden",
                subtitle: nil,
                leadingText: "Close",
                onLeading: onClose) {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape").foregroundColor(HiddenTheme.accent)
                    }
                }

            if model.conversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        section("Secret chats", model.relayConversations)
                        section("Apps", model.appConversations)
                        section("Hidden Telegram chats", model.telegramConversations)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundColor(.secondary)
            Text("No hidden chats yet").font(.headline)
            Text("Add a secret chat, an app, or hide a Telegram chat from Settings.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button(action: onSettings) {
                Text("Open Settings").fontWeight(.medium).foregroundColor(HiddenTheme.accent)
            }.padding(.top, 4)
            Spacer()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ convs: [Conversation]) -> some View {
        if !convs.isEmpty {
            HStack {
                Text(title.uppercased())
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

            ForEach(convs, id: \.id) { conv in
                Button(action: { onOpen(conv) }) {
                    HiddenChatRow(conv: conv, session: model.session)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        model.removeConversation(conv)
                    } label: {
                        Label(conv.kind == .telegramHidden ? "Un-hide" : "Delete chat",
                              systemImage: conv.kind == .telegramHidden ? "eye" : "trash")
                    }
                }
                Divider().padding(.leading, 78)
            }
        }
    }
}

@available(iOS 15.0, *)
struct HiddenChatRow: View {
    let conv: Conversation
    let session: HiddenSession

    var body: some View {
        HStack(spacing: 12) {
            HiddenAvatar(title: conv.title)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conv.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if conv.kind == .relayApp {
                        Text("APP").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(HiddenTheme.accent.opacity(0.15))
                            .foregroundColor(HiddenTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    if let last = conv.lastMessage {
                        Text(Self.time(last.timestamp)).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Text(preview).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let last = conv.lastMessage else {
            return conv.kind == .telegramHidden ? "Hidden Telegram chat" : "No messages yet"
        }
        if let media = last.media {
            switch media.kind {
            case .image: return "📷 Photo"
            case .video: return "🎬 Video"
            case .audio: return "🎧 Audio"
            case .file:  return "📎 " + media.filename
            }
        }
        return last.text
    }

    static func time(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
