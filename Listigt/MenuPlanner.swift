import Foundation
import Security

// MARK: - Recept som Claude returnerar

struct MenuIngredient: Codable, Hashable {
    var name: String
    var amount: Double
    /// "st", "g", "hg", "kg", "ml", "cl", "dl", "l" eller "" (efter smak/okänt).
    var unit: String
    /// Finns hemma i de flesta kök (salt, olja, kryddor) – läggs inte på listan som standard.
    var pantry: Bool
    /// "Willys: 2 för 40 kr", tom om varan inte är på erbjudande.
    var offer: String

    var quantity: Quantity? {
        guard amount > 0 else { return nil }
        return Quantity(amount: amount, unit: MeasureUnit(stored: unit.isEmpty ? "st" : unit) ?? .st)
    }
}

struct PlannedDish: Codable {
    var title: String
    var description: String
    var days: Int
    var servings: Int
    var minutes: Int
    var ingredients: [MenuIngredient]
    var steps: [String]
}

private struct PlannedMenu: Codable {
    var dishes: [PlannedDish]
}

struct MenuRequest {
    var people: Int
    var days: Int
    var dishes: Int
    var wishes: String
}

extension MenuDish {
    var ingredients: [MenuIngredient] {
        get { (ingredientsJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([MenuIngredient].self, from: $0) } ?? [] }
        set { ingredientsJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } }
    }
    var steps: [String] {
        get { (stepsJSON?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { stepsJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } }
    }
    var offerCount: Int { ingredients.filter { !$0.offer.isEmpty }.count }
}

// MARK: - API-nyckel i nyckelringen (bara på den här telefonen)

enum APIKey {
    private static let service = "se.langseth.listigt.anthropic"

    static var value: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Anrop till Claude

enum MenuPlanner {
    enum PlanError: LocalizedError {
        case noKey, badKey, http(Int, String), refused, truncated, unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "Lägg in en API-nyckel först."
            case .badKey: "API-nyckeln godkändes inte. Kontrollera den under Inställningar."
            case let .http(code, msg): "Claude svarade med fel \(code): \(msg)"
            case .refused: "Claude ville inte svara på den här förfrågan. Prova att ändra önskemålen."
            case .truncated: "Svaret blev för långt. Prova med färre rätter."
            case .unreadable: "Kunde inte läsa Claudes svar. Försök igen."
            }
        }
    }

    /// Hela menyn, eller (med `replacing`) en enda ny rätt som inte liknar de andra.
    static func plan(_ req: MenuRequest, offers: [Offer], avoid: [String] = [], single: Bool = false) async throws -> [PlannedDish] {
        guard let key = APIKey.value else { throw PlanError.noKey }

        let offerLines = offers.map { o in
            var s = "\(o.chain.title): \(o.name)"
            if !o.detail.isEmpty { s += " (\(o.detail))" }
            s += " – \(o.priceText)"
            if o.memberOnly { s += " [\(o.chain.memberLabel)]" }
            return s
        }

        let perDish = max(1, Int((Double(req.days) / Double(max(req.dishes, 1))).rounded(.up)))
        let task: String
        if single {
            task = """
            Föreslå EN ny middagsrätt för \(req.people) personer som ska räcka \(perDish) \(perDish == 1 ? "middag" : "middagar").
            Den ska skilja sig tydligt från: \(avoid.joined(separator: ", ")).
            """
        } else {
            task = """
            Planera en veckomeny: \(req.dishes) olika middagsrätter som tillsammans täcker \(req.days) middagar för \(req.people) personer.
            Om det är färre rätter än middagar lagas vissa rätter i större sats och räcker flera dagar; ange det i "days" \
            (summan av days ska bli \(req.days)) och skala mängderna därefter.
            """
        }

        let prompt = """
        \(task)

        Bygg rätterna i första hand på veckans erbjudanden nedan, så att hushållet sparar pengar. Vanlig svensk vardagsmat, \
        rimlig tidsåtgång en vardag, variation mellan rätterna (inte samma protein i alla).
        \(req.wishes.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "Önskemål från hushållet: \(req.wishes)")

        Regler för ingredienserna:
        - "name" är det man skriver på en inköpslista: kort, svenskt, utan mängd (t.ex. "Kycklingfilé", "Krossade tomater", "Gul lök").
        - Mängden gäller hela satsen (alla portioner och dagar). Använd enheterna st, g, hg, kg, ml, cl, dl, l, eller tom sträng och 0 för "efter smak".
        - "pantry" är true för sådant de flesta har hemma: salt, peppar, olja, smör till stekning, torra kryddor, mjöl, socker, buljongtärning.
        - "offer" anger kedja och pris om ingrediensen motsvaras av ett erbjudande nedan, t.ex. "Willys: 2 för 40 kr", annars tom sträng.
        - "steps" är korta, numrerbara instruktioner (utan siffror i början).

        Veckans erbjudanden:
        \(offerLines.isEmpty ? "(inga erbjudanden hämtade – föreslå ändå bra vardagsmat)" : offerLines.joined(separator: "\n"))
        """

        let ingredientSchema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "amount", "unit", "pantry", "offer"],
            "properties": [
                "name": ["type": "string"], "amount": ["type": "number"],
                "unit": ["type": "string", "enum": ["st", "g", "hg", "kg", "ml", "cl", "dl", "l", ""]],
                "pantry": ["type": "boolean"], "offer": ["type": "string"],
            ],
        ]
        let dishSchema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["title", "description", "days", "servings", "minutes", "ingredients", "steps"],
            "properties": [
                "title": ["type": "string"], "description": ["type": "string"],
                "days": ["type": "integer"], "servings": ["type": "integer"], "minutes": ["type": "integer"],
                "ingredients": ["type": "array", "items": ingredientSchema],
                "steps": ["type": "array", "items": ["type": "string"]],
            ],
        ]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["dishes"],
            "properties": ["dishes": ["type": "array", "items": dishSchema]],
        ]

        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 16000,
            "system": "Du är en svensk kock som planerar prisvärd vardagsmat utifrån butikernas veckoerbjudanden. Svara på svenska.",
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]

        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 240
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        r.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            if status == 401 { throw PlanError.badKey }
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            log("Claude HTTP \(status): \(msg)")
            throw PlanError.http(status, msg)
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw PlanError.refused
        case "max_tokens": throw PlanError.truncated
        default: break
        }
        if let usage = json["usage"] as? [String: Any] { log("Claude usage: \(usage)") }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let d = text.data(using: .utf8), let menu = try? JSONDecoder().decode(PlannedMenu.self, from: d),
              !menu.dishes.isEmpty else { throw PlanError.unreadable }
        return menu.dishes
    }

    /// Erbjudanden som är mat (inte hygien/hushåll), från en kedja eller alla valda butiker.
    @MainActor
    static func foodOffers(from chain: Chain? = nil) -> [Offer] {
        (chain.map { [$0] } ?? Chain.allCases).flatMap { OfferStore.shared.offers[$0] ?? [] }
            .filter { ![.hygien, .hushall].contains(AppModel.shared.category(for: $0.name)) }
    }
}
