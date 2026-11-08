import Foundation
import HawkKit
import Testing

private let video = PhoneVideo(id: 1, path: "/storage/emulated/0/DCIM/Camera/clip, one.mp4", size: 1_000_000_000,
                               width: 3840, height: 2160, duration: 120_000, bitrate: 60_000_000, added: nil)

@Suite struct AndroidStorageSaverTests {
    @Test func parsesTheMediaStore() {
        let rows = PhoneVideo.parse("""
        Row: 0 _id=10, _data=/storage/emulated/0/DCIM/Camera/clip, one.mp4, _size=1000, width=1920, height=1080, duration=5000, bitrate=8000000, date_added=1800000000
        Row: 1 _id=11, _data=relative/bad.mp4, _size=10, width=1, height=1, duration=1, bitrate=NULL, date_added=1
        noise
        """)
        #expect(rows.count == 1)
        #expect(rows[0].path == "/storage/emulated/0/DCIM/Camera/clip, one.mp4" && rows[0].size == 1000 && rows[0].longSide == 1920)
        #expect(rows[0].added == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func estimateNeverExceedsTheOriginal() {
        let e = SaverEstimate.estimate(video, maxLongSide: 1920)
        #expect(e == Int64(Double(6_000_000 + 128_000) * 120 / 8))
        #expect(SaverEstimate.saving([video], maxLongSide: 1920) == video.size - e)
        let small = PhoneVideo(id: 2, path: "/sdcard/a.mp4", size: 1000, width: 640, height: 360, duration: 60_000, bitrate: nil, added: nil)
        #expect(SaverEstimate.estimate(small, maxLongSide: 1920) == 1000)
    }

    @Test func whatsappAndOddPathsAreNeverTouched() {
        #expect(!SaverRules.mayTouch("/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/v.mp4").isAllowed)
        #expect(!SaverRules.mayTouch("/storage/emulated/0/WhatsApp/Media/v.mp4").isAllowed)
        #expect(!SaverRules.mayTouch("/data/media/0/v.mp4").isAllowed)
        #expect(!SaverRules.mayTouch("/storage/emulated/0/../0/v.mp4").isAllowed)
        #expect(SaverRules.mayTouch(video.path).isAllowed)
    }

    @Test func theCopyMustMatchBeforeAnythingHappens() {
        let good = SaverRules.Check(duration: 120_400, width: 1920, height: 1080, size: 90_000_000)
        #expect(SaverRules.verified(original: video, copy: good, maxLongSide: 1920))
        #expect(!SaverRules.verified(original: video, copy: .init(duration: 100_000, width: 1920, height: 1080, size: 1), maxLongSide: 1920))
        #expect(!SaverRules.verified(original: video, copy: .init(duration: 120_000, width: 1080, height: 1080, size: 1), maxLongSide: 1920))
        #expect(!SaverRules.verified(original: video, copy: .init(duration: 120_000, width: 1920, height: 1080, size: video.size), maxLongSide: 1920))
        #expect(!SaverRules.verified(original: video, copy: .init(duration: 120_000, width: 1920, height: 1080, size: 0), maxLongSide: 1920))
    }

    @Test func originalsGoOnlyWhenArchivedOrConfirmed() {
        #expect(SaverRules.mayDeleteOriginal(video, archivedSize: video.size, userConfirmedLoss: false, copyVerified: true).isAllowed)
        #expect(!SaverRules.mayDeleteOriginal(video, archivedSize: nil, userConfirmedLoss: false, copyVerified: true).isAllowed)
        #expect(!SaverRules.mayDeleteOriginal(video, archivedSize: video.size - 1, userConfirmedLoss: false, copyVerified: true).isAllowed)
        #expect(SaverRules.mayDeleteOriginal(video, archivedSize: nil, userConfirmedLoss: true, copyVerified: true).isAllowed)
        #expect(!SaverRules.mayDeleteOriginal(video, archivedSize: video.size, userConfirmedLoss: false, copyVerified: false).isAllowed)
        // Archive only (no copy): allowed once archived.
        #expect(SaverRules.mayDeleteOriginal(video, archivedSize: video.size, userConfirmedLoss: true, copyVerified: false).isAllowed)
    }
}

@Suite struct AndroidSaverWorkerTests {
    @Test func encodeKeepsMetadataAndScales() {
        let a = SaverWorker.encodeArguments(input: URL(filePath: "/tmp/in.mp4"), output: URL(filePath: "/tmp/out.mp4"), video: video, maxLongSide: 1920)
        #expect(a.contains("hevc_videotoolbox") && a.contains("-map_metadata") && a.contains("scale=1920:-2") && a.last == "/tmp/out.mp4")
        let portrait = PhoneVideo(id: 3, path: "/sdcard/p.mp4", size: 10, width: 1080, height: 2340, duration: 1000, bitrate: nil, added: nil)
        #expect(SaverWorker.encodeArguments(input: URL(filePath: "/a"), output: URL(filePath: "/b"), video: portrait, maxLongSide: 1920).contains("scale=-2:1920"))
    }

    @Test func probeOutput() {
        #expect(SaverWorker.parseProbe("1920,1080\n120.400000\n", size: 5) == SaverRules.Check(duration: 120_400, width: 1920, height: 1080, size: 5))
        #expect(SaverWorker.parseProbe("garbage", size: 5) == nil)
    }

    @Test func whatsappIsRefusedBeforeAnything() async {
        let fake = FakeDeviceSession()
        let wa = PhoneVideo(id: 9, path: "/storage/emulated/0/WhatsApp/Media/v.mp4", size: 10, width: 1, height: 1, duration: 1, bitrate: nil, added: nil)
        let out = await SaverWorker.run(wa, mode: .archive, maxLongSide: 1920, archive: nil, confirmedLoss: true, session: fake, deviceName: "T", store: nil)
        #expect(out.note == "WhatsApp media is never touched")
        #expect(fake.calls.isEmpty)
    }

    @Test func aMismatchedPullChangesNothing() async {
        let fake = FakeDeviceSession()   // its pull writes nothing, so sizes differ
        let out = await SaverWorker.run(video, mode: .archive, maxLongSide: 1920, archive: FileManager.default.temporaryDirectory,
                                        confirmedLoss: true, session: fake, deviceName: "T", store: nil)
        #expect(out.note == "The copy on the Mac does not match: nothing changed")
        #expect(!fake.calls.contains { $0.contains("rm ") })
    }

    @Test func archiveNamesNeverCollide() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hawk-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "clip.mp4"))
        try Data().write(to: dir.appending(path: "clip-2.mp4"))
        #expect(SaverWorker.uniqueFile(in: dir, name: "clip.mp4").lastPathComponent == "clip-3.mp4")
        #expect(SaverWorker.uniqueFile(in: dir, name: "other.mp4").lastPathComponent == "other.mp4")
    }
}
