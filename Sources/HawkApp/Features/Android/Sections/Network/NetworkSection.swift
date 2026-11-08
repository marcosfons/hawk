//
//  NetworkSection.swift
//  Hawk
//
//  A device's network (requirements 7.3-7.5): configuration (Private DNS, proxy,
//  interfaces, routes, VPN), open connections with the app holding each one, and
//  adb tunnels, which can be kept and are then recreated on reconnect.
//

import AppKit
import HawkKit
import SwiftUI

struct NetworkSection: View {
    let context: SectionContext
    @State private var config: NetworkConfig?
    @State private var connections: [Connection] = []
    @State private var apps: [Int: String] = [:]
    @State private var tunnels: [Tunnel] = []
    @State private var saved: [Tunnel] = []
    @State private var status: String?
    @State private var hotspot: [String]?
    @State private var wifi: [SavedWifi] = []
    @State private var authorities: [String] = []
    @State private var history: UsageHistory?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                      alignment: .leading, spacing: Metrics.spacing) {
                ConfigCard(config: config, hotspot: hotspot)
                DataCard(history: history)
                WifiCard(networks: wifi, live: context.isLive, add: addWifi)
                CertificatesCard(authorities: authorities)
                TunnelsCard(tunnels: tunnels, saved: saved, live: context.isLive, add: add, remove: remove)
            }
            Card(title: "Open connections (\(connections.count))", symbol: "point.3.connected.trianglepath.dotted") {
                DataTable(columns: columns, rows: connections, sortKey: "state", menu: nil, onSelect: nil)
                    .frame(minHeight: 260)
            }
        }
        .task(id: Key(device: context.device.id, live: context.isLive, shown: context.shown)) {
            saved = await SavedTunnels.load(context.device.id, store: context.hub.store)
            history = await context.hub.store?.load(UsageHistory.self, "usage.json", for: context.device.id)
            guard context.isLive, context.shown, let session = try? await context.hub.session(for: context.device.id) else { return }
            if let index = await context.hub.packages(for: context.device.id) {
                var names: [Int: String] = [:]
                for p in index.packages.values { if let uid = p.uid { names[uid] = p.label ?? p.name } }
                apps = names
            }
            var parts = NetworkConfig.parts
            parts["tether"] = Tethering.command
            parts["wifi"] = SavedWifi.command
            parts["ca"] = CAStore.command
            if let out = try? await session.shellBatch(parts, timeout: .seconds(15)) {
                config = NetworkConfig.parse(out)
                hotspot = Tethering.tetheredInterfaces(out["tether"] ?? "")
                wifi = SavedWifi.parse(out["wifi"] ?? "")
                authorities = CAStore.parse(out["ca"] ?? "")
            }
            await loadTunnels(session)
            while !Task.isCancelled {
                if let out = try? await session.shell(Connection.command, timeout: .seconds(10)) {
                    let parsed = Connection.parse(out.stdout)
                    if parsed != connections { connections = parsed }
                }
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            }
        }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool; let shown: Bool }

    private var columns: [Column<Connection>] {
        let apps = apps
        func app(_ c: Connection) -> String { apps[c.uid % 100_000] ?? (c.uid < 10_000 ? "System (\(c.uid))" : "UID \(c.uid)") }
        return [
            Column(id: "app", title: "App", width: 200, flexible: true, numeric: false, text: app, less: { app($0) < app($1) }),
            Column(id: "remote", title: "Remote", width: 200, numeric: false, text: { "\($0.remote):\($0.remotePort)" },
                   less: { $0.remote < $1.remote }),
            Column(id: "local", title: "Local", width: 180, numeric: false, text: { "\($0.local):\($0.localPort)" },
                   color: { _ in .secondaryLabelColor }, less: { $0.localPort < $1.localPort }),
            Column(id: "state", title: "State", width: 100, numeric: false, text: \.state, less: { $0.state < $1.state }),
        ]
    }

    private func loadTunnels(_ session: any DeviceSession) async {
        let serial = await context.hub.preferredSerial(context.device.id)
        let fwd = (try? await session.exec(["forward", "--list"], timeout: .seconds(5)))?.text ?? ""
        let rev = (try? await session.exec(["reverse", "--list"], timeout: .seconds(5)))?.text ?? ""
        tunnels = Tunnel.parse(fwd, direction: .forward, serial: serial) + Tunnel.parse(rev, direction: .reverse, serial: nil)
    }

    private func add(_ t: Tunnel, keep: Bool) {
        Task {
            guard let args = t.addArguments, let session = try? await context.hub.session(for: context.device.id) else {
                status = "Use tcp:<port>, localabstract:<name> or jdwp:<pid> on both sides"
                return
            }
            let out = try? await session.exec(args, timeout: .seconds(10))
            status = out?.status == 0 ? nil : "Could not add the tunnel: \(out?.stderr ?? "")"
            if keep, out?.status == 0 {
                saved = Array(Set(saved + [t]))
                await SavedTunnels.save(saved, context.device.id, store: context.hub.store)
            }
            await loadTunnels(session)
        }
    }

    /// Adds a network on the phone; the passphrase is used for this one command only.
    private func addWifi(_ ssid: String, _ security: String, _ passphrase: String?) {
        Task {
            guard let command = SavedWifi.addCommand(ssid: ssid, security: security, passphrase: passphrase),
                  let session = try? await context.hub.session(for: context.device.id) else {
                status = "Check the name, the security and the password (8 to 63 characters)"
                return
            }
            let out = try? await session.shell(command, timeout: .seconds(15))
            let ok = out?.status == 0 && !(out?.stdout.lowercased().contains("error") ?? true)
            status = ok ? "Added \(ssid) on the phone" : "Could not add \(ssid)"
            if let store = context.hub.store {
                try? await ActionLog.append(device: context.device.name, action: .change("Wi-Fi network added: \(ssid)"),
                                            result: ok ? .done : .failed("cmd wifi refused it"), id: context.device.id, store: store)
            }
            if let list = try? await session.shell(SavedWifi.command, timeout: .seconds(10)) { wifi = SavedWifi.parse(list.stdout) }
        }
    }

    private func remove(_ t: Tunnel) {
        Task {
            guard let session = try? await context.hub.session(for: context.device.id) else { return }
            _ = try? await session.exec(t.removeArguments, timeout: .seconds(10))
            saved.removeAll { $0 == t }
            await SavedTunnels.save(saved, context.device.id, store: context.hub.store)
            await loadTunnels(session)
        }
    }
}

private struct ConfigCard: View {
    let config: NetworkConfig?
    let hotspot: [String]?

    var body: some View {
        Card(title: "Configuration", symbol: "gearshape.2") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Private DNS", config?.privateDNS)
                row("Proxy", config.map { $0.proxy ?? "None" })
                row("VPN", config.map { $0.vpn ? "Connected" : "None" })
                row("Hotspot", hotspot.map { $0.isEmpty ? "Off" : "On (\($0.joined(separator: ", ")))" })
                ForEach(config?.interfaces ?? [], id: \.name) { i in row(i.name, i.addresses.joined(separator: ", ")) }
            }
            if let routes = config?.routes, !routes.isEmpty {
                DisclosureGroup("Routes (\(routes.count))") {
                    Text(routes.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Typography.small)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
            Text(value ?? "-").font(Typography.small).textSelection(.enabled)
        }
    }
}

private struct TunnelsCard: View {
    let tunnels: [Tunnel]
    let saved: [Tunnel]
    let live: Bool
    let add: (Tunnel, Bool) -> Void
    let remove: (Tunnel) -> Void
    @State private var direction: Tunnel.Direction = .reverse
    @State private var local = "tcp:8080"
    @State private var remote = "tcp:8080"
    @State private var keep = true

    var body: some View {
        Card(title: "Tunnels", symbol: "arrow.left.arrow.right") {
            ForEach(tunnels) { t in
                HStack {
                    Text(t.direction == .forward ? "Mac \(t.local) to device \(t.remote)" : "Device \(t.local) to Mac \(t.remote)")
                        .font(.system(size: 11, design: .monospaced))
                    if saved.contains(t) { Text("kept").font(Typography.caption).foregroundStyle(Palette.accent) }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { remove(t) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        .accessibilityLabel("Remove tunnel")
                }
            }
            if tunnels.isEmpty { Text("No tunnels.").font(Typography.small).foregroundStyle(Palette.secondary) }
            HStack {
                Picker("", selection: $direction) {
                    Text("Reverse").tag(Tunnel.Direction.reverse)
                    Text("Forward").tag(Tunnel.Direction.forward)
                }
                .labelsHidden().fixedSize()
                TextField("tcp:8080", text: $local).frame(width: 110)
                TextField("tcp:8080", text: $remote).frame(width: 110)
                Toggle("Keep", isOn: $keep)
                Button("Add") { add(Tunnel(direction: direction, local: local, remote: remote), keep) }.disabled(!live)
            }
            .textFieldStyle(.roundedBorder).controlSize(.small)
            Text("Kept tunnels are recreated when the device comes back.").font(Typography.caption).foregroundStyle(Palette.tertiary)
        }
    }
}

private struct DataCard: View {
    let history: UsageHistory?

    var body: some View {
        Card(title: "Data used", symbol: "arrow.up.arrow.down") {
            if let history, !history.days.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("").gridColumnAlignment(.trailing)
                        Text("Wi-Fi"); Text("Mobile"); Text("Hotspot")
                    }
                    .font(Typography.caption).foregroundStyle(Palette.tertiary)
                    ForEach([(1, "Today"), (7, "7 days"), (30, "30 days")], id: \.0) { days, label in
                        let t = DeviceDataTotals.totals(history, days: days)
                        GridRow {
                            Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary)
                            Text(Format.bytes(Double(t.wifi))); Text(Format.bytes(Double(t.mobile))); Text(Format.bytes(Double(t.hotspot)))
                        }
                        .font(Typography.small)
                    }
                }
            } else {
                Text("Open Usage per app once to read the history.").font(Typography.small).foregroundStyle(Palette.secondary)
            }
        }
    }
}

private struct WifiCard: View {
    let networks: [SavedWifi]
    let live: Bool
    let add: (String, String, String?) -> Void
    @State private var macNetworks: [String] = []
    @State private var ssid = ""
    @State private var security = "wpa2"
    @State private var password = ""

    var body: some View {
        Card(title: "Wi-Fi networks on the phone", symbol: "wifi") {
            ForEach(networks) { n in
                HStack {
                    Text(n.ssid).font(Typography.small)
                    Spacer()
                    Text(n.security).font(Typography.caption).foregroundStyle(Palette.secondary)
                }
            }
            if networks.isEmpty { Text("None listed.").font(Typography.small).foregroundStyle(Palette.secondary) }
            Divider()
            HStack {
                Menu("From this Mac") {
                    ForEach(macNetworks, id: \.self) { name in
                        Button(name) {
                            Task {
                                // macOS asks before giving the password; it is used once and forgotten.
                                let pass = await MacWifi.password(for: name)
                                add(name, pass == nil ? "open" : "wpa2", pass)
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(!live || macNetworks.isEmpty)
                TextField("Network name", text: $ssid).frame(width: 140)
                Picker("", selection: $security) {
                    ForEach(["wpa2", "wpa3", "open"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                SecureField("Password", text: $password).frame(width: 120)
                Button("Add") {
                    add(ssid, security, security == "open" ? nil : password)
                    password = ""
                }
                .disabled(!live || ssid.isEmpty)
            }
            .textFieldStyle(.roundedBorder).controlSize(.small)
        }
        .task { macNetworks = await MacWifi.savedNetworks() }
    }
}

private struct CertificatesCard: View {
    let authorities: [String]

    var body: some View {
        Card(title: "Trusted certificates", symbol: "checkmark.shield") {
            Text("\(authorities.count) system authorities. Certificates a user added are readable only with root.")
                .font(Typography.small).foregroundStyle(Palette.secondary)
            if !authorities.isEmpty {
                DisclosureGroup("List") {
                    Text(authorities.joined(separator: "\n")).font(.system(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Typography.small)
            }
        }
    }
}
