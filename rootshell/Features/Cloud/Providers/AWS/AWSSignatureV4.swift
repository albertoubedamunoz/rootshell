import Foundation
import CryptoKit

// MARK: - AWS Signature V4

/// AWS Signature Version 4 signing utility
/// Reference: https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
struct AWSSignatureV4 {

    // MARK: - Types

    struct Credentials: Sendable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?

        nonisolated init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyId = accessKeyId
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    // MARK: - Constants

    private nonisolated static let algorithm = "AWS4-HMAC-SHA256"
    private nonisolated static let aws4Request = "aws4_request"
    private nonisolated static let unsignedPayload = "UNSIGNED-PAYLOAD"

    // MARK: - Date Formatters

    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone, .withColonSeparatorInTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private nonisolated static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Public Methods

    /// Sign a URLRequest with AWS Signature V4
    /// - Parameters:
    ///   - request: The request to sign (will be modified in place)
    ///   - credentials: AWS credentials
    ///   - region: AWS region (e.g., "us-east-1")
    ///   - service: AWS service name (e.g., "ec2", "eks", "sts")
    ///   - date: The date for signing (defaults to now)
    /// - Returns: The signed request
    nonisolated static func sign(
        request: inout URLRequest,
        credentials: Credentials,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        let timestamp = timestampFormatter.string(from: date)
        let dateStamp = dateFormatter.string(from: date)

        // Set required headers
        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")

        if let sessionToken = credentials.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Ensure host header is set
        if let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }

        // Calculate payload hash
        let payloadHash: String
        if let body = request.httpBody {
            payloadHash = sha256Hex(body)
        } else {
            payloadHash = sha256Hex(Data())
        }
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        // Create canonical request
        let (canonicalRequest, signedHeaders) = createCanonicalRequest(request: request, payloadHash: payloadHash)

        // Create string to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/\(aws4Request)"
        let stringToSign = createStringToSign(
            timestamp: timestamp,
            credentialScope: credentialScope,
            canonicalRequest: canonicalRequest
        )

        // Calculate signature
        let signingKey = deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign)

        // Create authorization header
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    /// Create a presigned URL for AWS requests
    /// - Parameters:
    ///   - url: The base URL to sign
    ///   - method: HTTP method
    ///   - credentials: AWS credentials
    ///   - region: AWS region
    ///   - service: AWS service name
    ///   - headers: Additional headers to include in signing
    ///   - expiresIn: URL expiration in seconds (default 60)
    ///   - date: The date for signing
    /// - Returns: The presigned URL
    nonisolated static func presignURL(
        url: URL,
        method: String = "GET",
        credentials: Credentials,
        region: String,
        service: String,
        headers: [String: String] = [:],
        expiresIn: Int = 60,
        date: Date = Date()
    ) -> URL? {
        let timestamp = timestampFormatter.string(from: date)
        let dateStamp = dateFormatter.string(from: date)
        let credentialScope = "\(dateStamp)/\(region)/\(service)/\(aws4Request)"

        // Build signed headers string
        var allHeaders = headers
        if let host = url.host {
            allHeaders["host"] = host
        }
        let signedHeaderNames = allHeaders.keys.map { $0.lowercased() }.sorted()
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        // Build query parameters
        var queryItems: [URLQueryItem] = []

        // Add existing query items
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let existingItems = components.queryItems {
            queryItems.append(contentsOf: existingItems)
        }

        // Add AWS signing parameters
        queryItems.append(URLQueryItem(name: "X-Amz-Algorithm", value: algorithm))
        queryItems.append(URLQueryItem(name: "X-Amz-Credential", value: "\(credentials.accessKeyId)/\(credentialScope)"))
        queryItems.append(URLQueryItem(name: "X-Amz-Date", value: timestamp))
        queryItems.append(URLQueryItem(name: "X-Amz-Expires", value: String(expiresIn)))
        queryItems.append(URLQueryItem(name: "X-Amz-SignedHeaders", value: signedHeaders))

        if let sessionToken = credentials.sessionToken {
            queryItems.append(URLQueryItem(name: "X-Amz-Security-Token", value: sessionToken))
        }

        // Sort query items for canonical request
        queryItems.sort { $0.name < $1.name }

        // Build URL with query parameters
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = queryItems

        // Create canonical request
        let canonicalQueryString = queryItems.map { item in
            let name = urlEncode(item.name)
            let value = urlEncode(item.value ?? "")
            return "\(name)=\(value)"
        }.joined(separator: "&")

        let canonicalHeaders = signedHeaderNames.map { name in
            let value = allHeaders.first { $0.key.lowercased() == name }?.value ?? ""
            return "\(name):\(value.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")

        let canonicalRequest = [
            method.uppercased(),
            urlEncodePath(url.path.isEmpty ? "/" : url.path),
            canonicalQueryString,
            canonicalHeaders + "\n",
            signedHeaders,
            unsignedPayload
        ].joined(separator: "\n")

        // Create string to sign
        let stringToSign = createStringToSign(
            timestamp: timestamp,
            credentialScope: credentialScope,
            canonicalRequest: canonicalRequest
        )

        // Calculate signature
        let signingKey = deriveSigningKey(
            secretKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign)

        // Add signature to URL
        queryItems.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        components.queryItems = queryItems

        return components.url
    }

    // MARK: - Private Methods

    private nonisolated static func createCanonicalRequest(
        request: URLRequest,
        payloadHash: String
    ) -> (canonicalRequest: String, signedHeaders: String) {
        guard let url = request.url else {
            return ("", "")
        }

        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path

        // Canonical query string
        let canonicalQueryString: String
        if let query = url.query {
            let items = query.split(separator: "&").map { param -> (String, String) in
                let parts = param.split(separator: "=", maxSplits: 1)
                let key = String(parts[0])
                let value = parts.count > 1 ? String(parts[1]) : ""
                return (key, value)
            }.sorted { $0.0 < $1.0 }
            canonicalQueryString = items.map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }.joined(separator: "&")
        } else {
            canonicalQueryString = ""
        }

        // Canonical headers
        var headers: [(String, String)] = []
        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                headers.append((key.lowercased(), value.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }

        let canonicalHeaders = headers.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        let signedHeaders = headers.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method,
            urlEncodePath(path),
            canonicalQueryString,
            canonicalHeaders + "\n",
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        return (canonicalRequest, signedHeaders)
    }

    private nonisolated static func createStringToSign(
        timestamp: String,
        credentialScope: String,
        canonicalRequest: String
    ) -> String {
        let hashedRequest = sha256Hex(canonicalRequest.data(using: .utf8) ?? Data())
        return [
            algorithm,
            timestamp,
            credentialScope,
            hashedRequest
        ].joined(separator: "\n")
    }

    private nonisolated static func deriveSigningKey(
        secretKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        let kSecret = SymmetricKey(data: "AWS4\(secretKey)".data(using: .utf8)!)
        let kDate = hmacSHA256(key: kSecret, data: dateStamp)
        let kRegion = hmacSHA256(key: kDate, data: region)
        let kService = hmacSHA256(key: kRegion, data: service)
        let kSigning = hmacSHA256(key: kService, data: aws4Request)
        return kSigning
    }

    // MARK: - Crypto Helpers

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func hmacSHA256(key: SymmetricKey, data: String) -> SymmetricKey {
        let signature = HMAC<SHA256>.authenticationCode(for: data.data(using: .utf8)!, using: key)
        return SymmetricKey(data: Data(signature))
    }

    private nonisolated static func hmacSHA256Hex(key: SymmetricKey, data: String) -> String {
        let signature = HMAC<SHA256>.authenticationCode(for: data.data(using: .utf8)!, using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URL Encoding

    private nonisolated static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private nonisolated static func urlEncodePath(_ path: String) -> String {
        // SigV4 spec: each path segment must be URI-encoded twice for every
        // service except S3. The first pass percent-encodes any reserved
        // characters in the segment; the second pass percent-encodes the
        // resulting `%` sigils. EC2/EKS/STS paths happen to be all-unreserved
        // so the second pass is a no-op for them, but Bedrock model IDs carry
        // a `:` and a `.` that need the canonical URI to read `%253A`.
        // Reference: https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let onceEncoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return onceEncoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? onceEncoded
    }
}

