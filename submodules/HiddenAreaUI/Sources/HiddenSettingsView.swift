//
//  HiddenSettingsView.swift
//  HiddenAreaUI  (pelegram)
//
//  Settings for the hidden area (spec point 4). Lives INSIDE the hidden area,
//  styled like Telegram Settings. Contains only what the spec asks for: adding a
//  new chat, hiding online status, and auto-delete for relay chats.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import SwiftUI
import HiddenCore

@available(iOS 15.0, *)
struct HiddenSettingsView: View {
    @ObservedObject var model: HiddenViewModel
    var onBack: () -> Void

    @State private var personName = ""
    @State private var personToken = ""
    @State private var appName = ""
    @State private var appToken = ""
    @State private var username = ""

    private let autoDeleteOptions: [(String, Int)] = [
        ("Off", 0), ("1 day", 1), ("1 week", 7), ("1 month", 30)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HiddenNavBar(title: "Settings", subtitle: nil, leadingText: "Back", onLeading: onBack) {
                EmptyView()
            }
            Form {
                newSecretChatSection
                newAppChatSection
                hideTelegramSection
                hiddenChatsSection
                privacySection
                autoDeleteSection
            }
        }
    }

    // MARK: New chat

    private var newSecretChatSection: some View {
        Section {
            TextField("Name", text: $personName)
                .autocorrectionDisabled(true)
            TextField("Relay room token", text: $personToken)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            Button("Add secret chat") {
                model.addRelayPerson(title: personName, token: personToken)
                personName = ""; personToken = ""
            }
            .disabled(personName.isEmpty || personToken.isEmpty)
        } header: {
            Text("New secret chat (via relay)")
        } footer: {
            Text("E2E chat with another person. Both sides share the same relay room token.")
        }
    }

    private var newAppChatSection: some View {
        Section {
            TextField("App name", text: $appName)
                .autocorrectionDisabled(true)
            TextField("Relay room token", text: $appToken)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            Button("Add app chat") {
                model.addRelayApp(title: appName, token: appToken)
                appName = ""; appToken = ""
            }
            .disabled(appName.isEmpty || appToken.isEmpty)
        } header: {
            Text("New app chat")
        } footer: {
            Text("Chat with an application on your local PC, bot-style, over the relay.")
        }
    }

    // MARK: Restore hidden chats

    private var hiddenChatsSection: some View {
        Section {
            if model.telegramConversations.isEmpty {
                Text("No hidden Telegram chats")
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.telegramConversations, id: \.id) { conv in
                    HStack {
                        Text(conv.title).lineLimit(1)
                        Spacer()
                        Button("Restore") { model.unhideTelegramChat(conv) }
                            .buttonStyle(.borderless)
                            .foregroundColor(HiddenTheme.accent)
                    }
                }
                Button(role: .destructive) {
                    model.unhideAllTelegramChats()
                } label: {
                    Text("Restore all hidden chats")
                }
            }
        } header: {
            Text("Hidden Telegram chats")
        } footer: {
            Text("Restore brings a chat back to the main list and every folder (un-archives and un-mutes it). Use “Restore all” if a chat got stuck hidden.")
        }
    }

    private var hideTelegramSection: some View {
        Section {
            TextField("@username", text: $username)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            Button("Hide this Telegram chat") {
                model.hideTelegramChat(username: username)
                username = ""
            }
            .disabled(username.isEmpty)
        } header: {
            Text("Hide a Telegram chat")
        } footer: {
            Text("Archives and mutes the chat so it leaves the main list and stops notifying. It is NOT fully erased — it can still be found in Archive and search. The chat and its data are never deleted from Telegram. Only public @username chats can be hidden this way.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Hide online status", isOn: Binding(
                get: { model.hideOnline },
                set: { model.setHideOnline($0) }))
        } header: {
            Text("Privacy")
        } footer: {
            Text("Keeps your account appearing offline while the hidden area is open.")
        }
    }

    // MARK: Auto-delete

    private var autoDeleteSection: some View {
        Section {
            Picker("Delete old messages", selection: Binding(
                get: { model.autoDeleteDays },
                set: { model.setAutoDeleteDays($0) })) {
                ForEach(autoDeleteOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
        } header: {
            Text("Auto-delete (relay chats)")
        } footer: {
            Text("Automatically removes messages and their files from relay chats after this period. Applies to relay chats only.")
        }
    }
}
