import SwiftUI
import AppKit

/// Shown once after a successful first launch (Gatekeeper already passed).
struct FirstRunSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(FFTheme.heroGradient)
                        .frame(width: 48, height: 48)
                        .shadow(color: Color.accentColor.opacity(0.30), radius: 10, y: 3)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("You're all set")
                        .font(.title2.weight(.semibold))
                    Text("aiFlow \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .ffBadge()
                }
            }

            Text("If macOS asked you to allow aiFlow once under System Settings → Privacy & Security, that was expected. This is a free open-source app without a paid Apple Developer certificate — the one-time Open Anyway step is safe.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            Text("When you browse Desktop, Documents, or Downloads, macOS may ask for folder access — click Allow. You can enable the optional Finder right-click menu later under Login Items & Extensions.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    if let u = URL(string: "https://github.com/nnikolaandric-sudo/aiFlow") {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.link)

                Spacer()

                Button("Continue") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
