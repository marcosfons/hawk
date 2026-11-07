import HawkKit
import Foundation
import Testing

@Suite struct HelperProtocolTests {
    @Test(arguments: [HelperRequest.hello, .auto, .set(rpm: 4200)])
    func requestsRoundTripAsOneLine(_ request: HelperRequest) throws {
        let line = try #require(Helper.encodeLine(request))
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try JSONDecoder().decode(HelperRequest.self, from: line.dropLast()) == request)
    }

    @Test func responsesRoundTrip() throws {
        let r = HelperResponse(ok: false, manual: false, message: "Too hot")
        let line = try #require(Helper.encodeLine(r))
        #expect(try JSONDecoder().decode(HelperResponse.self, from: line.dropLast()) == r)
    }

    @Test func socketPathFitsInSockaddr() {
        var addr = Helper.address(Helper.socketPath)
        let stored = withUnsafeBytes(of: &addr.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #expect(stored == Helper.socketPath)
    }
}

@Suite struct FormatTests {
    @Test func bytesUseDecimalUnits() {
        #expect(Format.bytes(512) == "512 B")
        #expect(Format.bytes(1_500) == "1.5 KB")
        #expect(Format.bytes(44_000_000) == "44 MB")
    }

    @Test func memoryUsesBinaryGigabytes() {
        #expect(Format.memory(25_769_803_776) == "24.0 GB")
    }

    @Test func minutesShowHoursAndMinutes() {
        #expect(Format.minutes(130) == "2:10")
        #expect(Format.minutes(nil) == "-")
    }
}
