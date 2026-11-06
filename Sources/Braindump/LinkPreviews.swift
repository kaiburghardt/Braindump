import Foundation
import Observation

/// Title + status for a Jira or Notion link.
struct LinkPreview: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case todo, progress, done, unknown }

    var label: String?
    var title: String
    var status: String?
    var state: State
    /// Short hint when something is missing (e.g. "Connect Jira").
    var problem: String?
    var needsSetup = false
    var fetched: Date

    /// Text for the small pills: "In Progress · Title" or the hint.
    var summary: String {
        if let problem { return problem }
        return [status, title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

enum LinkSource: Hashable, Sendable {
    case jira(host: String, key: String)
    case notion(pageID: String)

    init?(url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []

        if host.hasSuffix("notion.so") || host.hasSuffix("notion.site") {
            let peek = query.first { $0.name == "p" }?.value
            for candidate in [peek, url.path()].compactMap({ $0 }) {
                if let id = Self.notionID(in: candidate) {
                    self = .notion(pageID: id)
                    return
                }
            }
            return nil
        }

        let path = url.path()
        if let key = query.first(where: { $0.name == "selectedIssue" })?.value, key.wholeMatch(of: /[A-Z][A-Z0-9_]+-\d+/) != nil {
            self = .jira(host: host, key: key)
            return
        }
        if let match = path.firstMatch(of: /\/(?:browse|issues)\/([A-Z][A-Z0-9_]+-\d+)/) {
            self = .jira(host: host, key: String(match.1))
            return
        }
        return nil
    }

    private static func notionID(in text: String) -> String? {
        let lower = text.lowercased()
        if let uuid = lower.firstMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) {
            return String(uuid.0).replacingOccurrences(of: "-", with: "")
        }
        return lower.matches(of: /[0-9a-f]{32}/).last.map { String($0.0) }
    }
}

/// Fetches title and status of Jira issues and Notion pages (with the user's own tokens),
/// caches the results and shows them in the editor, the radar list and the to-do list.
@MainActor
@Observable
final class LinkPreviewService {
    private(set) var previews: [URL: LinkPreview] = [:]
    private(set) var jiraSite: String
    /// Host of the first Atlassian link seen while no site is set – only a pre-fill for Settings.
    private(set) var suggestedJiraSite = ""
    private(set) var jiraEmail: String
    private(set) var hasJiraToken: Bool
    private(set) var hasNotionToken: Bool

    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var onCredentialsChange: (@MainActor () -> Void)?
    @ObservationIgnored private var jiraToken: String?
    @ObservationIgnored private var notionToken: String?
    @ObservationIgnored private var tokensLoaded = false
    @ObservationIgnored private var inFlight: Set<URL> = []

    private var cacheURL: URL { NotesModel.supportURL.appending(path: "link-previews.json") }

    init() {
        let d = UserDefaults.standard
        jiraSite = Self.normalizedSite(d.string(forKey: "jiraSite") ?? "")
        jiraEmail = d.string(forKey: "jiraEmail") ?? ""
        hasJiraToken = d.bool(forKey: "jiraTokenSaved")
        hasNotionToken = d.bool(forKey: "notionTokenSaved")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: LinkPreview].self, from: data) {
            previews = Dictionary(uniqueKeysWithValues: cached.compactMap { key, value in URL(string: key).map { ($0, value) } })
        }
    }

    func preview(for url: URL) -> LinkPreview? { previews[url] }

    func refresh(_ urls: [URL], force: Bool = false) {
        var droppedStale = false
        for url in Set(urls) {
            guard let source = LinkSource(url: url), !inFlight.contains(url) else { continue }
            if case .jira(let host, _) = source {
                // The Jira token only ever goes to the site from Settings – never to the host a link names.
                if jiraSite.isEmpty {
                    if suggestedJiraSite.isEmpty, host.hasSuffix(".atlassian.net") { suggestedJiraSite = host }
                } else if host != jiraSite {
                    if previews.removeValue(forKey: url) != nil { droppedStale = true }
                    continue
                }
            }
            if !force, let p = previews[url], Date().timeIntervalSince(p.fetched) < (p.problem == nil ? 300 : 60) { continue }
            inFlight.insert(url)
            loadTokensIfNeeded()
            let jira = (site: jiraSite, email: jiraEmail, token: jiraToken)
            let notion = notionToken
            Task {
                let result: LinkPreview
                switch source {
                case .jira(_, let key):
                    result = await Self.fetchJira(site: jira.site, key: key, email: jira.email, token: jira.token)
                case .notion(let id):
                    result = await Self.fetchNotion(pageID: id, token: notion)
                }
                inFlight.remove(url)
                let old = previews[url]
                // Network error: keep the old result instead of overwriting it
                if result.problem == Self.offline, var old {
                    old.fetched = result.fetched
                    previews[url] = old
                    return
                }
                previews[url] = result
                if old?.summary != result.summary || old?.state != result.state || old?.needsSetup != result.needsSetup {
                    saveCache()
                    onChange?()
                }
            }
        }
        if droppedStale {
            saveCache()
            onChange?()
        }
    }

    /// "https://Company.atlassian.net/jira/…" → "company.atlassian.net"
    static func normalizedSite(_ site: String) -> String {
        var s = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        return String(s.prefix { $0 != "/" })
    }

    // MARK: Credentials

    func saveJira(site: String, email: String, token: String) async -> String {
        jiraSite = Self.normalizedSite(site)
        jiraEmail = email.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(jiraSite, forKey: "jiraSite")
        UserDefaults.standard.set(jiraEmail, forKey: "jiraEmail")
        loadTokensIfNeeded()
        if !token.isEmpty {
            Keychain.set(token, for: "jira")
            jiraToken = token
            hasJiraToken = true
            UserDefaults.standard.set(true, forKey: "jiraTokenSaved")
        }
        onCredentialsChange?()
        guard !jiraSite.isEmpty, let token = jiraToken else { return "Please enter your Jira site and token." }
        return await Self.testJira(host: jiraSite, email: jiraEmail, token: token)
    }

    func removeJira() {
        Keychain.set(nil, for: "jira")
        jiraToken = nil
        hasJiraToken = false
        UserDefaults.standard.set(false, forKey: "jiraTokenSaved")
        onCredentialsChange?()
    }

    func saveNotion(token: String) async -> String {
        loadTokensIfNeeded()
        if !token.isEmpty {
            Keychain.set(token, for: "notion")
            notionToken = token
            hasNotionToken = true
            UserDefaults.standard.set(true, forKey: "notionTokenSaved")
        }
        onCredentialsChange?()
        guard let token = notionToken else { return "Please enter a Notion token." }
        return await Self.testNotion(token: token)
    }

    func removeNotion() {
        Keychain.set(nil, for: "notion")
        notionToken = nil
        hasNotionToken = false
        UserDefaults.standard.set(false, forKey: "notionTokenSaved")
        onCredentialsChange?()
    }

    private func loadTokensIfNeeded() {
        guard !tokensLoaded else { return }
        tokensLoaded = true
        if hasJiraToken { jiraToken = Keychain.get("jira") }
        if hasNotionToken { notionToken = Keychain.get("notion") }
    }

    private func saveCache() {
        let dict = Dictionary(uniqueKeysWithValues: previews.map { ($0.key.absoluteString, $0.value) })
        try? FileManager.default.createDirectory(at: NotesModel.supportURL, withIntermediateDirectories: true)
        try? JSONEncoder().encode(dict).write(to: cacheURL, options: .atomic)
    }

    // MARK: Fetching

    private static let offline = "offline"

    private static func problem(_ text: String, label: String?, setup: Bool = false) -> LinkPreview {
        LinkPreview(label: label, title: "", status: nil, state: .unknown, problem: text, needsSetup: setup, fetched: Date())
    }

    /// No disk cache, no stored cookies, no redirects to another host (they would carry the token along).
    private static let session = URLSession(configuration: .ephemeral, delegate: SameHostRedirects(), delegateQueue: nil)

    private static func get(_ url: URL, headers: [String: String]) async -> (Int, [String: Any]?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await session.data(for: request) else { return (-1, nil) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func jiraHeaders(email: String, token: String) -> [String: String] {
        ["Authorization": "Basic " + Data("\(email):\(token)".utf8).base64EncodedString(), "Accept": "application/json"]
    }

    private static func fetchJira(site: String, key: String, email: String, token: String?) async -> LinkPreview {
        guard !site.isEmpty, let token, !email.isEmpty else { return problem("Connect Jira …", label: key, setup: true) }
        guard let url = URL(string: "https://\(site)/rest/api/3/issue/\(key)?fields=summary,status") else {
            return problem("Invalid link", label: key)
        }
        let (code, json) = await get(url, headers: jiraHeaders(email: email, token: token))
        switch code {
        case 200:
            let fields = json?["fields"] as? [String: Any]
            let status = fields?["status"] as? [String: Any]
            let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String
            let state: LinkPreview.State = switch category {
            case "done": .done
            case "indeterminate": .progress
            case "new": .todo
            default: .unknown
            }
            return LinkPreview(label: key, title: fields?["summary"] as? String ?? key,
                               status: status?["name"] as? String, state: state, problem: nil, fetched: Date())
        case 401, 403: return problem("Check Jira login", label: key, setup: true)
        case 404: return problem("\(key) not found", label: key)
        case -1: return problem(offline, label: key)
        default: return problem("Jira error \(code)", label: key)
        }
    }

    private static func testJira(host: String, email: String, token: String) async -> String {
        guard let url = URL(string: "https://\(host)/rest/api/3/myself") else { return "Invalid Jira site." }
        let (code, json) = await get(url, headers: jiraHeaders(email: email, token: token))
        switch code {
        case 200: return "✓ Connected as \(json?["displayName"] as? String ?? email)"
        case 401, 403: return "Email or token is wrong."
        case -1: return "Can't reach \(host)."
        default: return "Jira answered with error \(code)."
        }
    }

    private static func notionHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28", "Accept": "application/json"]
    }

    private static func fetchNotion(pageID: String, token: String?) async -> LinkPreview {
        guard let token else { return problem("Connect Notion …", label: "Notion", setup: true) }
        guard let url = URL(string: "https://api.notion.com/v1/pages/\(pageID)") else { return problem("Invalid link", label: "Notion") }
        let (code, json) = await get(url, headers: notionHeaders(token))
        switch code {
        case 200:
            var title = ""
            var status: String?
            var color: String?
            for (name, raw) in json?["properties"] as? [String: Any] ?? [:] {
                guard let prop = raw as? [String: Any], let type = prop["type"] as? String else { continue }
                if type == "title", let parts = prop["title"] as? [[String: Any]] {
                    title = parts.compactMap { $0["plain_text"] as? String }.joined()
                } else if type == "status", let s = prop["status"] as? [String: Any] {
                    status = s["name"] as? String
                    color = s["color"] as? String
                } else if type == "select", name.lowercased() == "status", status == nil, let s = prop["select"] as? [String: Any] {
                    status = s["name"] as? String
                    color = s["color"] as? String
                }
            }
            if let emoji = (json?["icon"] as? [String: Any])?["emoji"] as? String { title = "\(emoji) \(title)" }
            let state: LinkPreview.State = switch color {
            case "green": .done
            case "blue", "yellow", "orange", "purple", "pink", "brown", "red": .progress
            case nil: .unknown
            default: .todo
            }
            return LinkPreview(label: "Notion", title: title.isEmpty ? "Untitled" : title,
                               status: status, state: state, problem: nil, fetched: Date())
        case 401: return problem("Check Notion token", label: "Notion", setup: true)
        case 403, 404: return problem("Page not shared with Braindump", label: "Notion", setup: true)
        case -1: return problem(offline, label: "Notion")
        default: return problem("Notion error \(code)", label: "Notion")
        }
    }

    private static func testNotion(token: String) async -> String {
        let (code, json) = await get(URL(string: "https://api.notion.com/v1/users/me")!, headers: notionHeaders(token))
        switch code {
        case 200: return "✓ Connected as integration “\(json?["name"] as? String ?? "Notion")”"
        case 401: return "The token is wrong."
        case -1: return "Can't reach Notion."
        default: return "Notion answered with error \(code)."
        }
    }
}

/// Follows a redirect only to HTTPS on the same host, so the Authorization header never leaves it.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host() == task.originalRequest?.url?.host() else { return nil }
        return request
    }
}
