import Foundation
import Network
import SystemConfiguration
import Darwin

// Tries NAT-PMP (RFC 6886) first — simpler, works on Apple routers.
// Falls back to UPnP IGD — broader router support.
// Renews the mapping at half the lifetime so it never expires.
actor PortForwarder {
    private let port: UInt16
    private var renewTask: Task<Void, Never>?

    init(port: UInt16) { self.port = port }

    func start() async {
        if await tryNATPMP() { return }
        _ = await tryUPnP()
    }

    func stop() { renewTask?.cancel() }

    // MARK: - NAT-PMP (RFC 6886)

    private func tryNATPMP() async -> Bool {
        guard let gw = defaultGateway() else {
            print("[PortForwarder] No default gateway found")
            return false
        }
        guard await natpmpMap(gateway: gw, lifetime: 7200) else { return false }
        // Renew at half the lifetime
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                _ = await self.natpmpMap(gateway: gw, lifetime: 7200)
            }
        }
        return true
    }

    private func natpmpMap(gateway: String, lifetime: UInt32) async -> Bool {
        // Build 12-byte mapping request
        var req = Data(count: 12)
        req[0] = 0; req[1] = 2  // version=0, opcode=2 (map TCP)
        withUnsafeBytes(of: port.bigEndian)     { req.replaceSubrange(4..<6, with: $0) }
        withUnsafeBytes(of: port.bigEndian)     { req.replaceSubrange(6..<8, with: $0) }
        withUnsafeBytes(of: lifetime.bigEndian) { req.replaceSubrange(8..<12, with: $0) }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(gateway), port: 5351)
        let conn = NWConnection(to: endpoint, using: .udp)

        let finalReq = req
        return await withCheckedContinuation { cont in
            var done = false
            let finish = { (ok: Bool) in
                guard !done else { return }; done = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: finalReq, completion: .contentProcessed { _ in
                        conn.receiveMessage { data, _, _, _ in
                            // Response layout: [0]ver [1]op+128 [2-3]result [4-7]epoch
                            //                  [8-9]internal [10-11]external [12-15]lifetime
                            guard let d = data, d.count >= 16,
                                  d[1] == 130, d[2] == 0, d[3] == 0 else { finish(false); return }
                            let ext  = UInt16(d[10]) << 8 | UInt16(d[11])
                            let life = UInt32(d[12]) << 24 | UInt32(d[13]) << 16 | UInt32(d[14]) << 8 | UInt32(d[15])
                            print("[PortForwarder] NAT-PMP: port \(self.port) → external \(ext), lifetime \(life)s")
                            finish(true)
                        }
                    })
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            Task { try? await Task.sleep(for: .seconds(3)); finish(false) }
        }
    }

    // MARK: - UPnP IGD

    private func tryUPnP() async -> Bool {
        guard let location = await ssdpDiscover() else {
            print("[PortForwarder] UPnP: no gateway found via SSDP")
            return false
        }
        guard let controlURL = await fetchControlURL(location: location) else {
            print("[PortForwarder] UPnP: could not find WANIPConnection control URL")
            return false
        }
        guard await soapAddPortMapping(controlURL: controlURL) else { return false }
        print("[PortForwarder] UPnP: port \(port) mapped via \(controlURL.host ?? "?")")
        renewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                _ = await self.soapAddPortMapping(controlURL: controlURL)
            }
        }
        return true
    }

    private func ssdpDiscover() async -> URL? {
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        let endpoint = NWEndpoint.hostPort(host: "239.255.255.250", port: 1900)
        let conn = NWConnection(to: endpoint, using: .udp)

        return await withCheckedContinuation { cont in
            var done = false
            let finish = { (url: URL?) in
                guard !done else { return }; done = true
                conn.cancel(); cont.resume(returning: url)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in
                        conn.receiveMessage { data, _, _, _ in
                            guard let data, let resp = String(data: data, encoding: .utf8) else { finish(nil); return }
                            let location = resp.components(separatedBy: "\r\n")
                                .first { $0.lowercased().hasPrefix("location:") }
                                .flatMap { line -> URL? in
                                    let parts = line.split(separator: ":", maxSplits: 1)
                                    guard parts.count == 2 else { return nil }
                                    return URL(string: String(parts[1]).trimmingCharacters(in: .whitespaces))
                                }
                            finish(location)
                        }
                    })
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            Task { try? await Task.sleep(for: .seconds(4)); finish(nil) }
        }
    }

    private func fetchControlURL(location: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: location),
              let xml = String(data: data, encoding: .utf8) else { return nil }

        for svcType in ["WANIPConnection", "WANPPPConnection"] {
            guard let svcRange = xml.range(of: svcType) else { continue }
            let after = String(xml[svcRange.upperBound...])
            guard let s = after.range(of: "<controlURL>")?.upperBound,
                  let e = after.range(of: "</controlURL>")?.lowerBound,
                  s < e else { continue }
            var urlStr = String(after[s..<e])
            if urlStr.hasPrefix("/") {
                let scheme = location.scheme ?? "http"
                let host   = location.host   ?? ""
                let portPart = location.port.map { ":\($0)" } ?? ""
                urlStr = "\(scheme)://\(host)\(portPart)\(urlStr)"
            }
            return URL(string: urlStr)
        }
        return nil
    }

    private func soapAddPortMapping(controlURL: URL) async -> Bool {
        let p = "\(port)"
        let ip = localIP() ?? "0.0.0.0"
        let soap = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:AddPortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
        <NewRemoteHost></NewRemoteHost>
        <NewExternalPort>\(p)</NewExternalPort>
        <NewProtocol>TCP</NewProtocol>
        <NewInternalPort>\(p)</NewInternalPort>
        <NewInternalClient>\(ip)</NewInternalClient>
        <NewEnabled>1</NewEnabled>
        <NewPortMappingDescription>Canopy</NewPortMappingDescription>
        <NewLeaseDuration>7200</NewLeaseDuration>
        </u:AddPortMapping></s:Body></s:Envelope>
        """
        var req = URLRequest(url: controlURL)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(soap.utf8)
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    // MARK: - System helpers

    private func defaultGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Canopy" as CFString, nil, nil),
              let dict  = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let gw    = dict["Router"] as? String else { return nil }
        return gw
    }

    private func localIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let fa = ptr {
            if fa.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let ip: String = fa.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var sin = $0.pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN))
                    return String(cString: buf)
                }
                if ip != "127.0.0.1" { return ip }
            }
            ptr = fa.pointee.ifa_next
        }
        return nil
    }
}
