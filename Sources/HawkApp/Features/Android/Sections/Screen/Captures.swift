//
//  Captures.swift
//  Hawk
//
//  Screenshots and recordings on the Mac: a folder the user picks (Pictures/Hawk
//  Captures by default), the recent ones listed, and ffmpeg presets run in the
//  background at low priority, keeping the original.
//

import AppKit
import HawkKit
import Observation

@Observable
final class CapturesModel {
    private(set) var files: [URL] = []
    private(set) var status: String?
    private(set) var busy = false

    @ObservationIgnored private let defaults = UserDefaults.standard

    var folder: URL {
        get {
            defaults.string(forKey: "androidCaptures").map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? URL.picturesDirectory.appending(path: "Hawk Captures", directoryHint: .isDirectory)
        }
        set { defaults.set(newValue.path, forKey: "androidCaptures"); reload() }
    }

    func reload() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        files = items.filter { ["png", "mp4", "gif", "webp", "mkv"].contains($0.pathExtension.lowercased()) }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        if files.count > 24 { files = Array(files.prefix(24)) }
    }

    /// "<device>-2026-11-08-101530.png", plain characters only.
    func newFile(device: String, extension ext: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = String(device.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(40))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(name)-\(f.string(from: Date())).\(ext)")
    }

    /// `adb exec-out screencap -p` straight into a file (nothing left on the phone),
    /// and onto the clipboard.
    func screenshot(session: any DeviceSession, device: String) async {
        busy = true
        defer { busy = false }
        do {
            let out = try await session.exec(["exec-out", "screencap", "-p"], timeout: .seconds(20))
            guard out.status == 0, out.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                status = "Screenshot failed: \(out.error?.summary ?? "not a PNG")"
                return
            }
            let url = newFile(device: device, extension: "png")
            try out.stdout.write(to: url, options: .atomic)
            NSPasteboard.general.clearContents()
            if let image = NSImage(data: out.stdout) { NSPasteboard.general.writeObjects([image]) }
            status = "Saved \(url.lastPathComponent) and copied it"
            reload()
        } catch {
            status = "Screenshot failed: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }

    func delete(_ url: URL) {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
            status = "Could not move \(url.lastPathComponent) to the Trash"
        }
        reload()
    }

    /// ffmpeg at low priority; the original stays.
    func optimize(_ url: URL, preset: FFmpegPreset) async {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile) else {
            status = "ffmpeg is not installed (brew install ffmpeg)"
            return
        }
        busy = true
        defer { busy = false }
        let output = url.deletingPathExtension().appendingPathExtension("\(preset.rawValue).\(preset.fileExtension)")
        status = "Optimizing \(url.lastPathComponent)"
        var runner = AdbProcess(executable: "/usr/bin/nice")
        runner.slowAbove = .seconds(600)
        do {
            let out = try await runner.run(["-n", "15", ffmpeg] + preset.arguments(input: url, output: output), timeout: .seconds(1800))
            if out.status == 0, let before = size(url), let after = size(output) {
                status = "\(output.lastPathComponent): \(Format.bytes(Double(before))) to \(Format.bytes(Double(after)))"
            } else {
                status = "ffmpeg failed: \(out.stderr.split(separator: "\n").last.map(String.init) ?? "status \(out.status)")"
            }
        } catch {
            status = "ffmpeg stopped: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
        reload()
    }

    private func size(_ url: URL) -> Int? { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
}
