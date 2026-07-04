//
//  HiddenMedia.swift
//  HiddenAreaUI  (pelegram)
//
//  Media rendering + picking for the hidden area (spec point 3), all wired to
//  the encrypted MediaStore (spec point 5):
//    - EncryptedImageView : decrypts a blob to a UIImage in memory.
//    - EncryptedVideoView : plays a blob via AVPlayer + an in-memory
//      AVAssetResourceLoader, so decrypted video bytes never touch disk.
//    - MediaPicker / DocumentPicker : pick photos/videos/files as Data.
//
//  The only place plaintext can reach disk is an explicit user "export", which
//  writes to the temp dir on demand (flagged for review).
//
//  UNVERIFIED BY BUILD (authored on Windows).
//

import SwiftUI
import UIKit
import AVKit
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import HiddenCore

// MARK: - Picked media payload

struct PickedMedia {
    var data: Data
    var filename: String
    var mime: String
    var width: Int
    var height: Int
    var durationMs: Int
}

// MARK: - Encrypted image

@available(iOS 15.0, *)
struct EncryptedImageView: View {
    let ref: MediaRef
    let session: HiddenSession
    var maxHeight: CGFloat = 260

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: maxHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 200, height: 160)
                    .overlay(ProgressView())
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let ref = ref
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            let data = session.loadMedia(ref)
            let img = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { self.image = img }
        }
    }
}

// MARK: - Encrypted video / audio

@available(iOS 15.0, *)
struct EncryptedVideoView: View {
    let ref: MediaRef
    let session: HiddenSession

    @State private var player: AVPlayer?
    @State private var loader: SegmentedAssetLoader?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: 240, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: 240, height: 180)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private func load() {
        guard player == nil else { return }
        // No pre-load: the resource loader decrypts only the segments the player
        // asks for, so a big video never sits whole in RAM.
        let loader = SegmentedAssetLoader(ref: ref, session: session)
        let rawExt = (ref.filename as NSString).pathExtension
        let ext = rawExt.isEmpty ? (ref.kind == .audio ? "m4a" : "mp4") : rawExt
        guard let url = URL(string: "hcmedia://local/\(UUID().uuidString).\(ext)") else { return }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "hcmedia.loader"))
        let item = AVPlayerItem(asset: asset)
        self.loader = loader
        self.player = AVPlayer(playerItem: item)
    }
}

/// Serves an encrypted, segmented blob to AVFoundation on byte-range request by
/// decrypting only the requested range (via HiddenSession.loadMediaRange), so
/// neither the whole plaintext nor a temp file ever exists on disk.
final class SegmentedAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let ref: MediaRef
    private let session: HiddenSession

    init(ref: MediaRef, session: HiddenSession) {
        self.ref = ref
        self.session = session
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            if let ut = UTType(mimeType: ref.mime) { info.contentType = ut.identifier }
            info.isByteRangeAccessSupported = true
            info.contentLength = Int64(ref.size)
        }
        if let req = loadingRequest.dataRequest {
            let start = Int(req.currentOffset)
            if start >= ref.size {
                loadingRequest.finishLoading()
                return true
            }
            let remaining = ref.size - start
            let length = req.requestsAllDataToEndOfResource
                ? remaining
                : min(req.requestedLength, remaining)
            if length > 0, let data = session.loadMediaRange(ref, offset: start, length: length) {
                req.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        return true
    }
}

// MARK: - Photo / video picker (PHPicker)

@available(iOS 15.0, *)
struct MediaPicker: UIViewControllerRepresentable {
    var onPicked: (PickedMedia) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            let ids = provider.registeredTypeIdentifiers
            let preferred = ids.first(where: {
                guard let ut = UTType($0) else { return false }
                return ut.conforms(to: .image) || ut.conforms(to: .movie) || ut.conforms(to: .audio)
            }) ?? ids.first
            guard let typeId = preferred else { return }

            provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                guard let data = data else { return }
                let ut = UTType(typeId)
                let mime = ut?.preferredMIMEType ?? "application/octet-stream"
                let ext = ut?.preferredFilenameExtension ?? "dat"
                let base = provider.suggestedName ?? "media"
                var width = 0, height = 0
                if ut?.conforms(to: .image) == true, let img = UIImage(data: data) {
                    width = Int(img.size.width * img.scale)
                    height = Int(img.size.height * img.scale)
                }
                let picked = PickedMedia(data: data, filename: "\(base).\(ext)", mime: mime,
                                         width: width, height: height, durationMs: 0)
                DispatchQueue.main.async { self.parent.onPicked(picked) }
            }
        }
    }
}

// MARK: - Arbitrary file picker (UIDocumentPicker)

@available(iOS 15.0, *)
struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: (PickedMedia) -> Void
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.presentationMode.wrappedValue.dismiss()
            guard let url = urls.first else { return }
            let didScope = url.startAccessingSecurityScopedResource()
            defer { if didScope { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let ut = UTType(filenameExtension: url.pathExtension)
            let mime = ut?.preferredMIMEType ?? "application/octet-stream"
            let picked = PickedMedia(data: data, filename: url.lastPathComponent, mime: mime,
                                     width: 0, height: 0, durationMs: 0)
            // The picked copy in the system inbox is transient; we hold the bytes
            // in memory and hand them to the encrypted store.
            parent.onPicked(picked)
        }
    }
}

// MARK: - Explicit export (the one place plaintext may reach disk)

@available(iOS 15.0, *)
enum HiddenExport {
    /// Decrypt a blob to a temp file for sharing. FLAGGED: this is the single
    /// deliberate exception to "no plaintext on disk", gated behind an explicit
    /// user action + confirm in the UI. Written into a unique, protected folder
    /// that the ShareSheet deletes once dismissed.
    static func temporaryURL(for ref: MediaRef, session: HiddenSession) -> URL? {
        guard let data = session.loadMedia(ref) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hcexport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = ref.filename.isEmpty ? "file" : ref.filename
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}

@available(iOS 15.0, *)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// If set, this file's *enclosing* directory is deleted when the sheet closes.
    var cleanupURL: URL? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let cleanup = cleanupURL
        vc.completionWithItemsHandler = { _, _, _, _ in
            if let u = cleanup {
                try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
            }
        }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
