import AppKit
import CoreImage.CIFilterBuiltins
import DanteCore
import DanteKit
import SwiftUI

/// Settings › Agents › iPhone and iPad: turns the companion server on, shows the pairing code
/// while it listens, the devices connected now, and unpairs them all with a new key.
struct CompanionSettingsSection: View {
    @Environment(\.theme) private var theme
    private var hub = CompanionHub.shared
    @State private var showsCode = false
    @State private var confirmsUnpair = false

    var body: some View {
        SwiftUI.Section {
            Toggle("Let the companion app connect over Tailscale", isOn: Binding(get: { hub.isOn }, set: { hub.setOn($0) }))
                .help("Dante listens on this Mac’s Tailscale address only, so the phone reaches it on Wi-Fi or cellular without anything in between. A device must scan the pairing code once; it proves it has the key on every connection without sending it.")
            if hub.isOn {
                status
                if hub.pairing != nil, case .listening = hub.state {
                    LabeledContent("Pair a device") {
                        Button("Show Pairing Code…") { showsCode = true }
                    }
                }
                ForEach(hub.devices) { device in
                    LabeledContent(device.name) {
                        Text("Connected \(device.since, style: .relative) ago").foregroundStyle(theme.text3.color)
                    }
                }
            }
        } header: {
            Text("iPhone and iPad")
        }
        .sheet(isPresented: $showsCode) {
            if let pairing = hub.pairing {
                VStack(spacing: 14) {
                    Text("Pair your iPhone or iPad").font(.dante(size: 15, weight: .semibold))
                    QRCode(text: pairing.url.absoluteString)
                        .frame(width: 240, height: 240)
                    Text("Scan this with the Dante app. Anyone with this code can talk to the agents on this Mac, so don’t share or screenshot it.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        .multilineTextAlignment(.center).frame(maxWidth: 300)
                    HStack {
                        Button("Unpair All Devices…") { confirmsUnpair = true }
                        Spacer()
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pairing.url.absoluteString, forType: .string)
                        }
                        .help("For pasting into the app when the camera can’t scan, such as on a Mac or in the simulator. It carries the key, so keep it private.")
                        Button("Done") { showsCode = false }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(22)
                .frame(width: 360)
            }
        }
        .confirmationDialog("Unpair every device?", isPresented: $confirmsUnpair) {
            Button("Unpair All", role: .destructive) { hub.unpairAll() }
        } message: {
            Text("Dante makes a new key. Each device has to scan the new code before it can connect again.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = hub.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
        } else {
            switch hub.state {
            case .listening(let host, let port):
                LabeledContent("Listening") {
                    Text("\(host):\(String(port))").font(.dante(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            case .starting:
                LabeledContent("Starting…") { ProgressView().controlSize(.small) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.red.color)
            case .stopped:
                EmptyView()
            }
        }
    }
}

/// A QR code drawn by Core Image, scaled without smoothing.
private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white))
        }
    }

    private static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
