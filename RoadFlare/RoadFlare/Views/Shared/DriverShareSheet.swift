import SwiftUI
import UIKit
import RidestrSDK

/// Custom in-app share tray for sharing a driver's QR code and deeplink.
/// Shows an orange-on-gray QR code matching the Kinetic Beacon design system.
struct DriverShareSheet: View {
    let driver: FollowedDriver
    let driverName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var deeplink: String {
        guard let npub = try? NIP19.npubEncode(publicKeyHex: driver.pubkey) else {
            return driver.pubkey
        }
        let name = driverName ?? ""
        let nameParam = name.isEmpty ? "" : "?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
        return "nostr:\(npub)\(nameParam)"
    }

    private var shareText: String {
        guard let npub = try? NIP19.npubEncode(publicKeyHex: driver.pubkey) else {
            return driver.pubkey
        }
        return npub
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 24) {
                    Spacer().frame(height: 8)

                    // Driver name
                    Text(driverName ?? String(driver.pubkey.prefix(8)) + "...")
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)

                    // QR Code (orange on dark gray)
                    if let qrImage = QRCodeImage.generate(from: deeplink) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Deeplink text
                    Text(shareText)
                        .font(RFFont.mono(11))
                        .foregroundColor(Color.rfOffline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // Action buttons
                    HStack(spacing: 16) {
                        // Copy
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

                        // Share
                        Button {
                            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                  let root = windowScene.keyWindow?.rootViewController else { return }
                            // Find the topmost presented controller
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
