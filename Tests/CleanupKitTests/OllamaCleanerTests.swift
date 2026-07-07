import Foundation
import Testing
@testable import CleanupKit

/// Serial URLProtocol stub. Set `StubURLProtocol.handler` per test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no stub handler") }
        // Body arrives as a stream for URLSession uploads; read it fully.
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            req.httpBody = data
        }
        let (status, data) = handler(req)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct OllamaCleanerTests {
    let options = CleanupOptions(level: .standard, vocabulary: ["Kubernetes"])

    @Test func cleanSendsCorrectRequestShapeAndParsesContent() async throws {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/chat")
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            #expect(body["model"] as? String == "qwen3:4b-instruct")
            #expect(body["stream"] as? Bool == false)
            #expect(body["think"] as? Bool == false)          // top-level, NOT in options
            #expect(body["keep_alive"] as? Int == -1)          // top-level, NOT in options
            let opts = body["options"] as! [String: Any]
            #expect((opts["temperature"] as! NSNumber).doubleValue == 0.2)
            let messages = body["messages"] as! [[String: String]]
            #expect(messages[0]["role"] == "system")
            #expect(messages[0]["content"]!.contains("Kubernetes"))
            #expect(messages[1]["role"] == "user")
            #expect(messages[1]["content"]!.hasPrefix("Transcript:"))
            let resp = #"{"message":{"role":"assistant","content":"Cleaned text."},"done":true}"#
            return (200, Data(resp.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        let out = try await cleaner.clean("um cleaned text", options: options)
        #expect(out == "Cleaned text.")
    }

    @Test func stripsEmptyThinkBlockFromContent() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"message":{"role":"assistant","content":"<think></think>\n\nReal output"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        #expect(try await cleaner.clean("x", options: options) == "Real output")
    }

    @Test func non200Throws() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        await #expect(throws: CleanupError.self) {
            _ = try await cleaner.clean("x", options: options)
        }
    }

    @Test func emptyContentThrowsBadResponse() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"message":{"role":"assistant","content":"  "}}"#.utf8)) }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        await #expect(throws: CleanupError.badResponse("empty content")) {
            _ = try await cleaner.clean("x", options: options)
        }
    }

    @Test func isAvailableTrueWhenModelListed() async {
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/tags")
            return (200, Data(#"{"models":[{"name":"qwen3:4b-instruct"},{"name":"gemma4:latest"}]}"#.utf8))
        }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == true)
    }

    @Test func isAvailableMatchesBareNameAgainstLatestTag() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"models":[{"name":"gemma4:latest"}]}"#.utf8)) }
        let cleaner = OllamaCleaner(model: "gemma4", urlSession: stubbedSession())
        #expect(await cleaner.isAvailable() == true)
    }

    @Test func isAvailableFalseWhenModelMissingOrServerDown() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"models":[]}"#.utf8)) }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == false)
        StubURLProtocol.handler = { _ in (500, Data()) }
        #expect(await OllamaCleaner(urlSession: stubbedSession()).isAvailable() == false)
    }

    @Test func updateModelAffectsSubsequentRequests() async throws {
        StubURLProtocol.handler = { req in
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            #expect(body["model"] as? String == "switched:latest")
            return (200, Data(#"{"message":{"role":"assistant","content":"ok"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        cleaner.updateModel("switched:latest")
        _ = try await cleaner.clean("x", options: CleanupOptions(level: .standard, vocabulary: []))
    }

    // MARK: status + auto model resolution

    @Test func statusIsServerDownOnTransportFailure() async {
        StubURLProtocol.handler = { _ in (500, Data()) }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        #expect(await cleaner.status() == .serverDown)
    }

    @Test func statusResolvesConfiguredModelWhenInstalled() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"qwen3:4b-instruct"},{"name":"gemma4:latest"}]}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        #expect(await cleaner.status() ==
                .ready(resolvedModel: "qwen3:4b-instruct",
                       installed: ["qwen3:4b-instruct", "gemma4:latest"]))
    }

    @Test func statusFallsBackToInstalledChatModelWhenConfiguredMissing() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"nomic-embed-text:latest"},{"name":"gemma4:latest"}]}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())   // configured: qwen3:4b-instruct
        #expect(await cleaner.status() ==
                .ready(resolvedModel: "gemma4:latest",
                       installed: ["nomic-embed-text:latest", "gemma4:latest"]))
    }

    @Test func statusExcludesEmbeddingOnlyServers() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"nomic-embed-text:latest"},{"name":"mxbai-embed-large:latest"}]}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        #expect(await cleaner.status() == .noUsableModel(installed: ["nomic-embed-text:latest", "mxbai-embed-large:latest"]))
        #expect(await cleaner.isAvailable() == false)
    }

    @Test func isAvailableTrueViaFallbackModel() async {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"models":[{"name":"gemma4:latest"}]}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())   // configured model absent
        #expect(await cleaner.isAvailable() == true)
    }

    @Test func cleanUsesResolvedFallbackModelAfterAvailabilityCheck() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"gemma4:latest"}]}"#.utf8))
            }
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            #expect(body["model"] as? String == "gemma4:latest")
            return (200, Data(#"{"message":{"role":"assistant","content":"ok"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())   // configured: qwen3:4b-instruct
        #expect(await cleaner.isAvailable() == true)                // pipeline order: probe, then clean
        _ = try await cleaner.clean("x", options: options)
    }

    @Test func updateModelClearsResolvedFallback() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"gemma4:latest"},{"name":"switched:latest"}]}"#.utf8))
            }
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            #expect(body["model"] as? String == "switched:latest")  // not the stale gemma4 resolution
            return (200, Data(#"{"message":{"role":"assistant","content":"ok"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())   // configured: qwen3:4b-instruct
        _ = await cleaner.isAvailable()                             // resolves fallback gemma4
        cleaner.updateModel("switched:latest")                      // must clear the resolution
        _ = try await cleaner.clean("x", options: options)
    }

    @Test func transformSendsEditPromptContract() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"qwen3:4b-instruct"}]}"#.utf8))
            }
            let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            #expect(messages[0]["content"]!.contains("spoken instruction"))
            #expect(messages[1]["content"]!.contains("Instruction:\nmake it shorter"))
            #expect(messages[1]["content"]!.contains("Text:\nHello there, world"))
            return (200, Data(#"{"message":{"role":"assistant","content":"Hi, world"}}"#.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        let out = try await cleaner.transform("Hello there, world", instruction: "make it shorter")
        #expect(out == "Hi, world")
    }

    @Test func pullModelStreamsProgressAndCompletes() async throws {
        let ndjson = """
        {"status":"pulling manifest"}
        {"status":"downloading","total":1000,"completed":250}
        {"status":"downloading","total":1000,"completed":1000}
        {"status":"success"}

        """
        StubURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/pull")
            return (200, Data(ndjson.utf8))
        }
        let cleaner = OllamaCleaner(urlSession: stubbedSession())
        nonisolated(unsafe) var fractions: [Double] = []
        try await cleaner.pullModel("qwen3:4b-instruct") { fraction, _ in
            fractions.append(fraction)
        }
        #expect(fractions.contains(0.25))
        #expect(fractions.contains(1.0))
    }
}
