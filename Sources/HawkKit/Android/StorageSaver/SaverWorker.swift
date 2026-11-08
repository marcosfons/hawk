import Foundation

/// Carries out the storage saver for one video (requirements 6.1), every step
/// behind SaverRules and logged with free space before and after. The original is
/// deleted last, and only when the rules allow it.
public enum SaverWorker {
    public enum Mode: String, Sendable, CaseIterable {
        case reencode, archive, both

        public var title: String {
            switch self {
            case .reencode: "Re-encode (smaller copy replaces it)"
            case .archive: "Archive to the Mac, then free it"
            case .both: "Archive, and put a smaller copy back"
            }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var freed: Int64 = 0
        public var note: String
    }

    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile)
    static let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first(where: FileManager.default.isExecutableFile)

    public static var canReencode: Bool { ffmpeg != nil && ffprobe != nil }

    /// The ffmpeg arguments: hardware HEVC, at most `maxLongSide`, metadata (date,
    /// location, orientation) carried over.
    public static func encodeArguments(input: URL, output: URL, video: PhoneVideo, maxLongSide: Int) -> [String] {
        let side = min(video.longSide, maxLongSide)
        let scale = video.width >= video.height ? "scale=\(side):-2" : "scale=-2:\(side)"
        return ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                "-vf", scale, "-c:v", "hevc_videotoolbox", "-b:v", String(SaverEstimate.targetBitrate(longSide: side)), "-tag:v", "hvc1",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart+use_metadata_tags", output.path]
    }

    /// `ffprobe` output "1920,1080\n120.400000" -> the check values.
    public static func parseProbe(_ text: String, size: Int64) -> SaverRules.Check? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return nil }
        let wh = lines[0].split(separator: ",")
        guard wh.count >= 2, let w = Int(wh[0]), let h = Int(wh[1]), let seconds = Double(lines[1]) else { return nil }
        return SaverRules.Check(duration: Int(seconds * 1000), width: w, height: h, size: size)
    }

    public static func run(_ v: PhoneVideo, mode: Mode, maxLongSide: Int, archive: URL?, confirmedLoss: Bool,
                           session: any DeviceSession, deviceName: String, store: DeviceStore?) async -> Outcome {
        func log(_ what: String, _ result: ActionLog.Result) async {
            guard let store else { return }
            try? await ActionLog.append(device: deviceName, action: .change(what), result: result, id: session.id, store: store)
        }
        if case .blocked(let why) = SaverRules.mayTouch(v.path) { return Outcome(note: why) }
        let quoted = ShellQuote.quote(v.path)
        let freeBefore = await freeSpace(session)
        let work = FileManager.default.temporaryDirectory.appending(path: "hawk-saver-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. The original on the Mac: in the archive folder, or a temporary one.
        let local: URL
        if mode != .reencode, let archive {
            local = uniqueFile(in: archive, name: AppActions.localName(package: "video", remote: v.path).replacingOccurrences(of: "video-", with: ""))
        } else {
            local = work.appending(path: "original.mp4")
        }
        do { try await session.pull(v.path, to: local, timeout: .seconds(1800)) } catch {
            await log("Storage saver: pull \(v.name)", .failed((error as? AdbError)?.summary ?? "pull failed"))
            return Outcome(note: "Could not copy it to the Mac")
        }
        let pulled = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard pulled == v.size else { return Outcome(note: "The copy on the Mac does not match: nothing changed") }
        let archivedSize = mode != .reencode ? pulled : nil
        if mode != .reencode { await log("Storage saver: archived \(v.name) to the Mac", .done) }

        // 2. A smaller copy, checked before anything on the phone changes.
        var verified = false
        var newRemote: String?
        if mode != .archive {
            guard let ffmpeg, let ffprobe else { return Outcome(note: "ffmpeg is not installed") }
            let out = work.appending(path: "small.mp4")
            let enc = try? await AdbProcess(executable: "/usr/bin/nice").run(["-n", "15", ffmpeg] + encodeArguments(input: local, output: out, video: v, maxLongSide: maxLongSide),
                                                                              timeout: .seconds(3600))
            let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let probe = try? await AdbProcess(executable: ffprobe).run(["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
                                                                        "-of", "csv=p=0", out.path], timeout: .seconds(60))
            guard enc?.status == 0, let check = probe.flatMap({ parseProbe($0.text, size: size) }),
                  SaverRules.verified(original: v, copy: check, maxLongSide: maxLongSide) else {
                await log("Storage saver: re-encode \(v.name)", .failed("the copy did not pass the check"))
                return Outcome(note: "The smaller copy did not pass the check: the original is untouched")
            }
            verified = true
            let remote = (v.path as NSString).deletingPathExtension + ".hawk.mp4"
            do { try await session.push(out, to: remote, timeout: .seconds(1800)) } catch {
                return Outcome(note: "Could not put the copy on the phone: the original is untouched")
            }
            newRemote = remote
        }

        // 3. The original goes only now, and only if the rules allow.
        if case .blocked(let why) = SaverRules.mayDeleteOriginal(v, archivedSize: archivedSize, userConfirmedLoss: confirmedLoss, copyVerified: verified || mode == .archive) {
            if let newRemote { _ = try? await session.shell("rm -f \(ShellQuote.quote(newRemote))", timeout: .seconds(10)) }
            return Outcome(note: why)
        }
        let script: String
        if let newRemote {
            // Same name and date as the original, so the gallery keeps its place.
            let q = ShellQuote.quote(newRemote)
            script = "touch -r \(quoted) \(q) && rm \(quoted) && mv \(q) \(quoted)"
        } else {
            script = "rm \(quoted)"
        }
        let done = (try? await session.shell(script, timeout: .seconds(30)))?.status == 0
        _ = try? await session.shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ShellQuote.quote("file://" + v.path)) >/dev/null 2>&1",
                                     timeout: .seconds(15))
        let freeAfter = await freeSpace(session)
        let freed = (freeAfter ?? 0) - (freeBefore ?? 0)
        await log("Storage saver: \(mode.rawValue) \(v.name), free \(freeBefore.map { "\($0 >> 20) MB" } ?? "?") to \(freeAfter.map { "\($0 >> 20) MB" } ?? "?")",
                  done ? .done : .failed("the phone refused it"))
        return Outcome(freed: max(freed, 0), note: done ? "Done" : "The phone refused the change")
    }

    /// A name not taken yet: two videos with the same name from different folders
    /// must never overwrite each other's archive.
    public static func uniqueFile(in folder: URL, name: String) -> URL {
        var url = folder.appending(path: name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Bytes free on shared storage (df -k).
    static func freeSpace(_ session: any DeviceSession) async -> Int64? {
        guard let out = try? await session.shell("df -k /storage/emulated/0 | tail -n 1", timeout: .seconds(10)) else { return nil }
        let f = out.stdout.split(separator: " ", omittingEmptySubsequences: true)
        return f.count >= 4 ? Int64(f[3]).map { $0 * 1024 } : nil
    }
}
