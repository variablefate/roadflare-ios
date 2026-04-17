import SwiftUI
import UIKit
import RidestrSDK

/// Custom in-app share tray for sharing a driver's QR code and deeplink.
struct DriverShareSheet: View {
    let pubkey: String
    let driverName: String?
    var pictureURL: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var driverAvatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(Color.rfPrimary.opacity(0.1))
                .frame(width: 72, height: 72)
            Image(systemName: "person.fill")
                .font(.system(size: 30))
                .foregroundColor(Color.rfPrimary)
        }
    }

    private var deeplink: String {
        guard let npub = try? NIP19.npubEncode(publicKeyHex: pubkey) else {
            return pubkey
        }
        let name = driverName ?? ""
        let nameParam = name.isEmpty ? "" : "?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
        return "nostr:\(npub)\(nameParam)"
    }

    private var shareText: String {
        guard let npub = try? NIP19.npubEncode(publicKeyHex: pubkey) else {
            return pubkey
        }
        return npub
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    Text(driverName ?? String(pubkey.prefix(8)) + "...")
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)

                    if let urlStr = pictureURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            driverAvatarPlaceholder
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                    } else {
                        driverAvatarPlaceholder
                    }

                    if let qrImage = QRCodeImage.generate(from: deeplink) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Text(shareText)
                        .font(RFFont.mono(11))
                        .foregroundColor(Color.rfOffline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = shareText
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(RFFont.title(14))
                                .foregroundColor(Color.rfPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.rfPrimary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        Button {
                            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                  let root = windowScene.keyWindow?.rootViewController else { return }
                            var topVC = root
                            while let presented = topVC.presentedViewController {
                                topVC = presented
                            }
                            let vc = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)
                            topVC.present(vc, animated: true)
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(RFFont.title(14))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.rfPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            .navigationTitle("Share Driver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color.rfPrimary)
                }
            }
        }
    }
}
