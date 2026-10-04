import Foundation

/// IAM Identity Center portal URLs. Query values are escaped strictly so opaque
/// page tokens and role names keep `+`, `=`, `/` and `&` intact.
nonisolated enum AWSSSOPortalURL {
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=/?")
        return set
    }()

    static func make(region: String, path: String, query: [(name: String, value: String)] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "portal.sso.\(region).amazonaws.com"
        components.path = path
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { item in
                let value = item.value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? item.value
                return "\(item.name)=\(value)"
            }.joined(separator: "&")
        }
        return components.url
    }
}
