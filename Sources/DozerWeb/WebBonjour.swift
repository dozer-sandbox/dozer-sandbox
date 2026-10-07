import Foundation
import dnssd

// 606 — `doz serve` announced with Bonjour (owner ruling; `serve.advertise`): `_http._tcp` "Dozer on <Mac>" at
// the serve port, TXT `path=/` — so Safari's Bonjour list, a phone's browser or `dns-sd -B _http._tcp` find
// `http://<mac>.local:<port>`. dns_sd (the system's mDNSResponder client — `import dnssd`, no dependency; the
// audit keeps it in this file). Registering can be refused (Local Network privacy: `kDNSServiceErr_PolicyDenied`)
// — that is said once, never fatal.

public final class WebBonjour: @unchecked Sendable {
    private var ref: DNSServiceRef?
    private let queue = DispatchQueue(label: "doz.serve.bonjour")
    private let lock = NSLock()
    private var result: ((Int32, String?) -> Void)?

    private init() {}

    /// Register; `onResult(error, registered name)` is called once dns_sd answers (0 = registered).
    public static func advertise(name: String, port: Int, onResult: @escaping @Sendable (Int32, String?) -> Void) -> WebBonjour {
        let b = WebBonjour()
        b.result = onResult
        var txt: [UInt8] = []
        let path = Array("path=/".utf8)
        txt.append(UInt8(path.count))
        txt.append(contentsOf: path)
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(b).toOpaque()
        let err = txt.withUnsafeBytes { t in
            DNSServiceRegister(&ref, 0, 0, name, "_http._tcp", nil, nil, UInt16(port).bigEndian, UInt16(t.count), t.baseAddress, { _, _, error, name, _, _, ctx in
                guard let ctx else { return }
                let me = Unmanaged<WebBonjour>.fromOpaque(ctx).takeUnretainedValue()
                let registered = name.map { String(cString: $0) }
                let cb: ((Int32, String?) -> Void)? = me.lock.withLock { let c = me.result; me.result = nil; return c }
                cb?(error, registered)
            }, context)
        }
        guard Int(err) == kDNSServiceErr_NoError, let ref else {
            onResult(Int(err) == kDNSServiceErr_NoError ? -1 : err, nil)
            return b
        }
        b.ref = ref
        DNSServiceSetDispatchQueue(ref, b.queue)
        return b
    }

    /// Stop announcing.
    public func stop() {
        lock.withLock { result = nil }
        queue.sync {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
        }
    }

    /// What a dns_sd error means for a person.
    public static func explain(_ error: Int32) -> String {
        switch Int(error) {
        case kDNSServiceErr_PolicyDenied: "macOS refused it (Local Network privacy: System Settings › Privacy & Security › Local Network — allow the app doz runs in)"
        case kDNSServiceErr_NameConflict: "another service has that name"
        case kDNSServiceErr_ServiceNotRunning: "the Bonjour service (mDNSResponder) is not running"
        default: "dns_sd error \(error)"
        }
    }
}
