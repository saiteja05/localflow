import Foundation

/// What the local Ollama install can do for us right now. Distinguishes the
/// states the UI must not conflate: server down vs. no chat-capable model.
public enum OllamaStatus: Equatable, Sendable {
    case serverDown
    case noUsableModel(installed: [String])   // server up; only embeddings (or nothing)
    /// Server up with a usable model: the configured one when installed,
    /// otherwise an auto-picked fallback. `installed` lists every model tag.
    case ready(resolvedModel: String, installed: [String])
}

public final class OllamaCleaner: CleanupProvider, @unchecked Sendable {
    public let id = "ollama"
    // Mutable state guarded by a lock so the model can be updated live
    // (from Settings) while in-flight requests keep reading consistent values.
    private let modelLock = NSLock()
    private var _model: String
    private var _resolvedModel: String?       // fallback pick cached by status()
    public var model: String { modelLock.withLock { _model } }
    private let baseURL: URL
    private let urlSession: URLSession
    private let requestTimeout: TimeInterval

    public init(model: String = "qwen3:4b-instruct",
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                urlSession: URLSession = .shared,
                requestTimeout: TimeInterval = 4) {
        self._model = model
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.requestTimeout = requestTimeout
    }

    public func updateModel(_ newModel: String) {
        modelLock.withLock {
            _model = newModel
            _resolvedModel = nil   // stale fallback must not outlive an explicit choice
        }
    }

    // MARK: status + availability

    /// Embedding models can't chat; never auto-pick one.
    private static func isUsableChatModel(_ name: String) -> Bool {
        !name.lowercased().contains("embed")
    }

    /// Probes the server and resolves which model a cleanup request would use:
    /// the configured model when installed, otherwise the first usable chat
    /// model (so "any Ollama with any real model" just works, spec-free setup).
    /// Caches the resolution for the subsequent `clean()` call.
    public func status() async -> OllamaStatus {
        var req = URLRequest(url: baseURL.appending(path: "api/tags"))
        req.timeoutInterval = 1  // liveness probe must be fast
        guard let (data, resp) = try? await urlSession.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(OllamaAPI.TagsResponse.self, from: data)
        else {
            modelLock.withLock { _resolvedModel = nil }
            return .serverDown
        }
        let installed = tags.models.map(\.name)
        let configured = model
        let configuredInstalled = installed.contains { name in
            name == configured || name.split(separator: ":").first.map(String.init) == configured
        }
        let resolved: String?
        if configuredInstalled {
            resolved = configured
        } else {
            resolved = installed.first(where: Self.isUsableChatModel)
        }
        modelLock.withLock { _resolvedModel = resolved }
        guard let resolved else { return .noUsableModel(installed: installed) }
        return .ready(resolvedModel: resolved, installed: installed)
    }

    public func isAvailable() async -> Bool {
        if case .ready = await status() { return true }
        return false
    }

    // MARK: cleanup

    public func clean(_ text: String, options: CleanupOptions) async throws -> String {
        // The pipeline probes isAvailable() (which resolves) right before this;
        // direct callers without a probe get the configured model.
        let requestModel = modelLock.withLock { _resolvedModel ?? _model }
        let body = OllamaAPI.ChatRequest(
            model: requestModel,
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

    // MARK: in-app model download

    /// Pulls a model through Ollama's streaming API (NDJSON progress lines) so
    /// users never need a terminal. `progress` receives (fraction 0…1, status).
    public func pullModel(_ name: String,
                          progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(OllamaAPI.PullRequest(model: name, stream: true))
        req.timeoutInterval = 3600   // large downloads

        let (bytes, resp) = try await urlSession.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw CleanupError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let update = try? decoder.decode(OllamaAPI.PullProgress.self, from: Data(line.utf8))
            else { continue }
            if let error = update.error { throw CleanupError.badResponse(error) }
            if let total = update.total, total > 0, let completed = update.completed {
                progress(Double(completed) / Double(total), update.status ?? "downloading")
            } else if let status = update.status {
                progress(status == "success" ? 1.0 : 0, status)
            }
        }
    }
}
