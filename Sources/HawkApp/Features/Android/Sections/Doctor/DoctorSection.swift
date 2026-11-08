//
//  DoctorSection.swift
//  Hawk
//
//  Connection doctor (requirements 1.5-1.7): what the Mac sees on USB matched
//  against adb, as causes with what to do; pairing over Wi-Fi by QR code; and a
//  real throughput test. USB is read when the page opens, on Refresh and when
//  devices change: never polled.
//

import AppKit
import CoreImage.CIFilterBuiltins
import HawkKit
import SwiftUI

struct DoctorSection: View {
    let context: SectionContext
    @State private var findings: [ConnectionDoctor.Finding] = []
    @State private var speed: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Card(title: "Diagnosis", symbol: "stethoscope") {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await diagnose() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Diagnose again")
            } content: {
                ForEach(findings) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: f.severity >= .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(f.severity == .problem ? Palette.hot : f.severity == .warning ? Palette.warn : Palette.good)
                            .accessibilityLabel(f.severity >= .warning ? "Problem" : "Fine")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(Typography.label)
                            Text(f.detail).font(Typography.small).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            PairingCard(context: context)
            Card(title: "Connection speed", symbol: "speedometer") {
                HStack {
                    Button("Test speed") { Task { await test() } }.disabled(!context.isLive || testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(speed ?? "Pushes and pulls a 32 MB temporary file, then deletes it.").font(Typography.small).foregroundStyle(Palette.secondary)
                }
                .controlSize(.small)
            }
        }
        .task(id: Key(device: context.device.id, state: context.device.state?.word, transports: context.device.transports.count)) { await diagnose() }
    }

    private struct Key: Equatable { let device: DeviceID; let state: String?; let transports: Int }

    private func diagnose() async {
        let usb = await Task.detached(priority: .utility) { USBDevice.current() }.value
        let status = await context.hub.server.currentStatus()
        let running: Bool = if case .running = status.state { true } else { false }
        findings = ConnectionDoctor.diagnose(usb: usb, adb: await context.hub.devices(), installation: status.installation, serverRunning: running)
    }

    private func test() async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        testing = true
        defer { testing = false }
        do {
            let r = try await Throughput.measure(on: session)
            speed = "Push \(Format.rate(r.push)), pull \(Format.rate(r.pull)) over \(context.device.preferred?.kind.label ?? "adb")"
        } catch {
            speed = "Test failed: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }
}

/// Wireless debugging - Pair device with QR code, on the phone (Android 11+).
private struct PairingCard: View {
    let context: SectionContext
    @State private var pairing: WirelessPairing?
    @State private var status: String?

    var body: some View {
        Card(title: "Pair over Wi-Fi", symbol: "qrcode") {
            HStack(alignment: .top, spacing: 16) {
                if let pairing, let image = Self.qr(pairing.qrPayload) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                        .accessibilityLabel("Pairing QR code")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("On the phone: Developer options - Wireless debugging - Pair device with QR code, then scan this. The phone and this Mac must be on the same Wi-Fi.")
                        .font(Typography.small).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    if let pairing { Text("Or pair with code \(pairing.code)").font(Typography.small) }
                    Button(pairing == nil ? "Show QR code" : "New QR code") { start() }.controlSize(.small)
                    if let status { Text(status).font(Typography.small) }
                }
            }
        }
        .task(id: pairing?.name) { await waitAndPair() }
    }

    private func start() {
        pairing = WirelessPairing()
        status = "Waiting for the phone to scan it"
    }

    /// Looks for the phone's pairing service every 2 s for two minutes, then pairs.
    private func waitAndPair() async {
        guard let pairing, let adb = await context.hub.server.process() else { return }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let out = try? await adb.run(["mdns", "services"], timeout: .seconds(5)),
                  let service = pairing.service(in: MdnsService.parse(out.text)) else { continue }
            let result = try? await adb.run(pairing.pairArguments(service), timeout: .seconds(15))
            status = result?.text.contains("Successfully paired") == true
                ? "Paired. The phone connects over Wi-Fi when it appears on the network."
                : "Pairing failed: \(result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no answer")"
            return
        }
        status = "No phone scanned it in two minutes."
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
