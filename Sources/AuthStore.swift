import Foundation

struct AuthCredential {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String?
    var issuer: String?
    var recordKey: String
}

enum AuthError: Error, LocalizedError {
    case missingFile
    case noCredential
    case refreshFailed(String)
    case skippedWrite(String)

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "No ~/.grok/auth.json — run grok login"
        case .noCredential:
            return "No usable token in ~/.grok/auth.json — run grok login"
        case .refreshFailed(let message):
            return "Token refresh failed: \(message)"
        case .skippedWrite(let message):
            return message
        }
    }
}

enum AuthStore {
    private static var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
            .appendingPathComponent("auth.json")
    }

    private static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let refreshSkew: TimeInterval = 5 * 60

    static func validAccessToken() throws -> String {
        let (credential, root) = try load()
        if let expiresAt = credential.expiresAt, expiresAt.timeIntervalSinceNow > refreshSkew {
            return credential.accessToken
        }
        if credential.refreshToken == nil {
            if credential.accessToken.isEmpty { throw AuthError.noCredential }
            return credential.accessToken
        }
        return try refresh(credential, originalRoot: root)
    }

    static func forceRefresh() throws -> String {
        let (credential, root) = try load()
        return try refresh(credential, originalRoot: root)
    }

    private static func load() throws -> (AuthCredential, [String: Any]) {
        let url = authURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AuthError.missingFile
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.noCredential
        }
        guard let credential = pickCredential(from: root) else {
            throw AuthError.noCredential
        }
        return (credential, root)
    }

    private static func pickCredential(from root: [String: Any]) -> AuthCredential? {
        for (key, value) in root {
            guard let rec = value as? [String: Any] else { continue }
            let access = rec["key"] as? String ?? ""
            let refresh = rec["refresh_token"] as? String
            if access.isEmpty && (refresh == nil || refresh?.isEmpty == true) { continue }
            return AuthCredential(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: parseDate(rec["expires_at"]),
                clientID: rec["oidc_client_id"] as? String ?? clientID(fromRecordKey: key),
                issuer: rec["oidc_issuer"] as? String,
                recordKey: key
            )
        }
        return nil
    }

    private static func clientID(fromRecordKey key: String) -> String? {
        if let idx = key.range(of: "::", options: .backwards) {
            let id = String(key[idx.upperBound...])
            return id.isEmpty ? nil : id
        }
        return nil
    }

    private static func refresh(_ credential: AuthCredential, originalRoot: [String: Any]) throws -> String {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw AuthError.noCredential
        }
        guard let clientID = credential.clientID, !clientID.isEmpty else {
            throw AuthError.refreshFailed("missing oidc_client_id")
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = formURLEncoded(body)

        let (data, response) = try send(request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.refreshFailed("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.refreshFailed("HTTP \(http.statusCode) \(snippet.prefix(180))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw AuthError.refreshFailed("response missing access_token")
        }

        let newRefresh = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Double ?? (json["expires_in"] as? Int).map(Double.init) ?? 21_600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        do {
            try writeBack(
                recordKey: credential.recordKey,
                accessToken: access,
                refreshToken: newRefresh ?? refreshToken,
                expiresAt: expiresAt,
                expectedAccess: credential.accessToken,
                expectedRefresh: refreshToken
            )
        } catch AuthError.skippedWrite {
            // Grok already rotated the file; the new access token still works for this request.
        }

        return access
    }

    private static func writeBack(
        recordKey: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        expectedAccess: String,
        expectedRefresh: String
    ) throws {
        let url = authURL
        let currentData = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
              var rec = root[recordKey] as? [String: Any] else {
            throw AuthError.skippedWrite("auth.json changed shape during refresh")
        }
        let currentAccess = rec["key"] as? String ?? ""
        let currentRefresh = rec["refresh_token"] as? String ?? ""
        if currentAccess != expectedAccess || currentRefresh != expectedRefresh {
            throw AuthError.skippedWrite("auth.json changed under us; skipping write")
        }

        rec["key"] = accessToken
        rec["refresh_token"] = refreshToken
        rec["expires_at"] = iso8601String(from: expiresAt)
        root[recordKey] = rec

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try out.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(AuthError.refreshFailed("empty response"))
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw AuthError.refreshFailed("timeout")
        }
        session.finishTasksAndInvalidate()
        switch result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        case .none: throw AuthError.refreshFailed("no result")
        }
    }

    private static func formURLEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))
        let joined = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(joined.utf8)
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            return parseISO8601(s)
        }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func iso8601String(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
