import Foundation

/// Decodes the payload of a JWT without verifying it — enough to read the
/// user id, plan, or expiry out of a token the tool already trusts.
enum JWT {
    static func claims(_ token: String) -> JSONObject? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return JSONObject(object)
    }

    static func expiry(_ token: String) -> Date? {
        DateParsing.unixSeconds(claims(token)?.double("exp"))
    }
}
