import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - New signature sheet
//
// Three ways to make a reusable signature: draw it on the SignaturePad (port
// of signature_pad), type it in a script face that ships with macOS, or
// import a photo / scan (the paper is keyed out). Saved to SignatureLibrary.

struct SignatureCreatorSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case draw = "Draw"
        case type = "Type"
        case image = "Image"

        var id: String { rawValue }
    }

    /// Called with the stored signature (so the caller can place it at once).
    var onCreated: (SignatureArtwork) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var pad = SignaturePadController()
    @State private var mode: Mode = .draw
    @State private var label = "Signature"
    @State private var inkColor: SignatureInkColor = .black
    @State private var typedName = ESignDefaults.signerName
    @State private var fontName = SignatureFonts.available.first?.name ?? ""
    @State private var importedPNG: Data?
    @State private var importedPreview: NSImage?
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var errorText: String?

    private var canSave: Bool {
        switch mode {
        case .draw: return !pad.isEmpty
        case .type: return !typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: return importedPNG != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FFTheme.heroGradient)
                        .frame(width: 30, height: 30)
                    Image(systemName: "signature")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Signature")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Saved on this Mac and reusable on any document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .draw: drawPane
                case .type: typePane
                case .image: imagePane
                }
            }
            .frame(height: 250)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Signature", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Menu {
                    Button("Signature") { label = "Signature" }
                    Button("Initials") { label = "Initials" }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Signature") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 640)
        .onChange(of: mode) { _, _ in errorText = nil }
    }

    // MARK: Draw

    private var drawPane: some View {
        VStack(spacing: 8) {
            SignaturePadRepresentable(controller: pad, inkColor: inkColor.nsColor)
                .frame(height: 200)
                .clipShape(FFTheme.cardShape)
                .overlay(FFTheme.cardShape.strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
                .overlay {
                    if pad.isEmpty {
                        Text("Sign here with your trackpad or mouse")
                            .foregroundStyle(Color.black.opacity(0.28))
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                colorPicker
                Spacer()
                Button { pad.undo() } label: { Label("Undo Stroke", systemImage: "arrow.uturn.backward") }
                    .disabled(pad.isEmpty)
                Button { pad.clear() } label: { Label("Clear", systemImage: "eraser") }
                    .disabled(pad.isEmpty)
            }
        }
    }

    // MARK: Type

    private var typePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Your name", text: $typedName)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(SignatureFonts.available, id: \.name) { face in
                        Button { fontName = face.name } label: {
                            Text(typedName.isEmpty ? "Signature" : typedName)
                                .font(.custom(face.name, size: 26))
                                .foregroundStyle(Color(nsColor: inkColor.nsColor))
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(FFTheme.cardShape.fill(Color.white))
                                .overlay(FFTheme.cardShape.strokeBorder(
                                    fontName == face.name ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: fontName == face.name ? 2 : 1))
                                .contentShape(FFTheme.cardShape)
                        }
                        .buttonStyle(.plain)
                        .help(face.title)
                    }
                }
            }
            colorPicker
        }
    }

    // MARK: Image

    private var imagePane: some View {
        VStack(spacing: 8) {
            ZStack {
                FFTheme.cardShape.fill(Color.white)
                if let importedPreview {
                    Image(nsImage: importedPreview)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                } else if importing {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("Drop a photo or scan of your signature")
                            .foregroundStyle(Color.black.opacity(0.7))
                        Text("Sign on white paper with a dark pen — the background is removed.")
                            .font(.caption)
                            .foregroundStyle(Color.black.opacity(0.45))
                    }
                }
            }
            .frame(height: 200)
            .overlay(FFTheme.cardShape
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in importImage(url) }
                }
                return true
            }
            HStack {
                Button("Choose Image…") { chooseImage() }
                Spacer()
                if importedPNG != nil {
                    Button("Remove") {
                        importedPNG = nil
                        importedPreview = nil
                    }
                }
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            Text("Ink")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(SignatureInkColor.allCases) { color in
                Button { inkColor = color } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: inkColor == color ? 2 : 0)
                            .padding(-3))
                }
                .buttonStyle(.plain)
                .help(color.title)
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo or scan of your signature"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url)
    }

    private func importImage(_ url: URL) {
        importing = true
        errorText = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SignatureImageImporter.process(url) }
            }.value
            importing = false
            switch result {
            case .success(let png):
                importedPNG = png
                importedPreview = NSImage(data: png)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: Save

    private func save() {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var artwork = SignatureArtwork(label: name.isEmpty ? "Signature" : name, kind: .drawn,
                                       colorHex: inkColor.rawValue)
        var png: Data?
        switch mode {
        case .draw:
            artwork.ink = pad.ink
        case .type:
            artwork.kind = .typed
            artwork.text = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
            artwork.fontName = fontName
        case .image:
            artwork.kind = .image
            png = importedPNG
        }
        let library = SignatureLibrary.shared
        do {
            try library.add(artwork, imagePNG: png)
            guard let stored = library.items.first(where: { $0.id == artwork.id }),
                  library.drawable(for: stored) != nil else {
                errorText = "That signature came out empty — try again."
                library.delete(artwork.id)
                return
            }
            onCreated(stored)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
