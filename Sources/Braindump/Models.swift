import Foundation
import SwiftUI

// MARK: - Radar (things to keep an eye on)

enum RadarStatus {
    case fresh, due, overdue

    var color: Color {
        switch self {
        case .fresh: .green
        case .due: .orange
        case .overdue: .red
        }
    }
}

struct RadarItem: Identifiable, Equatable {
    let note: Note

    var id: String { note.id }
    var title: String { note.title }
    var link: URL? { note.link }
    var added: Date { note.created }
    var lastChecked: Date? { note.lastChecked }
    var referenceDate: Date { lastChecked ?? added }

    /// Calendar days since the last check (or since the note went on the radar).
    func days(now: Date) -> Int {
        let cal = Calendar.current
        let d = cal.dateComponents([.day], from: cal.startOfDay(for: referenceDate), to: cal.startOfDay(for: now)).day ?? 0
        return max(0, d)
    }

    func status(now: Date, interval: Int) -> RadarStatus {
        let d = days(now: now)
        if d >= interval + 3 { return .overdue }
        if d >= interval { return .due }
        return .fresh
    }
}

// MARK: - Suggestions

struct Suggestion: Identifiable, Equatable {
    let note: Note
    /// `.todo` or `.radar`
    let type: NoteType
    var id: String { note.id }
}

// MARK: - Similarity (keeps IDs stable while a title is being rewritten)

enum TextSimilarity {
    static func score(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 0.9 }
        let wa = Set(a.split(separator: " "))
        let wb = Set(b.split(separator: " "))
        let union = wa.union(wb).count
        return union == 0 ? 0 : Double(wa.intersection(wb).count) / Double(union)
    }
}

// MARK: - Pop-up above a multi-line selection

struct SelectionAction: Identifiable {
    let title: String
    let systemImage: String
    var prominent = false
    let perform: @MainActor () -> Void

    var id: String { title }
}
