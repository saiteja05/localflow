import Foundation

public final class OllamaCleaner: CleanupProvider {
    public let id = "ollama"
    private let model: String
    private let baseURL: URL
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval

    public init(model: String = "qwen3:4b-instruct",
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                urlSession: URLSession = .shared,
                requestTimeout: TimeInterval = 4) {
        self.model = model
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    public func isAvailable() async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: "api/tags"))
        req.timeoutInterval = 1  // liveness probe must be fast
        guard let (data, resp) = try? await urlSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaAPI.TagsResponse.self, from: data)
        else { return false }
        return tags.models.contains { tag in
            tag.name == model || tag.name.split(separator: ":").first.map(String.init) == model
        }
    }

    public func clean(_ text: String, options: CleanupOptions) async throws -> String {
        let body = OllamaAPI.ChatRequest(
            model: model,
            messages: [
                .init(role: "system",
                      content: PromptBuilder.instructions(level: options.level,
                                                          vocabulary: options.vocabulary)),
                .init(role: "user", content: PromptBuilder.userPrompt(for: text)),
            ],
            stream: false, think: false, keep_alive: -1,
            options: .init(temperature: 0.2))

        var req = URLRequest(url: baseURL.appending(path: "api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = requestTimeout

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await urlSession.data(for: req) }
        catch { throw CleanupError.unavailable }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CleanupError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let decoded = try? JSONDecoder().decode(OllamaAPI.ChatResponse.self, from: data) else {
            throw CleanupError.badResponse("undecodable body")
        }
        var content = decoded.message.content
        // Older servers ignore think:false; a /no_think-style empty think block may remain.
        content = content.replacingOccurrences(
            of: #"^\s*<think>\s*</think>\s*"#, with: "", options: .regularExpression)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw CleanupError.badResponse("empty content") }
        return content
    }
}
