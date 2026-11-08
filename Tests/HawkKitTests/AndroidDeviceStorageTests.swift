import HawkKit
import Testing

@Suite struct AndroidDeviceStorageTests {
    private let diskstats = """
    Latency: 3ms [512B Data Write]
    Data-Free: 1000K / 4000K total = 25% free
    System-Free: 0K / 700K total = 0% free
    File-based Encryption: true
    App Size: 300
    App Data Size: 200
    App Cache Size: 50
    Photos Size: 1000
    Videos Size: 2000
    Audio Size: 10
    Downloads Size: 0
    System Size: 700
    Other Size: 40
    Package Names: ["com.example.big","com.example.small","com.example.bad;x","android"]
    App Sizes: [100,10,5,1]
    App Data Sizes: [100,0,5,1]
    Cache Sizes: [50,0,5,1]
    """

    private let df = """
    Filesystem       1K-blocks      Used Available Use% Mounted on
    /dev/root          7929884   7929884         0 100% /
    /dev/block/dm-9    4000     3000      1000  75% /data
    /dev/block/dm-9    4000     3000      1000  75% /data/user/0
    /dev/fuse          4000     3000      1000  75% /storage/emulated
    /dev/fuse          64000    1000     63000   2% /storage/ABCD-1234
    """

    @Test func parsesClassesAppsVolumesAndType() {
        let s = DeviceStorage.parse(["diskstats": diskstats, "df": df, "block": "dm-0 loop0 sda sdb zram0 mmcblk0 mmcblk0p1"])
        #expect(s.dataTotal == 4000 * 1024 && s.dataFree == 1000 * 1024)
        #expect(s.classes[.videos] == 2000 && s.classes[.appCache] == 50 && s.classes.count == 9)
        #expect(s.fileBasedEncryption == true)
        #expect(s.apps.map(\.package) == ["com.example.big", "com.example.small", "android"])
        #expect(s.biggest(1).first?.total == 250)
        #expect(s.volumes.map(\.mount) == ["/data", "/storage/ABCD-1234"])
        #expect(s.volumes.map(\.kind) == ["Internal", "SD card or USB drive"])
        #expect(s.storageType == "UFS" && s.hasCardSlotInUse)
    }

    @Test func emmcAndUnknown() {
        #expect(DeviceStorage.parse(["block": "mmcblk0 mmcblk0boot0 mmcblk0rpmb mmcblk0p1"]).storageType == "eMMC")
        #expect(DeviceStorage.parse(["block": "mmcblk0 mmcblk1"]).hasCardSlotInUse)
        #expect(DeviceStorage.parse(["block": "vda vdb"]).storageType == nil)
    }

    @Test func mismatchedArraysUseTheShortest() {
        let text = "Package Names: [\"com.example.a\",\"com.example.b\"]\nApp Sizes: [1]\nApp Data Sizes: [1,2]\nCache Sizes: [1,2]\n"
        #expect(DeviceStorage.parse(["diskstats": text]).apps.count == 1)
    }

    @Test func garbageIsHarmless() {
        let junk = "Package Names: [not json\nApp Sizes: {}\nData-Free: lots\nApp Size: -5\n" + String(repeating: ":::\n", count: 10_000)
        let s = DeviceStorage.parse(["diskstats": junk, "df": junk, "block": junk])
        #expect(s.apps.isEmpty && s.volumes.isEmpty && s.dataTotal == nil && s.classes.isEmpty)
    }
}
