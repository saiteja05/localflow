import Foundation

/// DTOs for Ollama's HTTP API (docs/api.md, verified 2026-07).
enum OllamaAPI {
    struct ChatMessage: Codable { var role: String; var content: String }
    struct ChatOptions: Codable { var temperature: Double }
    struct ChatRequest: Codable {
        var model: String
        var messages: [ChatMessage]
        var stream: Bool
        var think: Bool          // top-level (Ollama >= 0.9.0); ignored by older servers
        var keep_alive: Int      // -1 keeps the model resident
        var options: ChatOptions
    }
    struct ChatResponse: Codable {
        struct Message: Codable { var content: String }
        var message: Message
    }
    struct TagsResponse: Codable {
        struct Model: Codable { var name: String }
        var models: [Model]
    }
    struct PullRequest: Codable {
        var model: String
        var stream: Bool
    }
    struct PullProgress: Codable {
        var status: String?
        var total: Int64?
        var completed: Int64?
        var error: String?
    }
}
