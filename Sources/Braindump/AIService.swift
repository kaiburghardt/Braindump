import Foundation
import Observation

/// An OpenAI-compatible chat server (for example a LiteLLM proxy, OpenAI itself, or a model
/// server on this Mac) that the user sets up in Settings → Connections. Nothing is preconfigured:
/// without a server address and a model, every feature that needs it stays off and Braindump
/// works on-device as before.
///
/// Every request asks for JSON that matches a schema (`response_format: json_schema`) with low
/// reasoning effort. Servers or models that reject one of these optional parameters get the request
/// again without it; that is remembered per model until the app quits.
@MainActor
@Observable
final class AIService {
    enum Failure: Error, Equatable, Sendable {
        case notConfigured
        case auth
        case offline
        case server(Int)
        case badResponse

        var message: String {
            switch self {
            case .notConfigured: "Set up an AI server in Settings → Connections."
            case .auth: "The AI server refused the key – check it in Settings → Connections."
            case .offline: "Can't reach the AI server."
            case .server(let code): "The AI server answered with error \(code)."
            case .badResponse: "The AI answer couldn't be read – please try again."
            }
        }
    }

    /// "https://llm.example.com" – without a trailing slash or "/v1".
    private(set) var baseURL: String
    private(set) var model: String
    private(set) var hasKey: Bool
    /// Model IDs the server listed (Save & Test), for the picker in Settings.
    private(set) var models: [String] = []

    var isConfigured: Bool { !baseURL.isEmpty && !model.isEmpty }
    var host: String { URL(string: baseURL)?.host() ?? baseURL }

    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var keyLoaded = false
    /// Optional request parameters a model rejected – left out from then on (until quit).
    @ObservationIgnored private var dropped: [String: Set<String>] = [:]

    private enum Keys {
        static let base = "aiBaseURL"
        static let model = "aiModel"
        static let keySaved = "aiKeySaved"
        /// Test runs only: a file with the key (test copies never touch the Keychain).
        static let keyFile = "aiKeyFile"
    }
    private static let keychainAccount = "ai"

    init() {
        let d = UserDefaults.standard
        baseURL = Self.normalizedBase(d.string(forKey: Keys.base) ?? "") ?? ""
        model = (d.string(forKey: Keys.model) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        hasKey = NotesModel.isTestRun ? d.string(forKey: Keys.keyFile) != nil : d.bool(forKey: Keys.keySaved)
    }

    /// "llm.example.com/v1/" → "https://llm.example.com". Plain http only for this Mac
    /// (a local model server) – the key must not travel unencrypted. nil = not usable.
    static func normalizedBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        return s
    }

    // MARK: Settings

    /// Saves the address (and the key, if one was typed) and asks the server for its models.
    func save(baseURL raw: String, key newKey: String) async -> String {
        guard let base = Self.normalizedBase(raw) else {
            return "Please use an https:// address (plain http only for localhost)."
        }
        baseURL = base
        UserDefaults.standard.set(base, forKey: Keys.base)
        loadKeyIfNeeded()
        let trimmed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { storeKey(trimmed) }
        dropped = [:]
        onChange?()
        guard !base.isEmpty else { return "Please enter the server address." }
        return await loadModels()
    }

    /// Fetches the server's model list (`GET /v1/models`) for the picker.
    @discardableResult
    func loadModels() async -> String {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + "/v1/models") else { return "Please enter the server address." }
        loadKeyIfNeeded()
        let (code, data) = await Self.send(request(url, body: nil), session: Self.session)
        switch code {
        case 200:
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            models = Array(Set(ids)).sorted()
            let count = "\(models.count) \(models.count == 1 ? "model" : "models")"
            return model.isEmpty ? "✓ Connected – \(count). Now pick a small, fast one." : "✓ Connected – \(count)."
        case 401, 403:
            return "The server refused the key."
        case 404:
            models = []
            return "Connected, but the server doesn't list its models – type the model name instead."
        case -1:
            return "Can't reach \(host)."
        default:
            return "The server answered with error \(code)."
        }
    }

    func setModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model else { return }
        model = trimmed
        UserDefaults.standard.set(trimmed, forKey: Keys.model)
        onChange?()
    }

    func remove() {
        storeKey(nil)
        baseURL = ""
        model = ""
        models = []
        UserDefaults.standard.removeObject(forKey: Keys.base)
        UserDefaults.standard.removeObject(forKey: Keys.model)
        onChange?()
    }

    /// Test runs only: point at a server (or the stub) without saving anything.
    func configureForTesting(baseURL: String, model: String) {
        guard NotesModel.isTestRun else { return }
        self.baseURL = Self.normalizedBase(baseURL) ?? ""
        self.model = model
        onChange?()
    }

    /// Optional parameters the current model rejected (for the test probe's log).
    var droppedParameters: [String] { (dropped[model] ?? []).sorted() }

    private func loadKeyIfNeeded() {
        guard !keyLoaded else { return }
        keyLoaded = true
        if NotesModel.isTestRun {
            if let path = UserDefaults.standard.string(forKey: Keys.keyFile) {
                key = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if hasKey {
            key = Keychain.get(Self.keychainAccount)
        }
    }

    private func storeKey(_ value: String?) {
        key = value
        keyLoaded = true
        hasKey = value != nil
        guard !NotesModel.isTestRun else { return }
        Keychain.set(value, for: Self.keychainAccount)
        UserDefaults.standard.set(value != nil, forKey: Keys.keySaved)
    }

    // MARK: Requests

    /// One chat request whose answer is a JSON object matching `schema`, decoded into `T`.
    /// `task` names the schema (also shows up in the server's logs).
    func complete<T: Decodable>(_ type: T.Type, task: String, system: String, user: String,
                                schema: [String: Any], maxTokens: Int = 2000) async throws(Failure) -> T {
        guard isConfigured, let url = URL(string: baseURL + "/v1/chat/completions") else { throw .notConfigured }
        loadKeyIfNeeded()

        let requestModel = model
        var omit = dropped[requestModel] ?? []
        var askedForJSONOnly = false
        while true {
            var systemText = system
            if omit.contains("response_format"), let schemaData = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) {
                systemText += "\n\nAnswer with one JSON object only, matching this JSON schema:\n" + String(decoding: schemaData, as: UTF8.self)
            } else if askedForJSONOnly {
                systemText += "\n\nAnswer with one JSON object only, no other text."
            }
            var body: [String: Any] = [
                "model": requestModel,
                "max_tokens": maxTokens,
                "messages": [["role": "system", "content": systemText], ["role": "user", "content": user]],
            ]
            // No `temperature`: several current models only accept their default.
            if !omit.contains("reasoning_effort") { body["reasoning_effort"] = "low" }
            if !omit.contains("response_format") {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": task, "strict": true, "schema": schema]]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw .badResponse }

            let (code, reply) = await Self.send(request(url, body: data), session: Self.session)
            switch code {
            case 200:
                if let content = Self.content(of: reply), let value = Self.decodeJSON(T.self, from: content) { return value }
                guard !askedForJSONOnly else { throw .badResponse }
                askedForJSONOnly = true
            case 400:
                // A model that doesn't take one of the optional parameters: leave it out and retry.
                let text = reply.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
                let mentionsReasoning = ["reasoning", "effort", "thinking", "budget"].contains { text.contains($0) }
                let mentionsFormat = ["response_format", "json_schema", "schema"].contains { text.contains($0) }
                if !omit.contains("reasoning_effort") && (mentionsReasoning || !mentionsFormat) {
                    omit.insert("reasoning_effort")
                } else if !omit.contains("response_format") {
                    omit.insert("response_format")
                } else {
                    throw .server(400)
                }
                dropped[requestModel] = omit
            case 401, 403: throw .auth
            case -1: throw .offline
            default: throw .server(code)
            }
        }
    }

    private func request(_ url: URL, body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = body == nil ? 15 : 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// No disk cache, no cookies, no redirects to another host (they would carry the key along).
    /// Test runs can answer requests from `AIStub` instead of the network.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        if NotesModel.isTestRun { config.protocolClasses = [AIStub.self] + (config.protocolClasses ?? []) }
        return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    nonisolated private static func send(_ request: URLRequest, session: URLSession) async -> (Int, Data?) {
        guard let (data, response) = try? await session.data(for: request) else { return (-1, nil) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The text of the first answer – or the arguments of a tool call, which some servers use
    /// to hand back structured output.
    private static func content(of data: Data?) -> String? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String, !text.isEmpty { return text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        if let calls = message["tool_calls"] as? [[String: Any]],
           let function = calls.first?["function"] as? [String: Any],
           let arguments = function["arguments"] as? String { return arguments }
        return nil
    }

    /// Decodes the JSON – also when it comes wrapped in a code fence or a sentence.
    static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(T.self, from: Data(text.utf8)) { return value }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? decoder.decode(T.self, from: Data(text[start...end].utf8))
    }
}

// MARK: - JSON schemas

/// Small helpers to write the JSON schemas for structured answers. Strict mode wants every
/// property listed in `required` and no extra properties.
enum Schema {
    static func object(_ properties: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
    static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    static var string: [String: Any] { ["type": "string"] }
    static var integer: [String: Any] { ["type": "integer"] }
    static func oneOf(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}

// MARK: - Test stub

/// Test runs only: answers AI requests with replies from the self-test, so tests never need a
/// real server. Requests are only intercepted while a handler is set.
final class AIStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ task: String, _ body: [String: Any]) -> Any?

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var tasks: [String] = []
    private static let lock = NSLock()

    /// `handler` gets the schema name and the request body and returns the model's JSON answer
    /// (nil → HTTP 500). It runs on a background thread.
    static func install(_ handler: Handler?) {
        lock.withLock {
            self.handler = handler
            tasks = []
        }
    }

    /// Schema names of the requests answered so far.
    static var answeredTasks: [String] { lock.withLock { tasks } }

    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { handler != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let format = (json["response_format"] as? [String: Any])?["json_schema"] as? [String: Any]
        let task = format?["name"] as? String ?? (request.url?.path.hasSuffix("/models") == true ? "models" : "unknown")
        let handler = Self.lock.withLock { () -> Handler? in
            Self.tasks.append(task)
            return Self.handler
        }
        var status = 200
        var payload: Any
        if task == "models" {
            payload = ["data": [["id": "stub-model"]]]
        } else if let answer = handler?(task, json),
                  let answerData = try? JSONSerialization.data(withJSONObject: answer) {
            payload = ["choices": [["message": ["role": "assistant", "content": String(decoding: answerData, as: UTF8.self)]]]]
        } else {
            status = 500
            payload = ["error": "stub has no answer for \(task)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
