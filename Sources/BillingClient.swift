import Foundation

struct UsageSnapshot {
    let percent: Int
    let periodEnd: Date?
    let fetchedAt: Date
}

enum BillingError: Error, LocalizedError {
    case unauthorized
    case http(Int, String)
    case decode(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "HTTP 401 from billing API"
        case .http(let code, let body):
            return "Billing HTTP \(code): \(body)"
        case .decode(let message):
            return "Billing parse error: \(message)"
        case .network(let message):
            return message
        }
    }
}

enum BillingClient {
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    static func fetch(accessToken: String) throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("1.0.5", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("grok-cli", forHTTPHeaderField: "x-grok-client-identifier")

        let (data, response) = try send(request)
        guard let http = response as? HTTPURLResponse else {
            throw BillingError.network("no HTTP response")
        }
        if http.statusCode == 401 {
            throw BillingError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw BillingError.http(http.statusCode, String(snippet.prefix(180)))
        }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> UsageSnapshot {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BillingError.decode(error.localizedDescription)
        }
        guard let root = obj as? [String: Any] else {
            throw BillingError.decode("root is not an object")
        }
        let config = root["config"] as? [String: Any] ?? root

        var percent: Double?
        if let products = config["productUsage"] as? [[String: Any]] {
            if let grokBuild = products.first(where: { ($0["product"] as? String) == "GrokBuild" }) {
                percent = number(grokBuild["usagePercent"])
            }
            if percent == nil, let first = products.first {
                percent = number(first["usagePercent"])
            }
        }
        if percent == nil {
            percent = number(config["creditUsagePercent"])
        }
        guard let percent else {
            throw BillingError.decode("missing usage percent")
        }

        let period = config["currentPeriod"] as? [String: Any]
        let periodEnd = parseISO8601(period?["end"] as? String)

        return UsageSnapshot(
            percent: Int(percent.rounded()),
            periodEnd: periodEnd,
            fetchedAt: Date()
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let sem = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(BillingError.network(error.localizedDescription))
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(BillingError.network("empty response"))
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw BillingError.network("timeout")
        }
        session.finishTasksAndInvalidate()
        switch result {
        case .success(let pair): return pair
        case .failure(let error): throw error
        case .none: throw BillingError.network("no result")
        }
    }
}
