import Foundation
import KaruiSorting

/// How closely a stand-in backend answers as Private Cloud Compute does, on the
/// same prompts: whether its scores can stand in for Private Cloud Compute's.
public struct Agreement: Equatable, Sendable {
    public struct VariantAgreement: Equatable, Sendable {
        public let name: String
        /// Items both answered, and how many got the same majority answer.
        public let compared: Int
        public let agreed: Int
        /// Private Cloud Compute's answer → the stand-in's → count.
        public let confusion: [TriageCategory?: [TriageCategory?: Int]]
        /// Accuracy against your grades, each by its own answers, on the same items.
        public let pccAccuracy: VariantMetrics.Ratio
        public let standInAccuracy: VariantMetrics.Ratio
    }

    /// A variant changing an item's answer from shipping under Private Cloud Compute,
    /// and whether the stand-in changed it the same way.
    public struct Shift: Equatable, Sendable {
        public let variant: String
        public let item: GoldenItem
        public let pcc: (from: TriageCategory?, to: TriageCategory?)
        public let standIn: (from: TriageCategory?, to: TriageCategory?)

        public var standInFollowed: Bool { standIn.from == pcc.from && standIn.to == pcc.to }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.variant == rhs.variant && lhs.item == rhs.item && lhs.pcc == rhs.pcc && lhs.standIn == rhs.standIn
        }
    }

    public let variants: [VariantAgreement]
    public let shifts: [Shift]

    public var compared: Int { variants.reduce(0) { $0 + $1.compared } }
    public var agreed: Int { variants.reduce(0) { $0 + $1.agreed } }

    /// `pcc` and `standIn` are the same templates over the same items, in order.
    public init(pcc: [VariantResult], standIn: [VariantResult]) {
        variants = zip(pcc, standIn).map { pcc, standIn in
            let both = zip(pcc.items, standIn.items).filter { !$0.0.outcomes.isEmpty && !$0.1.outcomes.isEmpty }
            var confusion: [TriageCategory?: [TriageCategory?: Int]] = [:]
            for (p, s) in both { confusion[p.majority, default: [:]][s.majority, default: 0] += 1 }
            return VariantAgreement(
                name: pcc.template.name,
                compared: both.count,
                agreed: both.filter { $0.0.majority == $0.1.majority }.count,
                confusion: confusion,
                pccAccuracy: .init(part: both.filter { $0.0.majority == $0.0.item.labelCategory }.count, whole: both.count),
                standInAccuracy: .init(part: both.filter { $0.1.majority == $0.1.item.labelCategory }.count, whole: both.count)
            )
        }
        guard let pccShipping = pcc.first, let standInShipping = standIn.first else {
            shifts = []
            return
        }
        shifts = zip(pcc.dropFirst(), standIn.dropFirst()).flatMap { pccVariant, standInVariant in
            pccShipping.items.indices.compactMap { index -> Shift? in
                let pccBefore = pccShipping.items[index], pccAfter = pccVariant.items[index]
                let standInBefore = standInShipping.items[index], standInAfter = standInVariant.items[index]
                guard ![pccBefore, pccAfter, standInBefore, standInAfter].contains(where: \.outcomes.isEmpty),
                      pccBefore.majority != pccAfter.majority else { return nil }
                return Shift(
                    variant: pccVariant.template.name, item: pccBefore.item,
                    pcc: (pccBefore.majority, pccAfter.majority), standIn: (standInBefore.majority, standInAfter.majority)
                )
            }
        }
    }

    public func markdown(standIn: String, goldenFile: String) -> String {
        func percent(_ part: Int, _ whole: Int) -> String { VariantMetrics.Ratio(part: part, whole: whole).text }
        var lines = [
            "# \(standIn) as a stand-in for Private Cloud Compute",
            "",
            "Golden set: \(goldenFile). Each item’s majority answer from each, on the same prompts.",
            "",
            "**Same answer as Private Cloud Compute: \(percent(agreed, compared))**",
            "",
            "| | Same answer | PCC accuracy | \(standIn) accuracy |",
            "|---|---|---|---|",
        ]
        lines += variants.map { "| \($0.name) | \(percent($0.agreed, $0.compared)) | \($0.pccAccuracy.text) | \($0.standInAccuracy.text) |" }
        lines += ["", "Rows are Private Cloud Compute’s answer; columns, \(standIn)’s, over every prompt.", "",
                  "| | Important | Neutral | Spam | Unreadable |", "|---|---|---|---|---|"]
        let categories: [TriageCategory?] = [.notifyNow, .summary, .silence, nil]
        for row in categories {
            let counts = categories.map { column in variants.reduce(0) { $0 + ($1.confusion[row]?[column] ?? 0) } }
            lines.append("| \(ReportWriter.title(row)) | " + counts.map(String.init).joined(separator: " | ") + " |")
        }
        lines += ["", "## Where a variant moved Private Cloud Compute’s answer", ""]
        if shifts.isEmpty {
            lines.append("No variant changed an answer under Private Cloud Compute, so there’s nothing yet to check the stand-in follows.")
        } else {
            lines.append("A stand-in that’s useful for choosing variants moves the same way: \(percent(shifts.filter(\.standInFollowed).count, shifts.count)) did.")
            lines.append("")
            lines += shifts.map {
                "- \($0.standInFollowed ? "✓" : "✗") \($0.variant): PCC \(ReportWriter.title($0.pcc.from)) → \(ReportWriter.title($0.pcc.to)); \(standIn) \(ReportWriter.title($0.standIn.from)) → \(ReportWriter.title($0.standIn.to)). \($0.item.summary)"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
