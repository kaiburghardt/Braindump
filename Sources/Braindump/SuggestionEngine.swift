import Foundation
import FoundationModels
import Observation

enum LineVerdict: Sendable {
    case todo, radar, note
}

// MARK: - Structured output for Apple's on-device model

@Generable
enum LineCategory {
    case todo
    case radar
    case note
}

@Generable
struct LineClassification {
    @Guide(description: "The line number exactly as given in the input")
    var line: Int
    var category: LineCategory
}

@Generable
struct ClassificationBatch {
    @Guide(description: "Exactly one entry for every input line")
    var lines: [LineClassification]
}

// MARK: - Engine

/// Looks at note titles and decides: to-do, radar (keep an eye on it) or just a note.
/// Order: Apple Intelligence (if available) → our own mini classifier (trained locally,
/// learns from you) → simple keyword rules while the classifier is still training.
@MainActor
@Observable
final class SuggestionEngine {
    enum Backend: Equatable { case appleIntelligence, classifier, heuristic }

    private(set) var verdicts: [String: LineVerdict] = [:]
    private(set) var backend: Backend = .heuristic
    private(set) var statusText = "Simple keyword rules"
    private(set) var isWorking = false
    private(set) var classifierTraining = false

    @ObservationIgnored var onResults: (@MainActor () -> Void)?
    @ObservationIgnored var onBackendChange: (@MainActor () -> Void)?
    @ObservationIgnored private var queue: [(key: String, text: String)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var classifierReady = false
    @ObservationIgnored private var appleStatus: String?
    @ObservationIgnored private let classifier = LineClassifier(directory: NotesModel.supportURL.appending(path: "Classifier"))
    @ObservationIgnored private var pendingExamples: [LineExample]?

    /// Minimum confidence before the classifier suggests anything.
    private static let threshold = 0.6
    private static let batchSize = 16

    private static let instructions = """
    You sort the notes of a product manager's personal scratchpad. Notes are German or English \
    and are often short fragments. Put every line into exactly one category:
    - todo: something the author has to do personally – a concrete action or reminder. \
    Examples: "Max anrufen wegen Vertrag", "TODO: remove unused tracking events", "Slides für Montag vorbereiten".
    - radar: work that other people or a team are doing, which the author only wants to check on \
    every few days to see the progress or to unblock it. Examples: "-> Lisa: neue Onboarding-Texte", \
    "Design for the checkout redesign from Tom", "Rollout of the new pricing in NL".
    - note: everything else – thoughts, facts, ideas without a clear action, names, links, fragments.
    If you are unsure, use note.
    """

    /// (Re)train – at launch and after you marked a few notes yourself.
    func prepareClassifier(examples: [LineExample]) {
        guard !examples.isEmpty else { return }
        if classifierTraining {
            pendingExamples = examples
            return
        }
        classifierTraining = true
        updateStatus()
        Task {
            let changed = await classifier.prepare(examples)
            let ready = await classifier.isReady
            classifierTraining = false
            let becameReady = ready && !classifierReady
            classifierReady = ready
            if changed && !becameReady && backend == .classifier {
                reset()
                onBackendChange?()
            }
            refreshAvailability()
            if let next = pendingExamples {
                pendingExamples = nil
                prepareClassifier(examples: next)
            }
        }
    }

    func refreshAvailability() {
        let newBackend: Backend
        switch SystemLanguageModel.default.availability {
        case .available:
            newBackend = .appleIntelligence
            appleStatus = nil
        case .unavailable(let reason):
            newBackend = classifierReady ? .classifier : .heuristic
            appleStatus = switch reason {
            case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
            case .deviceNotEligible: "no Apple Intelligence on this Mac"
            case .modelNotReady: "Apple model not ready yet"
            @unknown default: "Apple Intelligence unavailable"
            }
        }
        if newBackend != backend {
            backend = newBackend
            reset()
            onBackendChange?()
        }
        updateStatus()
    }

    private func updateStatus() {
        switch backend {
        case .appleIntelligence:
            statusText = "Apple Intelligence · on this Mac"
        case .classifier:
            statusText = classifierTraining
                ? "Mini model · local · learning …"
                : "Mini model · local · learns from your clicks"
        case .heuristic:
            statusText = classifierTraining
                ? "Training the mini model (one-time, ~30 s) …"
                : "Simple keyword rules" + (appleStatus.map { " · \($0)" } ?? "")
        }
    }

    /// Forgets all results (e.g. when a better backend becomes available).
    func reset() {
        generation += 1
        verdicts = [:]
        queue = []
    }

    func enqueue(_ items: [(key: String, text: String)]) {
        var pending = Set(queue.map(\.key))
        for item in items where verdicts[item.key] == nil && !pending.contains(item.key) {
            queue.append(item)
            pending.insert(item.key)
        }
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        isWorking = true
        worker = Task { [self] in
            while !queue.isEmpty {
                let batch = Array(queue.prefix(Self.batchSize))
                queue.removeFirst(batch.count)
                let gen = generation
                let result = await classify(batch)
                if gen == generation {
                    verdicts.merge(result) { _, new in new }
                    onResults?()
                }
            }
            isWorking = false
            worker = nil
        }
    }

    private func classify(_ batch: [(key: String, text: String)]) async -> [String: LineVerdict] {
        if backend == .appleIntelligence, let result = await classifyWithModel(batch) {
            return result
        }
        if classifierReady {
            let predictions = await classifier.classify(batch.map(\.text))
            var out: [String: LineVerdict] = [:]
            for (item, prediction) in zip(batch, predictions) {
                if let rule = Heuristic.rule(item.text) {
                    out[item.key] = rule
                } else if let prediction, prediction.confidence >= Self.threshold {
                    out[item.key] = LineVerdict(label: prediction.label)
                } else {
                    out[item.key] = LineVerdict.note
                }
            }
            return out
        }
        return heuristic(batch)
    }

    private func heuristic(_ batch: [(key: String, text: String)]) -> [String: LineVerdict] {
        Dictionary(batch.map { ($0.key, Heuristic.classify($0.text)) }, uniquingKeysWith: { first, _ in first })
    }

    private func classifyWithModel(_ batch: [(key: String, text: String)]) async -> [String: LineVerdict]? {
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let listing = batch.enumerated()
                .map { "\($0.offset + 1). \(String($0.element.text.prefix(240)))" }
                .joined(separator: "\n")
            let prompt = "Classify each of these \(batch.count) lines:\n\n\(listing)"
            let response = try await session.respond(
                to: prompt,
                generating: ClassificationBatch.self,
                options: GenerationOptions(samplingMode: .greedy)
            )
            var out: [String: LineVerdict] = [:]
            for item in response.content.lines {
                let i = item.line - 1
                guard batch.indices.contains(i) else { continue }
                out[batch[i].key] = LineVerdict(item.category)
            }
            for entry in batch where out[entry.key] == nil {
                out[entry.key] = .note
            }
            return out
        } catch let error as LanguageModelSession.GenerationError {
            // One "sensitive" line shouldn't sink the whole batch → split it and retry.
            if case .guardrailViolation = error, batch.count > 1 {
                let mid = batch.count / 2
                let left = Array(batch[..<mid])
                let right = Array(batch[mid...])
                let a = await classifyWithModel(left) ?? heuristic(left)
                let b = await classifyWithModel(right) ?? heuristic(right)
                return a.merging(b) { first, _ in first }
            }
            return nil
        } catch {
            return nil
        }
    }
}

extension LineVerdict {
    init(_ category: LineCategory) {
        switch category {
        case .todo: self = .todo
        case .radar: self = .radar
        case .note: self = .note
        }
    }

    init(label: String) {
        switch label {
        case "todo": self = .todo
        case "radar", "watch": self = .radar
        default: self = .note
        }
    }
}

extension SuggestionEngine.Backend {
    var symbol: String {
        switch self {
        case .appleIntelligence: "apple.intelligence"
        case .classifier: "brain"
        case .heuristic: "text.magnifyingglass"
        }
    }
}

// MARK: - Fallback without a model

/// Keyword rules. The keyword lists contain German words on purpose: they have to match
/// the user's notes, which are often written in German.
enum Heuristic {
    private static let radarMarkers = [
        "warten auf", "wartet auf", "waiting for", "waiting on", "fortschritt", "progress",
        "stand von", "stand bei", "im blick", "nachverfolgen", "blocked", "blockiert", "rollout",
    ]
    private static let todoMarkers = [
        "todo", "to-do", "to do:", "nicht vergessen", " muss ", " müssen ", " sollte ", "erledigen",
        "anrufen", "zurückrufen", "schicken", "senden", "schreiben an", "mail an", "email an", "e-mail an",
        "buchen", "bestellen", "kaufen", "vorbereiten", "klären", "nachfragen", "nachhaken",
        "follow up", "follow-up", "remember to", "need to", "have to", " must ", "fix ", "call ",
        "send ", "book ", "prepare ", "reply ", "antworten",
    ]

    /// Unambiguous cases that always win, whatever a model says.
    static func rule(_ text: String) -> LineVerdict? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("->") || t.hasPrefix("→") || t.hasPrefix("=>") { return .radar }
        if t.contains("todo") || t.contains("to-do") { return .todo }
        for prefix in ["idee:", "idea:", "gedanke:", "thought:", "random:", "notiz:", "note:", "info:"] where t.hasPrefix(prefix) {
            return .note
        }
        return nil
    }

    static func classify(_ text: String) -> LineVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // "-> Julie: …" = delegated → keep it on the radar
        if trimmed.hasPrefix("->") || trimmed.hasPrefix("→") || trimmed.hasPrefix("=>") { return .radar }
        let t = " " + trimmed.lowercased() + " "
        if radarMarkers.contains(where: t.contains) { return .radar }
        if todoMarkers.contains(where: t.contains) { return .todo }
        return .note
    }
}
