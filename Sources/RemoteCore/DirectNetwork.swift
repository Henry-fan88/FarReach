import Foundation
import Darwin
import SystemConfiguration
import dnssd

public enum DirectAddressScope: String, Equatable, Sendable {
    case global, privateNetwork, sharedCarrierNAT, loopback, linkLocal, reserved, invalid
}

public struct DirectNetworkAddress: Equatable, Sendable {
    public let interfaceName: String
    public let address: String
    public let family: Int
    public let scope: DirectAddressScope
    /// An address candidate, not proof that a firewall admits incoming traffic.
    public var isInternetRoutable: Bool { scope == .global }
}

/// Local interface inventory only. No request is sent to an external service.
public enum DirectNetworkSnapshot {
    public static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "FarReach network inspection" as CFString, nil, nil) else { return nil }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        return (ipv4?[kSCDynamicStorePropNetPrimaryInterface as String] as? String)
            ?? (ipv6?[kSCDynamicStorePropNetPrimaryInterface as String] as? String)
    }

    /// Includes usable LAN/public IPv4 and global-unicast IPv6. Loopback,
    /// link-local, ULA IPv6, documentation, benchmarking and reserved ranges are
    /// deliberately excluded from connection suggestions.
    public static func localAddresses() -> [DirectNetworkAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var values: [DirectNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: buffer)
            let scope = classify(value)
            let version = family == AF_INET ? 4 : 6
            guard scope == .global || (version == 4 && (scope == .privateNetwork || scope == .sharedCarrierNAT)) else { continue }
            let item = DirectNetworkAddress(interfaceName: String(cString: entry.pointee.ifa_name), address: value, family: version, scope: scope)
            if !values.contains(item) { values.append(item) }
        }
        let primary = primaryInterfaceName()
        return values.sorted {
            if ($0.interfaceName == primary) != ($1.interfaceName == primary) { return $0.interfaceName == primary }
            if $0.isInternetRoutable != $1.isInternetRoutable { return $0.isInternetRoutable }
            if $0.family != $1.family { return $0.family > $1.family }
            return ($0.interfaceName, $0.address) < ($1.interfaceName, $1.address)
        }
    }

    /// Conservative classification for choosing a directly reachable endpoint.
    /// An address marked global can still be filtered or unreachable in practice.
    public static func classify(_ text: String) -> DirectAddressScope {
        guard !text.isEmpty, !text.contains("%"), !text.contains("[") else { return .invalid }
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            func matches(_ network: UInt32, _ bits: UInt32) -> Bool {
                let mask = UInt32.max << (32 - bits)
                return value & mask == network & mask
            }
            if matches(0x7f000000, 8) { return .loopback }
            if matches(0xa9fe0000, 16) { return .linkLocal }
            if matches(0x0a000000, 8) || matches(0xac100000, 12) || matches(0xc0a80000, 16) { return .privateNetwork }
            if matches(0x64400000, 10) { return .sharedCarrierNAT }
            let reserved: [(UInt32, UInt32)] = [
                (0x00000000, 8), (0xc0000000, 24), (0xc0000200, 24),
                (0xc0586300, 24), (0xc6120000, 15), (0xc6336400, 24),
                (0xcb007100, 24), (0xe0000000, 4), (0xf0000000, 4)
            ]
            return reserved.contains(where: { matches($0.0, $0.1) }) ? .reserved : .global
        }
        var v6 = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return .invalid }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
        if bytes[0] & 0xfe == 0xfc { return .privateNetwork }
        // Only global-unicast 2000::/3 is suggested. IPv4-mapped, unspecified,
        // multicast, NAT64 and other special-purpose prefixes are not endpoints.
        guard bytes[0] & 0xe0 == 0x20 else { return .reserved }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            // 2001::/23 contains protocol assignments rather than ordinary host
            // address space. Conservatively exclude the whole block, and docs.
            if bytes[2] <= 1 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return .reserved }
        }
        // Deprecated 6to4 and the second IPv6 documentation prefix.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return .reserved }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return .reserved }
        return .global
    }
}

public enum RouterMappingState: String, Equatable, Sendable {
    case externalAddress, mapped, unavailable, doubleNAT, timedOut, stopped
}

public struct RouterMappingResult: Equatable, Sendable {
    public let state: RouterMappingState
    public let externalAddress: String?
    public let internalPort: UInt16?
    public let externalPort: UInt16?
    public let errorCode: Int32?
    public let lifetime: UInt32
    public let readOnly: Bool
    /// This confirms a reported public mapping, never external reachability.
    public var isPublicEndpointCandidate: Bool {
        state == .mapped && !readOnly && externalPort != nil && externalPort != 0
            && externalAddress.map { DirectNetworkSnapshot.classify($0) == .global } == true
    }
    public var message: String {
        switch state {
        case .externalAddress:
            return "The router reported a public IPv4 address. No port was opened."
        case .mapped:
            return "The router reported a TCP mapping. Verify it from another network before relying on it."
        case .doubleNAT:
            return "The router reports another NAT upstream. A mapping on this router alone may not make this Mac reachable."
        case .timedOut:
            return readOnly ? "The router did not report a usable external address. Automatic discovery may be unsupported or blocked." : "The router did not confirm a mapping before the timeout. No active mapping request is being retained."
        case .stopped:
            return readOnly ? "Router inspection stopped." : "The automatic mapping request has been released. The router may take time to remove its lease."
        case .unavailable:
            if let address = externalAddress, DirectNetworkSnapshot.classify(address) != .global {
                return "The router reported an address that is not public. Direct internet reachability is not established."
            }
            if let errorCode, errorCode == Int32(kDNSServiceErr_NATPortMappingUnsupported) || errorCode == Int32(kDNSServiceErr_Unsupported) {
                return "This network does not report support for automatic router mapping. Configure your own router manually if available."
            }
            return "The router could not provide a usable public TCP endpoint\(errorCode.map { " (error \($0))" } ?? "")."
        }
    }

    /// Pure reply evaluation shared by production callbacks and tests. A nil
    /// result is provisional: mDNSResponder can first report 0.0.0.0 while it is
    /// still discovering the gateway. The caller must keep its deadline active.
    static func evaluate(readOnly: Bool, errorCode: Int32, externalAddress: String?, protocolValue: UInt32,
                         internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> RouterMappingResult? {
        let definedFields = errorCode == kDNSServiceErr_NoError || errorCode == kDNSServiceErr_DoubleNAT
        let address = definedFields ? externalAddress : nil
        let internalValue = definedFields && !readOnly && internalPort > 0 ? internalPort : nil
        let externalValue = definedFields && !readOnly && externalPort > 0 ? externalPort : nil
        if errorCode == kDNSServiceErr_NoError && (address == nil || address == "0.0.0.0") { return nil }
        let state: RouterMappingState
        if errorCode == kDNSServiceErr_DoubleNAT { state = .doubleNAT }
        else if errorCode != kDNSServiceErr_NoError { state = .unavailable }
        else if address.map({ DirectNetworkSnapshot.classify($0) }) != .global { state = .unavailable }
        else if readOnly { state = .externalAddress }
        else if externalPort == 0 || internalPort == 0 || protocolValue & UInt32(kDNSServiceProtocol_TCP) == 0 { state = .unavailable }
        else { state = .mapped }
        return RouterMappingResult(state: state, externalAddress: address, internalPort: internalValue,
                                   externalPort: externalValue, errorCode: errorCode == 0 ? nil : errorCode,
                                   lifetime: definedFields ? lifetime : 0, readOnly: readOnly)
    }
}

/// macOS's gateway mapping API uses PCP, NAT-PMP or UPnP/IGD when supported.
/// inspect() is read-only. Only start() requests an incoming TCP mapping.
/// Keep this object alive while sharing, and call stop() when sharing ends.
public final class RouterMapping {
    public var onChange: ((RouterMappingResult) -> Void)?
    private let queue = DispatchQueue(label: "FarReach.router-mapping")
    private let callbackQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var reference: DNSServiceRef?
    private var context: UnsafeMutableRawPointer?
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private var readOnly = true
    private var confirmedMapping = false

    private final class CallbackContext {
        weak var owner: RouterMapping?
        let generation: UUID
        init(owner: RouterMapping, generation: UUID) { self.owner = owner; self.generation = generation }
    }

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        queue.setSpecific(key: queueKey, value: 1)
    }

    public func inspect(timeout: TimeInterval = 12) { begin(readOnly: true, internalPort: 0, externalPort: 0, timeout: timeout) }
    public func start(internalPort: UInt16, requestedExternalPort: UInt16 = 0, timeout: TimeInterval = 12) {
        begin(readOnly: false, internalPort: internalPort, externalPort: requestedExternalPort, timeout: timeout)
    }
    public func stop() {
        queue.async { [self] in
            generation = UUID()
            cleanup()
            emit(RouterMappingResult(state: .stopped, externalAddress: nil, internalPort: nil, externalPort: nil,
                                     errorCode: nil, lifetime: 0, readOnly: readOnly), generation: generation)
        }
    }
    deinit {
        deadline?.cancel()
        // No self capture: the callback context has only a weak owner. Deallocate
        // on the same serial queue used by DNSServiceSetDispatchQueue.
        let reference = reference, context = context
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            if let reference { DNSServiceRefDeallocate(reference) }
            if let context { Unmanaged<CallbackContext>.fromOpaque(context).release() }
        } else {
            queue.async {
                if let reference { DNSServiceRefDeallocate(reference) }
                if let context { Unmanaged<CallbackContext>.fromOpaque(context).release() }
            }
        }
    }

    private func begin(readOnly: Bool, internalPort: UInt16, externalPort: UInt16, timeout: TimeInterval) {
        queue.async { [self] in
            generation = UUID()
            cleanup()
            self.readOnly = readOnly
            confirmedMapping = false
            let current = generation
            guard readOnly || internalPort > 0 else {
                emit(RouterMappingResult(state: .unavailable, externalAddress: nil, internalPort: nil, externalPort: nil,
                                         errorCode: Int32(kDNSServiceErr_BadParam), lifetime: 0, readOnly: false), generation: current)
                return
            }
            let box = CallbackContext(owner: self, generation: current)
            let pointer = Unmanaged.passRetained(box).toOpaque()
            context = pointer
            let error = DNSServiceNATPortMappingCreate(&reference, 0, 0,
                readOnly ? 0 : DNSServiceProtocol(kDNSServiceProtocol_TCP),
                readOnly ? 0 : internalPort.bigEndian,
                readOnly ? 0 : externalPort.bigEndian,
                readOnly ? 0 : 300,
                { _, _, _, error, address, protocolValue, internalPort, externalPort, ttl, context in
                    guard let context else { return }
                    let box = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
                    box.owner?.receive(error: error, address: address, protocolValue: protocolValue,
                                       internalPort: internalPort, externalPort: externalPort, ttl: ttl, generation: box.generation)
                }, pointer)
            guard error == kDNSServiceErr_NoError, let reference else {
                cleanup()
                emit(failure(error == 0 ? Int32(kDNSServiceErr_Unknown) : error), generation: current)
                return
            }
            let dispatchError = DNSServiceSetDispatchQueue(reference, queue)
            guard dispatchError == kDNSServiceErr_NoError else {
                cleanup(); emit(failure(dispatchError), generation: current); return
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current else { return }
                self.cleanup()
                self.emit(RouterMappingResult(state: .timedOut, externalAddress: nil, internalPort: nil, externalPort: nil,
                                               errorCode: nil, lifetime: 0, readOnly: readOnly), generation: current)
            }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + max(0.1, min(60, timeout.isFinite ? timeout : 12)), execute: deadline)
        }
    }

    private func receive(error: Int32, address: UInt32, protocolValue: UInt32, internalPort: UInt16,
                         externalPort: UInt16, ttl: UInt32, generation expected: UUID) {
        guard generation == expected, reference != nil else { return }
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let external = inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) == nil ? nil : String(cString: buffer)
        guard let result = RouterMappingResult.evaluate(readOnly: readOnly, errorCode: error, externalAddress: external,
            protocolValue: protocolValue, internalPort: UInt16(bigEndian: internalPort), externalPort: UInt16(bigEndian: externalPort), lifetime: ttl) else {
            // A zero address is provisional during discovery, but after a mapped
            // endpoint existed it revokes that endpoint rather than leaving a
            // stale public invitation active indefinitely.
            if confirmedMapping {
                cleanup()
                emit(failure(Int32(kDNSServiceErr_NATTraversal)), generation: expected)
            }
            return
        }
        deadline?.cancel(); deadline = nil
        confirmedMapping = result.state == .mapped
        // Read-only inspections complete after a definitive reply. An established
        // mapping remains registered so changes/renewal failures reach the owner.
        if readOnly || result.state != .mapped { cleanup() }
        emit(result, generation: expected)
    }
    private func failure(_ code: Int32) -> RouterMappingResult {
        RouterMappingResult(state: .unavailable, externalAddress: nil, internalPort: nil, externalPort: nil,
                            errorCode: code, lifetime: 0, readOnly: readOnly)
    }
    private func cleanup() {
        deadline?.cancel(); deadline = nil
        if let reference { DNSServiceRefDeallocate(reference) }; reference = nil
        if let context { Unmanaged<CallbackContext>.fromOpaque(context).release() }; context = nil
    }
    private func emit(_ result: RouterMappingResult, generation expected: UUID) {
        callbackQueue.async { [weak self] in
            guard let self, self.queue.sync(execute: { self.generation == expected }) else { return }
            self.onChange?(result)
        }
    }
}
