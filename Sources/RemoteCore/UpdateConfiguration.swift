import Foundation

/// Public release metadata only. The private update-signing key is never bundled.
public enum UpdateConfiguration: Equatable {
    case unconfigured
    case configured
    case invalid

    public init(info: [String: Any]) {
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        if (info["SUFeedURL"] != nil && !(info["SUFeedURL"] is String)) ||
            (info["SUPublicEDKey"] != nil && !(info["SUPublicEDKey"] is String)) {
            self = .invalid; return
        }
        guard !feed.isEmpty || !key.isEmpty else { self = .unconfigured; return }
        guard !feed.contains(where: { $0.isWhitespace }),
              let url = URLComponents(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.url != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.base64EncodedString() == key else { self = .invalid; return }
        self = .configured
    }
}
