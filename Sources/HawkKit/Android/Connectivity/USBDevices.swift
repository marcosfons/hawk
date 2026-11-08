import Foundation
import IOKit

/// A USB device as the Mac sees it, whether or not adb does (requirements 1.5).
public struct USBDevice: Sendable, Equatable {
    public struct Interface: Sendable, Equatable {
        public let classCode: Int
        public let subclass: Int
        public let proto: Int
        public init(classCode: Int, subclass: Int, proto: Int) {
            self.classCode = classCode
            self.subclass = subclass
            self.proto = proto
        }
    }

    public let vendorID: Int
    public let productID: Int
    public let name: String
    public let serial: String?
    /// IOKit's "Device Speed": 0 low, 1 full, 2 high (USB 2), 3 super (5 Gb/s), 4 super+ (10 Gb/s), 5 (20 Gb/s).
    public let speed: Int?
    public let interfaces: [Interface]

    public init(vendorID: Int, productID: Int, name: String, serial: String?, speed: Int?, interfaces: [Interface]) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.serial = serial
        self.speed = speed
        self.interfaces = interfaces
    }

    /// Phone makers' USB vendor IDs (Google, Samsung, Xiaomi, OnePlus, Motorola, Huawei,
    /// Sony, LG, HTC, Oppo, Vivo, Nothing, Asus, Lenovo, ZTE, Realme).
    static let androidVendors: Set<Int> = [0x18D1, 0x04E8, 0x2717, 0x2A70, 0x22B8, 0x12D1, 0x0FCE, 0x1004, 0x0BB4, 0x22D9,
                                          0x2D95, 0x2B0E, 0x0B05, 0x17EF, 0x19D2, 0x2A45]

    /// The adb interface: vendor class 0xFF, subclass 0x42, protocol 1.
    public var hasADB: Bool { interfaces.contains { $0.classCode == 0xFF && $0.subclass == 0x42 && $0.proto == 1 } }
    /// MTP or PTP (still image class): file transfer or photo mode.
    public var hasMTP: Bool { interfaces.contains { $0.classCode == 6 } }
    public var looksAndroid: Bool { hasADB || Self.androidVendors.contains(vendorID) || name.localizedCaseInsensitiveContains("android") }

    public var speedLabel: String? {
        switch speed {
        case 0: "USB 1 low speed (1.5 Mb/s)"
        case 1: "USB 1 (12 Mb/s)"
        case 2: "USB 2 (480 Mb/s)"
        case 3: "USB 3 (5 Gb/s)"
        case 4: "USB 3 (10 Gb/s)"
        case 5: "USB 3 (20 Gb/s)"
        default: nil
        }
    }

    /// Every USB device now, from IOKit (no permission needed). Cheap: read while the
    /// doctor is shown and when a USB device comes or goes, never polled.
    public static func current() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [USBDevice] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let p = properties(device)
            guard let vendor = p["idVendor"] as? Int, let product = p["idProduct"] as? Int else { continue }
            out.append(USBDevice(vendorID: vendor, productID: product,
                                 name: (p["USB Product Name"] as? String) ?? (p["kUSBProductString"] as? String) ?? "USB device",
                                 serial: (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String),
                                 speed: p["Device Speed"] as? Int, interfaces: interfaces(of: device)))
            if out.count >= 128 { break }
        }
        return out
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = dict?.takeRetainedValue() as? [String: Any] else { return [:] }
        return d
    }

    private static func interfaces(of device: io_registry_entry_t) -> [Interface] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [Interface] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 else { continue }
            let p = properties(entry)
            if let c = p["bInterfaceClass"] as? Int {
                out.append(Interface(classCode: c, subclass: p["bInterfaceSubClass"] as? Int ?? 0, proto: p["bInterfaceProtocol"] as? Int ?? 0))
            }
            if out.count >= 32 { break }
        }
        return out
    }
}
