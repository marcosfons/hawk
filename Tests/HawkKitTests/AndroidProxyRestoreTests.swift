import Foundation
import HawkKit
import Network
import Testing

@Suite struct AndroidProxyRestoreTests {
    @Test func noneMeansColonZero() {
        #expect(ProxyRestore.normalise(":0\n") == nil && ProxyRestore.normalise("null") == nil && ProxyRestore.normalise("") == nil)
        #expect(ProxyRestore.normalise("proxy.example.net:3128\n") == "proxy.example.net:3128")
    }

    @Test func restoresTheOriginalOnlyIfOursIsStillSet() {
        let none = ProxyRestore(original: nil, set: "127.0.0.1:8899")
        #expect(none.restoreCommand(current: "127.0.0.1:8899\n") == "settings put global http_proxy :0")
        let had = ProxyRestore(original: "proxy.example.net:3128", set: "127.0.0.1:8899")
        #expect(had.restoreCommand(current: "127.0.0.1:8899") == "settings put global http_proxy proxy.example.net:3128")
        // Someone changed it meanwhile: theirs stays.
        #expect(had.restoreCommand(current: "other.example.net:80") == nil)
        #expect(had.restoreCommand(current: ":0") == nil)
    }

    @Test func setCommandOnlyTakesHostPort() {
        #expect(ProxyRestore.setCommand("127.0.0.1:8899") == "settings put global http_proxy 127.0.0.1:8899")
        #expect(ProxyRestore.setCommand("x; reboot:1") == nil)
        #expect(ProxyRestore.setCommand("noport") == nil)
    }

    @Test func leftoverRecordIsRestoredOnConnectAndForgotten() async throws {
        let fake = FakeDeviceSession()
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-proxy-\(UUID().uuidString)"))
        await store.save(ProxyRestore(original: nil, set: "127.0.0.1:8899"), as: ProxyRestore.file, for: fake.id)
        await store.flush()
        fake.answer(shell: ProxyRestore.read, with: "127.0.0.1:8899\n")
        await ProxyRestore.restoreIfNeeded(on: fake, deviceName: "Test", store: store)
        #expect(fake.calls.contains("shell settings put global http_proxy :0"))
        #expect(await store.load(ProxyRestore.self, ProxyRestore.file, for: fake.id) == nil)
        // Nothing left: nothing runs.
        let calls = fake.calls.count
        await ProxyRestore.restoreIfNeeded(on: fake, deviceName: "Test", store: store)
        #expect(fake.calls.count == calls)
    }
}

@Suite struct AndroidCaptureProxyTests {
    @Test func connectAndPlainHeads() throws {
        let connect = try #require(ProxyRequestHead.parse(Data("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\nTLS".utf8)))
        #expect(connect.isTunnel && connect.host == "api.example.com" && connect.port == 443 && connect.path == nil)
        #expect(connect.length == "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n".utf8.count)
        let get = try #require(ProxyRequestHead.parse(Data("GET http://example.com:8080/a?b=1 HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)))
        #expect(!get.isTunnel && get.host == "example.com" && get.port == 8080 && get.path == "/a?b=1")
        let origin = String(decoding: ProxyRequestHead.originForm(Data("GET http://example.com/a HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8), path: "/a"), as: UTF8.self)
        #expect(origin.hasPrefix("GET /a HTTP/1.1\r\nHost: example.com"))
    }

    @Test func incompleteAndHostileHeads() {
        #expect(ProxyRequestHead.parse(Data("CONNECT a.example:443 HTTP/1.1\r\n".utf8)) == nil)
        #expect(ProxyRequestHead.parse(Data("CONNECT a b:443 HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(ProxyRequestHead.parse(Data("GET https://example.com/ HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(ProxyRequestHead.parse(Data("GET /relative HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(ProxyRequestHead.parse(Data("CONNECT evil;rm:443 HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test func proxiesAPlainRequestEndToEnd() async throws {
        // A tiny local server stands in for the internet: nothing leaves the Mac.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: params)
        server.newConnectionHandler = { c in
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                c.send(content: Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        server.start(queue: .global())
        // With port .any the port reads 0 until the listener is ready.
        for _ in 0..<200 where (server.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let serverPort = try #require(server.port?.rawValue)
        defer { server.cancel() }

        let proxy = CaptureProxy()
        let port = try await proxy.start()
        // A raw client: the system sends loopback requests around a configured proxy.
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: .global())
        let request = "GET http://127.0.0.1:\(serverPort)/ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        let reply: String = await withCheckedContinuation { c in
            client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                c.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
            }
        }
        client.cancel()
        #expect(reply.hasPrefix("HTTP/1.1 204"), "reply: \(reply.prefix(120))")
        var seen: [CapturedRequest] = []
        try await Task.sleep(for: .milliseconds(100))
        await proxy.stop()   // flushes what it has
        for await list in proxy.updates {
            seen = list
            break
        }
        #expect(seen.first?.host == "127.0.0.1" && seen.first?.path == "/ping" && seen.first?.status == 204)
        #expect((seen.first?.down ?? 0) > 0)
    }
}
