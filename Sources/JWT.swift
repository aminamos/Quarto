import Foundation

enum JWT {
    /// Unverified payload read. Old ABS tokens have no `exp` and are treated as live.
    static func expiration(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let exp: Double?
        if let value = json["exp"] as? Double {
            exp = value
        } else if let value = json["exp"] as? Int {
            exp = Double(value)
        } else {
            exp = nil
        }
        guard let exp else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func needsRefresh(_ token: String, leeway: TimeInterval = 90) -> Bool {
        guard let exp = expiration(of: token) else { return false }
        return exp.timeIntervalSinceNow < leeway
    }
}
