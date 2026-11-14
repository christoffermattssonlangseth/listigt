import Foundation

enum MeasureUnit: String, CaseIterable, Identifiable {
    case st, forp, g, hg, kg, ml, cl, dl, l

    var id: String { rawValue }

    var label: String { self == .forp ? "förp" : rawValue }

    /// Steg för −/+.
    var step: Double {
        switch self {
        case .st, .forp, .hg, .dl, .cl: 1
        case .g, .ml: 50
        case .kg, .l: 0.5
        }
    }

    /// Startvärde när man byter till enheten från ett för litet tal.
    var defaultAmount: Double {
        switch self {
        case .g, .ml: 500
        default: step
        }
    }
}

struct Quantity: Equatable {
    var amount: Double
    var unit: MeasureUnit

    static let one = Quantity(amount: 1, unit: .st)

    var isOne: Bool { self == .one }

    /// "2 st", "500 g", "1,5 l"
    var text: String { "\(Quantity.format(amount)) \(unit.label)" }

    static func format(_ x: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: x)) ?? "\(x)"
    }

    func stepped(_ direction: Double) -> Quantity {
        let s = unit.step
        // Från ett "ojämnt" värde (t.ex. 250 g) stegar vi till närmaste jämna steg.
        let next = direction > 0 ? (amount / s + 0.0001).rounded(.down) * s + s
                                 : (amount / s - 0.0001).rounded(.up) * s - s
        return Quantity(amount: max(next, s), unit: unit)
    }

    /// Summerar om enheterna är lika, annars vinner den nya mängden.
    func adding(_ other: Quantity) -> Quantity {
        other.unit == unit ? Quantity(amount: amount + other.amount, unit: unit) : other
    }
}

// MARK: - Tolka mängd ur inskriven text

enum QuantityParser {
    private static let unitWords: [String: MeasureUnit] = [
        "st": .st, "stycken": .st, "styck": .st, "x": .st,
        "förp": .forp, "förpackning": .forp, "förpackningar": .forp, "paket": .forp, "pkt": .forp,
        "g": .g, "gr": .g, "gram": .g, "hg": .hg, "kg": .kg, "kilo": .kg,
        "ml": .ml, "cl": .cl, "dl": .dl, "l": .l, "liter": .l,
    ]

    private static let number = #"(\d+(?:[.,]\d+)?)"#

    /// "Mjöl 2 kg" → ("Mjöl", 2 kg). "500g köttfärs" → ("köttfärs", 500 g). "Ägg 12" → ("Ägg", 12 st).
    /// Text utan mängd ger nil, t.ex. "Mjölk 1,5%".
    static func parse(_ raw: String) -> (name: String, quantity: Quantity?) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let units = unitWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")

        // Tal + enhet var som helst, som eget ord.
        let withUnit = #"(?:^|\s)"# + number + #"\s*("# + units + #")(?=\s|$)"#
        // "3x mjölk" / "mjölk x3"
        let times = #"(?:^|\s)(?:"# + number + #"\s*x|x\s*"# + number + #")(?=\s|$)"#
        // Ensamt heltal först eller sist: "3 bananer", "Ägg 12"
        let bare = #"(?:^(\d+)\s+)|(?:\s+(\d+)$)"#

        for (pattern, kind) in [(withUnit, 0), (times, 1), (bare, 2)] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            let numStr: String?
            var unit = MeasureUnit.st
            switch kind {
            case 0:
                numStr = group(1)
                unit = unitWords[group(2)?.lowercased() ?? ""] ?? .st
            case 1:
                numStr = group(1) ?? group(2)
            default:
                numStr = group(1) ?? group(2)
            }
            guard let n = numStr.flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }), n > 0,
                  let whole = Range(m.range, in: text) else { continue }
            var name = text
            name.removeSubrange(whole)
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            return (name.prefix(1).uppercased() + name.dropFirst(), Quantity(amount: n, unit: unit))
        }
        return (text, nil)
    }
}
