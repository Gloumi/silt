import Foundation

/// How long ago something was last touched, in the handful of steps a person
/// actually reasons in.
///
/// `DiskCore` deliberately knows nothing about this: it stores a raw timestamp
/// and takes a raw cutoff. Where the lines fall, and what they are called, is a
/// presentation decision — and it has to be *one* decision, because the treemap
/// legend and the large-files filter are read against each other. Their
/// thresholds are the same numbers on purpose.
enum AgeBand: Int, CaseIterable, Identifiable {
    case month, halfYear, year, twoYears, older

    var id: Int { rawValue }

    /// Exclusive upper bound in days; nil for the open-ended last band.
    private var maxDays: Double? {
        switch self {
        case .month: 30
        case .halfYear: 182
        case .year: 365
        case .twoYears: 730
        case .older: nil
        }
    }

    var label: String {
        switch self {
        case .month: "moins d'un mois"
        case .halfYear: "1 à 6 mois"
        case .year: "6 mois à 1 an"
        case .twoYears: "1 à 2 ans"
        case .older: "plus de 2 ans"
        }
    }

    /// For the legend, where five of these sit side by side over the drawing.
    var shortLabel: String {
        switch self {
        case .month: "< 1 mois"
        case .halfYear: "1-6 mois"
        case .year: "6 m-1 an"
        case .twoYears: "1-2 ans"
        case .older: "> 2 ans"
        }
    }

    /// Nil when the filesystem gave us no date, which must read as "unknown"
    /// rather than "ancient" — the views paint those neutral.
    static func band(modTime: Int32, now: Date = Date()) -> AgeBand? {
        guard modTime > 0 else { return nil }
        let days = (now.timeIntervalSince1970 - TimeInterval(modTime)) / 86_400
        return allCases.first { band in
            band.maxDays.map { days < $0 } ?? true
        }
    }
}

/// The choice offered in the large-files view. Every threshold is a band
/// boundary, so "plus d'un an" here and the legend over there agree.
enum AgeFilter: String, CaseIterable, Identifiable {
    case all, sixMonths, oneYear, twoYears

    var id: String { rawValue }

    private var days: Double? {
        switch self {
        case .all: nil
        case .sixMonths: 182
        case .oneYear: 365
        case .twoYears: 730
        }
    }

    /// Reads as the tail of the sentence it sits in — "dans les 100 plus gros
    /// fichiers, **plus d'un an**".
    var label: String {
        switch self {
        case .all: "toutes dates"
        case .sixMonths: "plus de 6 mois"
        case .oneYear: "plus d'un an"
        case .twoYears: "plus de 2 ans"
        }
    }

    /// For the empty state, where a sentence has to be built around it.
    var emptyStateDescription: String {
        switch self {
        case .all: "Ce dossier ne contient aucun fichier visible."
        case .sixMonths: "Tout ce qui est ici a bougé il y a moins de 6 mois."
        case .oneYear: "Tout ce qui est ici a bougé il y a moins d'un an."
        case .twoYears: "Tout ce qui est ici a bougé il y a moins de 2 ans."
        }
    }

    /// Unix seconds before which an entry counts as stale; nil means no filter.
    func cutoff(now: Date = Date()) -> Int32? {
        guard let days else { return nil }
        return Int32(now.timeIntervalSince1970 - days * 86_400)
    }
}
