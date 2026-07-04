//
//  HiddenRootView.swift
//  HiddenAreaUI  (pelegram)
//
//  Telegram-styled root of the hidden area. Uses a simple state-driven router
//  (list / chat / settings) so the header can be styled exactly like Telegram's
//  without fighting UINavigationController chrome.
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import SwiftUI
import HiddenCore

// MARK: - Theme

@available(iOS 15.0, *)
enum HiddenTheme {
    static let accent = Color(red: 0.20, green: 0.51, blue: 0.92)   // Telegram blue
    static let outgoing = Color(red: 0.90, green: 0.96, blue: 0.83) // light-green sent bubble
    static let outgoingDark = Color(red: 0.10, green: 0.35, blue: 0.24)
    static let incoming = Color(.secondarySystemBackground)

    static func bubble(_ outgoing: Bool, _ scheme: ColorScheme) -> Color {
        if outgoing { return scheme == .dark ? outgoingDark : Color(red: 0.85, green: 0.94, blue: 0.78) }
        return Color(.secondarySystemBackground)
    }

    static let avatarPalette: [Color] = [
        Color(red: 0.94, green: 0.42, blue: 0.42),
        Color(red: 0.36, green: 0.68, blue: 0.94),
        Color(red: 0.55, green: 0.78, blue: 0.35),
        Color(red: 0.96, green: 0.68, blue: 0.30),
        Color(red: 0.66, green: 0.52, blue: 0.90),
        Color(red: 0.36, green: 0.80, blue: 0.74)
    ]

    static func avatarColor(for key: String) -> Color {
        let h = abs(key.hashValue)
        return avatarPalette[h % avatarPalette.count]
    }
}

// MARK: - Avatar

@available(iOS 15.0, *)
struct HiddenAvatar: View {
    let title: String
    var size: CGFloat = 46

    private var monogram: String {
        let t = title.hasPrefix("@") ? String(title.dropFirst()) : title
        return String(t.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(HiddenTheme.avatarColor(for: title))
            Text(monogram)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Header

@available(iOS 15.0, *)
struct HiddenNavBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var leadingText: String
    var onLeading: () -> Void
    var trailing: () -> Trailing

    init(title: String,
         subtitle: String? = nil,
         leadingText: String,
         onLeading: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leadingText = leadingText
        self.onLeading = onLeading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onLeading) {
                Text(leadingText).foregroundColor(HiddenTheme.accent)
            }
            Spacer(minLength: 8)
            VStack(spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .bottom)
    }
}

// MARK: - Root router

@available(iOS 15.0, *)
struct HiddenRootView: View {
    @ObservedObject var model: HiddenViewModel
    var onClose: () -> Void

    enum Route: Equatable { case list, settings, chat(String) }
    @State private var route: Route = .list

    var body: some View {
        Group {
            switch route {
            case .list:
                HiddenChatListView(
                    model: model,
                    onOpen: open,
                    onSettings: { route = .settings },
                    onClose: onClose)
            case .settings:
                HiddenSettingsView(model: model, onBack: { route = .list })
            case let .chat(id):
                HiddenChatView(model: model, convId: id, onBack: { route = .list })
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func open(_ conv: Conversation) {
        if conv.kind == .telegramHidden {
            model.openTelegramChat(conv.peerId)
        } else {
            route = .chat(conv.id)
        }
    }
}
