import CoreML
import CreateML
import Foundation
import NaturalLanguage

/// A training example: line text + "todo" / "radar" / "note".
struct LineExample: Codable, Hashable, Sendable {
    let text: String
    let label: String

    /// Base examples from Resources/TrainingLines.json (inside the app bundle).
    static func bundled() -> [LineExample] {
        guard let url = Bundle.main.url(forResource: "TrainingLines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return json.flatMap { label, texts in texts.map { LineExample(text: $0, label: label) } }
    }
}

/// Tiny local classifier built only from Apple's frameworks (Create ML + NaturalLanguage):
/// two models – a word model (MaxEnt, ~15 KB) and one on Apple's multilingual BERT embeddings
/// (~1.3 MB) – whose probabilities are averaged. Trained on this Mac (one-time ~30 s) and
/// retrained from what the user marks.
actor LineClassifier {
    struct Prediction: Sendable {
        let label: String
        let confidence: Double
    }

    private enum Algorithm: String, Sendable { case maxEnt, bert }

    private let directory: URL
    private var maxEnt: NLModel?
    private var bert: NLModel?
    private var trainedOn: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    var isReady: Bool { maxEnt != nil }

    /// Loads the models from the cache, or retrains when the examples changed noticeably.
    /// Returns `true` when new models are active.
    func prepare(_ examples: [LineExample]) async -> Bool {
        let signature = Set(examples.map { "\($0.label)|\($0.text)" })
        if maxEnt == nil { loadCache() }
        let changes = signature.symmetricDifference(trainedOn).count
        if maxEnt != nil, changes < 3 { return false }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for algorithm in [Algorithm.maxEnt, .bert] {
            let target = directory.appending(path: "\(algorithm.rawValue).mlmodelc")
            let trained = await Task.detached(priority: .utility) { [examples] in
                try? Self.train(examples, algorithm: algorithm, into: target)
            }.value
            guard trained != nil, let model = try? NLModel(contentsOf: target) else { continue }
            switch algorithm {
            case .maxEnt: maxEnt = model
            case .bert: bert = model
            }
        }
        trainedOn = signature
        let meta = try? JSONEncoder().encode(signature.sorted())
        try? meta?.write(to: directory.appending(path: "trained-on.json"), options: .atomic)
        return maxEnt != nil
    }

    func classify(_ texts: [String]) -> [Prediction?] {
        guard let maxEnt else { return texts.map { _ in nil } }
        let weight = bert == nil ? 1.0 : 0.5
        return texts.map { text in
            var scores: [String: Double] = [:]
            for (label, p) in maxEnt.predictedLabelHypotheses(for: text, maximumCount: 3) { scores[label, default: 0] += weight * p }
            if let bert {
                for (label, p) in bert.predictedLabelHypotheses(for: text, maximumCount: 3) { scores[label, default: 0] += 0.5 * p }
            }
            guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }
            return Prediction(label: best.key, confidence: best.value)
        }
    }

    private func loadCache() {
        let meta = directory.appending(path: "trained-on.json")
        guard let data = try? Data(contentsOf: meta),
              let list = try? JSONDecoder().decode([String].self, from: data),
              let a = try? NLModel(contentsOf: directory.appending(path: "maxEnt.mlmodelc")) else { return }
        maxEnt = a
        bert = try? NLModel(contentsOf: directory.appending(path: "bert.mlmodelc"))
        trainedOn = Set(list)
    }

    private nonisolated static func train(_ examples: [LineExample], algorithm: Algorithm, into target: URL) throws -> URL {
        let data = Dictionary(grouping: examples, by: \.label).mapValues { $0.map(\.text) }
        let algo: MLTextClassifier.ModelAlgorithmType = switch algorithm {
        case .maxEnt: .maxEnt(revision: 1)
        case .bert: .transferLearning(.bertEmbedding, revision: 1)
        }
        let parameters = MLTextClassifier.ModelParameters(validation: .none, algorithm: algo, language: nil)
        let classifier = try MLTextClassifier(trainingData: data, parameters: parameters)
        let raw = FileManager.default.temporaryDirectory.appending(path: "braindump-\(algorithm.rawValue)-\(UUID().uuidString).mlmodel")
        try classifier.write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let compiled = try MLModel.compileModel(at: raw)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: compiled)
        } else {
            try FileManager.default.moveItem(at: compiled, to: target)
        }
        return target
    }
}
