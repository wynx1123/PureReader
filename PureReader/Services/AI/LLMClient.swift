import Foundation

/// 错误响应体会直接显示在 UI 上，而部分网关会在 4xx 里回显请求头或 key 片段。
/// 展示前先抹掉长串 token 与常见的 key 字段。
func redactSecrets(in body: String, limit: Int) -> String {
    var text = String(body.prefix(limit * 4))
    let patterns = [
        // Bearer <token> / api-key: <token>
        #"(?i)(bearer\s+|api[-_]?key["'\s:=]+)[A-Za-z0-9._\-]{8,}"#,
        // sk-... 之类的常见前缀密钥
        #"(?i)\b(sk|pk|rk)-[A-Za-z0-9._\-]{8,}"#,
        // JSON 里的 "authorization": "..." / "api_key": "..."
        #"(?i)"(authorization|api[-_]?key|token|secret)"\s*:\s*"[^"]{8,}""#
    ]
    for pattern in patterns {
        text = text.replacingOccurrences(
            of: pattern,
            with: "***",
            options: [.regularExpression]
        )
    }
    return String(text.prefix(limit))
}

/// OpenAI 兼容 Chat / Embeddings 客户端（URLSession，无三方 SDK）
enum LLMClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case modelNotSelected
        case invalidURL
        case httpStatus(Int, String)
        case decodeFailed
        case emptyResponse
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return String(localized: "请先在设置中配置 API Key")
            case .modelNotSelected:
                return String(localized: "请先从服务端拉取并选择模型")
            case .invalidURL:
                return String(
                    localized: "API 地址无效。公网地址需使用 HTTPS（本机或局域网地址可用 HTTP）"
                )
            case .httpStatus(let code, let body):
                return String(localized: "API 错误 \(code)：\(redactSecrets(in: body, limit: 200))")
            case .decodeFailed:
                return String(localized: "无法解析 API 响应")
            case .emptyResponse:
                return String(localized: "模型返回为空")
            case .cancelled:
                return String(localized: "已取消")
            }
        }
    }

    struct ChatMessage: Encodable, Sendable {
        let role: String
        let content: String
    }

    enum ModelAuthorization: Sendable {
        case bearer
        case apiKey
    }

    // MARK: - Models

    static func fetchModels(
        baseURL: String,
        apiKey: String,
        authorization: ModelAuthorization = .bearer,
        timeout: TimeInterval = 30
    ) async throws -> [String] {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else { throw ClientError.notConfigured }
        guard let base = validatedBaseURL(baseURL) else { throw ClientError.invalidURL }

        var request = URLRequest(url: endpointURL(base: base, path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch authorization {
        case .bearer:
            request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            request.setValue(cleanedKey, forHTTPHeaderField: "api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response)
        let models = try parseModelIDs(data)
        guard !models.isEmpty else { throw ClientError.emptyResponse }
        return models
    }

    // MARK: - Chat

    static func chat(
        messages: [ChatMessage],
        model: String? = nil,
        temperature: Double? = nil,
        timeout: TimeInterval = AIRewriteConstants.llmTimeout
    ) async throws -> String {
        guard !AIConfig.rewriteAPIKey.isEmpty else { throw ClientError.notConfigured }
        guard let base = AIConfig.resolvedRewriteBaseURL() else { throw ClientError.invalidURL }
        let selectedModel = (model ?? AIConfig.chatModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw ClientError.modelNotSelected }

        let url = endpointURL(base: base, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AIConfig.rewriteAPIKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": selectedModel,
            "temperature": temperature ?? AIConfig.temperature,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw ClientError.decodeFailed
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ClientError.emptyResponse }
        return trimmed
    }

    // MARK: - Embeddings

    static func embed(
        texts: [String],
        model: String? = nil,
        dimensions: Int? = nil,
        timeout: TimeInterval = 120
    ) async throws -> [[Float]] {
        guard !AIConfig.embeddingAPIKey.isEmpty else { throw ClientError.notConfigured }
        guard let base = AIConfig.resolvedEmbeddingBaseURL() else { throw ClientError.invalidURL }
        guard !texts.isEmpty else { return [] }
        let selectedModel = (model ?? AIConfig.embeddingModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw ClientError.modelNotSelected }

        let url = endpointURL(base: base, path: "embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AIConfig.embeddingAPIKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": selectedModel,
            "input": texts
        ]
        let dims = dimensions ?? AIConfig.embeddingDimensions
        if dims > 0 {
            body["dimensions"] = dims
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           (http.statusCode == 400 || http.statusCode == 422),
           dims > 0 {
            // 部分 OpenAI 兼容服务不接受 dimensions 参数，自动降级重试一次。
            return try await embed(
                texts: texts,
                model: model,
                dimensions: 0,
                timeout: timeout
            )
        }
        try throwIfNeeded(data: data, response: response)

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["data"] as? [[String: Any]]
        else {
            throw ClientError.decodeFailed
        }

        // 按 index 排序
        let sorted = items.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }

        return try sorted.map { item in
            guard let emb = item["embedding"] as? [Double] else {
                throw ClientError.decodeFailed
            }
            return emb.map { Float($0) }
        }
    }

    // MARK: - Helpers

    private static func throwIfNeeded(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.httpStatus(http.statusCode, body)
        }
    }

    private static func endpointURL(base: URL, path: String) -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == normalizedPath || basePath.hasSuffix("/\(normalizedPath)") {
            return base
        }
        return base.appendingPathComponent(normalizedPath)
    }

    private static func validatedBaseURL(_ value: String) -> URL? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw),
              url.host != nil,
              isTransportAcceptable(url)
        else { return nil }
        return url
    }

    private static func parseModelIDs(_ data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data)
        var ids: [String] = []

        func append(from value: Any) {
            if let id = value as? String {
                ids.append(id)
            } else if let item = value as? [String: Any],
                      let id = item["id"] as? String {
                ids.append(id)
            }
        }

        if let root = object as? [String: Any] {
            if let dataItems = root["data"] as? [Any] {
                dataItems.forEach { append(from: $0) }
            }
            if let modelItems = root["models"] as? [Any] {
                modelItems.forEach { append(from: $0) }
            }
        } else if let items = object as? [Any] {
            items.forEach { append(from: $0) }
        }

        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw ClientError.decodeFailed }
        return Array(Set(cleaned)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// 粗略 token 估算：中文约 1.5 字/token，英文约 4 字符/token
    static func estimateTokens(_ text: String) -> Int {
        let cjk = text.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }.count
        let rest = max(0, text.count - cjk)
        return max(1, Int(Double(cjk) / 1.5) + rest / 4)
    }
}
