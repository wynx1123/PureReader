import Foundation

/// OpenAI 兼容 Chat / Embeddings 客户端（URLSession，无三方 SDK）
enum LLMClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case invalidURL
        case httpStatus(Int, String)
        case decodeFailed
        case emptyResponse
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return String(localized: "请先在设置中配置 API Key")
            case .invalidURL:
                return String(localized: "API 地址无效")
            case .httpStatus(let code, let body):
                let snippet = String(body.prefix(200))
                return String(localized: "API 错误 \(code)：\(snippet)")
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

    // MARK: - Chat

    static func chat(
        messages: [ChatMessage],
        model: String? = nil,
        temperature: Double? = nil,
        timeout: TimeInterval = AIRewriteConstants.llmTimeout
    ) async throws -> String {
        guard AIConfig.isConfigured else { throw ClientError.notConfigured }
        guard let base = AIConfig.resolvedBaseURL() else { throw ClientError.invalidURL }

        let url = base.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AIConfig.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model ?? AIConfig.chatModel,
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
        guard AIConfig.isConfigured else { throw ClientError.notConfigured }
        guard let base = AIConfig.resolvedBaseURL() else { throw ClientError.invalidURL }
        guard !texts.isEmpty else { return [] }

        let url = base.appendingPathComponent("embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(AIConfig.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model ?? AIConfig.embeddingModel,
            "input": texts
        ]
        let dims = dimensions ?? AIConfig.embeddingDimensions
        if dims > 0 {
            body["dimensions"] = dims
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
