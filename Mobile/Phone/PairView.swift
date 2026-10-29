import SwiftUI
import VisionKit

/// Pairing: scan the code the Mac shows in Settings › Agents › iPhone and iPad, or paste its link.
struct PairView: View {
    let connection: CompanionConnection
    @State private var scanning = false
    @State private var link = ""
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(Palette.accent)
                    Text("Pair with your Mac").font(.title.weight(.semibold)).foregroundStyle(Palette.text)
                    Text("Talk to the agents on your Mac from anywhere. The Mac does the work; this phone listens and speaks.")
                        .foregroundStyle(Palette.text2)
                }
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Install Tailscale on the Mac and this phone, signed in to the same account.")
                    step(2, "On the Mac, open Dante › Settings › Agents and turn on iPhone and iPad.")
                    step(3, "Choose Show Pairing Code… and scan it here.")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))

                if QRScanner.isAvailable {
                    Button { scanning = true } label: {
                        Label("Scan the Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or paste the pairing link").font(.subheadline.weight(.medium)).foregroundStyle(Palette.text2)
                    HStack {
                        TextField("dante-companion://pair?…", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.go)
                            .onSubmit { if !link.isEmpty { pair(link) } }
                        Button("Pair") { pair(link) }.disabled(link.isEmpty)
                    }
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.red).font(.subheadline)
                }
            }
            .padding(20)
        }
        .lookBackground()
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                pair(code)
            }
            .ignoresSafeArea()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(Palette.accent)
                .frame(width: 22, height: 22).background(Circle().fill(Palette.accentTint))
            Text(text).foregroundStyle(Palette.text)
        }
    }

    private func pair(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let pairing = CompanionPairing(url: url) else {
            problem = "That isn’t a Dante pairing code."
            return
        }
        problem = nil
        connection.pair(with: pairing)
    }
}

/// The camera, looking for a QR code (VisionKit's data scanner).
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !done, case .barcode(let code) = item, let payload = code.payloadStringValue,
                      payload.hasPrefix(CompanionPairing.scheme + ":") else { continue }
                done = true
                dataScanner.stopScanning()
                found(payload)
            }
        }
    }
}
