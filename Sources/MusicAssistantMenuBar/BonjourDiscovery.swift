import Foundation
import Darwin

struct DiscoveredEndpoint: Sendable {
    let host: String
    let port: Int
}

@MainActor
final class BonjourDiscovery: NSObject {
    private var browser: NetServiceBrowser?
    private var resolvingService: NetService?
    private var timeoutWorkItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<DiscoveredEndpoint?, Never>?

    func discoverMusicAssistantEndpoint() async -> DiscoveredEndpoint? {
        if let direct = await discover(serviceType: "_music-assistant._tcp.", timeout: 3.5) {
            return direct
        }

        if let homeAssistant = await discover(serviceType: "_home-assistant._tcp.", timeout: 3.5) {
            let friendlyHost = "homeassistant.local"
            let host = preferredHostName(discoveredHost: homeAssistant.host, friendlyHost: friendlyHost)
            return DiscoveredEndpoint(host: host, port: AppConfig.defaultPort)
        }

        return nil
    }

    private func discover(serviceType: String, timeout: TimeInterval) async -> DiscoveredEndpoint? {
        await withCheckedContinuation { continuation in
            stopCurrentSearch()
            self.continuation = continuation

            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: serviceType, inDomain: "local.")

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finish(with: nil)
            }
            self.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        }
    }

    private func finish(with endpoint: DiscoveredEndpoint?) {
        guard let continuation else {
            stopCurrentSearch()
            return
        }

        self.continuation = nil
        stopCurrentSearch()
        continuation.resume(returning: endpoint)
    }

    private func stopCurrentSearch() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        resolvingService?.stop()
        resolvingService?.delegate = nil
        resolvingService = nil

        browser?.stop()
        browser?.delegate = nil
        browser = nil
    }

    private func preferredHostName(discoveredHost: String, friendlyHost: String) -> String {
        if discoveredHost.caseInsensitiveCompare(friendlyHost) == .orderedSame {
            return discoveredHost
        }

        let discoveredIPs = HostResolutionHelper.resolveIPAddresses(host: discoveredHost)
        let friendlyIPs = HostResolutionHelper.resolveIPAddresses(host: friendlyHost)

        guard !friendlyIPs.isEmpty else {
            return discoveredHost
        }

        if discoveredIPs.isEmpty {
            return friendlyHost
        }

        return discoveredIPs.intersection(friendlyIPs).isEmpty ? discoveredHost : friendlyHost
    }
}

extension BonjourDiscovery: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard resolvingService == nil else {
            return
        }

        resolvingService = service
        service.delegate = self
        service.resolve(withTimeout: 2.5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish(with: nil)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if continuation != nil, resolvingService == nil {
            finish(with: nil)
        }
    }
}

extension BonjourDiscovery: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = normalizedHost(from: sender)
        let port = sender.port

        guard let host, !host.isEmpty, port > 0 else {
            finish(with: nil)
            return
        }

        finish(with: DiscoveredEndpoint(host: host, port: port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(with: nil)
    }

    private func normalizedHost(from service: NetService) -> String? {
        if let hostName = service.hostName {
            let trimmed = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}

private enum HostResolutionHelper {
    static func resolveIPAddresses(host: String) -> Set<String> {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let result else {
            return []
        }
        defer { freeaddrinfo(result) }

        var addresses: Set<String> = []
        var current: UnsafeMutablePointer<addrinfo>? = result

        while let info = current {
            if let sockaddr = info.pointee.ai_addr,
               let ip = numericHostString(from: sockaddr)
            {
                addresses.insert(ip)
            }
            current = info.pointee.ai_next
        }

        return addresses
    }

    private static func numericHostString(from address: UnsafePointer<sockaddr>) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        let status = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard status == 0 else {
            return nil
        }

        let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
