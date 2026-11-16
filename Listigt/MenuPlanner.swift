import Foundation

// MARK: - En planerad rätt (sparas som MenuDish)

struct MenuIngredient: Codable, Hashable {
    var name: String
    var amount: Double
    /// "st", "g", "hg", "kg", "ml", "cl", "dl", "l" eller "" (mängden står då i `measure`).
    var unit: String
    /// Finns hemma i de flesta kök (salt, olja, kryddor) – läggs inte på listan som standard.
    var pantry: Bool
    /// "Willys: 2 för 40 kr", tom om varan inte är på erbjudande.
    var offer: String
    /// Mängd som inte går att handla i, t.ex. "2 msk" eller "1 burk".
    var measure: String? = nil

    var quantity: Quantity? {
        guard amount > 0 else { return nil }
        return Quantity(amount: amount, unit: MeasureUnit(stored: unit.isEmpty ? "st" : unit) ?? .st)
    }

    var amountText: String { quantity?.text ?? measure ?? "efter smak" }
}

struct PlannedDish {
    var title: String
    var description: String
    var days: Int
    var servings: Int
    var minutes: Int
    var ingredients: [MenuIngredient]
    var steps: [String]
    var recipeId: Int = 0
    var url: String? = nil
    var imageURL: String? = nil
}

struct MenuRequest {
    var people: Int
    var days: Int
    var dishes: Int
    var quick: Bool
    var vegetarian: Bool
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

// MARK: - ICA:s recept (samma inofficiella väg som erbjudandena)

enum ICARecipes {
    private static let api = "https://apim-pub.gw.ica.se/sverige/digx"

    struct Hit {
        let id: Int
        let categories: [String]
        let minutes: Int
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> JSON {
        let token = try await ICAProvider.tokens.get()
        var r = URLRequest(url: URL(string: api + path)!, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? JSON else { throw OfferError.badResponse }
        return json
    }

    static func search(_ query: String, take: Int = 30) async throws -> [Hit] {
        let d = try await post("/globalsearch/v1/search/quicksearch",
                               ["queryString": query, "take": take, "offset": 0,
                                "accountNumber": "0", "searchDomain": "Recipes"])
        return d.obj("recipeResult")?.arr("documents").compactMap { x in
            guard let id = x["_id"] as? Int else { return nil }
            return Hit(id: id, categories: x["mdsaCategories"] as? [String] ?? [],
                       minutes: Int(x.str("cookingTimeValue") ?? "") ?? 0)
        } ?? []
    }

    /// Hela recept (ingredienser, steg, portioner) för flera id i ett anrop.
    static func recipes(_ ids: [Int]) async throws -> [JSON] {
        guard !ids.isEmpty else { return [] }
        return try await post("/recipesearch/v1/search/recipes/byids", ["recipeIds": ids]).arr("documents")
    }
}

// MARK: - Planering utifrån erbjudanden

enum MenuPlanner {
    enum PlanError: LocalizedError {
        case network, nothingFound
        var errorDescription: String? {
            switch self {
            case .network: "Kunde inte hämta recept från ICA. Kontrollera uppkopplingen och försök igen."
            case .nothingFound: "Hittade inga passande recept. Prova utan \"Snabba rätter\" eller med en annan butik."
            }
        }
    }

    /// Erbjudanden som är mat (inte hygien/hushåll), från en kedja eller alla valda butiker.
    @MainActor
    static func foodOffers(from chain: Chain? = nil) -> [Offer] {
        (chain.map { [$0] } ?? Chain.allCases).flatMap { OfferStore.shared.offers[$0] ?? [] }
            .filter { ![.hygien, .hushall, .dryck, .godis, .barn].contains(AppModel.shared.category(for: $0.name)) }
    }

    /// Fördelar middagarna på rätterna: 5 dagar på 3 rätter → [2, 2, 1].
    static func split(days: Int, into dishes: Int) -> [Int] {
        let n = max(1, min(dishes, days))
        return (0..<n).map { days / n + ($0 < days % n ? 1 : 0) }
    }

    /// Väljer `days.count` recept. `avoid` = recept-id som redan finns i menyn.
    @MainActor
    static func plan(_ req: MenuRequest, offers: [Offer], days: [Int], avoid: Set<Int> = []) async throws -> [PlannedDish] {
        let terms = searchTerms(offers: offers, vegetarian: req.vegetarian)
        log("Veckomeny: söker \(terms)")

        // 1. Sök recept för varje erbjudande (parallellt) och behåll middagsrätter.
        var hitsByTerm: [(String, [Hit])] = []
        do {
            hitsByTerm = try await withThrowingTaskGroup(of: (Int, String, [ICARecipes.Hit]).self) { g in
                for (i, t) in terms.enumerated() {
                    g.addTask { (i, t, try await ICARecipes.search(t)) }
                }
                var out: [(Int, String, [ICARecipes.Hit])] = []
                for try await r in g { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
            }
        } catch { throw PlanError.network }

        var candidateTerm: [Int: String] = [:]
        for (term, hits) in hitsByTerm {
            let good = hits.filter { h in
                let c = Set(h.categories)
                guard !c.isDisjoint(with: ["Middag", "Huvudrätt"]),
                      c.isDisjoint(with: ["Förrätt", "Efterrätt", "Dessert", "Bakning", "Tårta", "Smörgåstårta"]),
                      !avoid.contains(h.id) else { return false }
                if req.quick && (h.minutes == 0 || h.minutes > 30) { return false }
                if req.vegetarian && !c.contains("Vegetarisk") { return false }
                return true
            }
            // Slumpa bland de 20 mest relevanta, så att varje meny blir olika.
            for h in good.prefix(20).shuffled().prefix(6) where candidateTerm[h.id] == nil { candidateTerm[h.id] = term }
        }

        // 2. Hämta hela recepten och poängsätt efter hur mycket som är på erbjudande.
        let docs: [JSON]
        do { docs = try await ICARecipes.recipes(Array(candidateTerm.keys)) } catch { throw PlanError.network }

        struct Scored { let doc: JSON; let id: Int; let term: String; let score: Double }
        let scored: [Scored] = docs.compactMap { d in
            guard let id = (d["id"] as? Int) ?? (d["_id"] as? Int), let term = candidateTerm[id] else { return nil }
            let names = ingredientRows(d).map { cleanName($0.str("ingredient") ?? "") }
                .filter { !isPantry($0, unit: "") }
            let onOffer = Set(names.compactMap { n in offers.first { OfferMatcher.matches(item: n, offer: $0.name) }?.id })
            let rating = d.obj("rating")?["averageRating"] as? Double ?? 3
            return Scored(doc: d, id: id, term: term, score: Double(onOffer.count) * 2 + rating + Double.random(in: 0..<3))
        }
        .sorted { $0.score > $1.score }

        // 3. Välj de bästa, helst med olika huvudingrediens.
        var chosen: [Scored] = []
        var usedTerms = Set<String>(), usedTitles = Set<String>()
        for pass in 0..<2 {
            for s in scored where chosen.count < days.count {
                let title = (s.doc.str("title") ?? "").lowercased()
                guard !usedTitles.contains(title), !chosen.contains(where: { $0.id == s.id }) else { continue }
                if pass == 0 && usedTerms.contains(s.term) { continue }
                chosen.append(s); usedTerms.insert(s.term); usedTitles.insert(title)
            }
        }
        guard !chosen.isEmpty else { throw PlanError.nothingFound }

        return zip(chosen, days).map { s, d in dish(from: s.doc, id: s.id, people: req.people, days: d, offers: offers) }
    }

    // MARK: Sökord

    private static let stopWords: Set<String> = [
        "färsk", "färska", "fryst", "frysta", "ekologisk", "ekologiska", "eko", "svensk", "svenska", "garant",
        "pack", "skivad", "skivade", "strimlad", "tärnad", "hel", "hela", "fryst", "naturell", "klassisk",
        "ca", "st", "med", "och", "i", "av", "kg", "g", "liten", "stor", "storpack", "mini", "fil", "minuter",
    ]

    /// "Färsk Laxfilé" → "laxfilé", "Ekologisk blandfärs" → "blandfärs".
    static func searchTerm(for offerName: String) -> String? {
        let words = offerName.lowercased(with: Locale(identifier: "sv_SE"))
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        guard !words.isEmpty else { return nil }
        return words.prefix(2).joined(separator: " ")
    }

    @MainActor
    private static func searchTerms(offers: [Offer], vegetarian: Bool) -> [String] {
        var terms: [String] = []
        let wanted: Set<ItemCategory> = vegetarian ? [.frukt, .mejeri, .skafferi, .frys] : [.kott]
        for o in offers where wanted.contains(AppModel.shared.category(for: o.name))
            && !o.name.localizedCaseInsensitiveContains("pålägg") {
            guard let t = searchTerm(for: o.name) else { continue }
            let q = vegetarian ? "vegetarisk \(t)" : t
            if !terms.contains(q) { terms.append(q) }
            if terms.count >= 16 { break }
        }
        terms = Array(terms.shuffled().prefix(10))
        terms.append(vegetarian ? "vegetarisk middag" : "vardagsmiddag")
        return terms
    }

    // MARK: Recept → rätt

    private static func ingredientRows(_ d: JSON) -> [JSON] {
        d.arr("ingredientGroups").flatMap { $0.arr("ingredients") }
    }

    private static func portions(_ d: JSON) -> Int {
        (d.arr("ingredientGroups").first?["portions"] as? Int) ?? Int(d.str("defaultPortions") ?? "") ?? 4
    }

    private static func dish(from d: JSON, id: Int, people: Int, days: Int, offers: [Offer]) -> PlannedDish {
        let servings = people * days
        let factor = Double(servings) / Double(max(portions(d), 1))
        var seen = Set<String>()
        let ingredients: [MenuIngredient] = ingredientRows(d).compactMap { row in
            let name = cleanName(row.str("ingredient") ?? "")
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let qty = (row["quantity"] as? Double ?? 0) * factor
            let rawUnit = (row.str("unit") ?? "").lowercased()
            var ing = MenuIngredient(name: name, amount: 0, unit: "", pantry: isPantry(name, unit: rawUnit), offer: "")
            if qty > 0 {
                switch rawUnit {
                case "g" where qty >= 1000, "ml" where qty >= 1000:
                    ing.unit = rawUnit == "g" ? "kg" : "l"
                    ing.amount = rounded(qty / 1000, unit: ing.unit)
                case "g", "hg", "kg", "ml", "cl", "dl", "l":
                    ing.amount = rounded(qty, unit: rawUnit); ing.unit = rawUnit
                case "", "st":
                    ing.amount = qty.rounded(.up); ing.unit = "st"
                default:
                    ing.measure = "\(Quantity.format(rounded(qty, unit: rawUnit))) \(rawUnit)"
                }
            }
            if let o = offers.first(where: { OfferMatcher.matches(item: name, offer: $0.name) }) {
                ing.offer = "\(o.chain.title): \(o.priceText)"
            }
            return ing
        }
        let steps = (d["cookingSteps"] as? [String] ?? d.arr("cookingStepItems").compactMap { $0.str("text") })
            .map(stripHTML).filter { !$0.isEmpty }
        let image = d.str("imageUrl").map { $0.hasPrefix("http") ? $0 : "https://assets.icanet.se/t_ICAseAbsoluteUrl/\($0)" }
        return PlannedDish(
            title: d.str("title") ?? "Recept",
            description: stripHTML(d.str("preamble") ?? ""),
            days: days, servings: servings,
            minutes: Int(d.str("cookingTimeValue") ?? "") ?? 0,
            ingredients: ingredients, steps: steps,
            recipeId: id, url: d.str("absoluteUrl"), imageURL: image)
    }

    /// Rimligt avrundat för en inköpslista: 612 g → 650 g, 1,33 dl → 1,5 dl.
    private static func rounded(_ x: Double, unit: String) -> Double {
        switch unit {
        case "g", "ml": return x < 100 ? (x / 10).rounded(.up) * 10 : (x / 50).rounded(.up) * 50
        default: return (x * 2).rounded(.up) / 2
        }
    }

    private static let pantryWords = [
        "salt", "peppar", "olja", "olivolja", "rapsolja", "vatten", "socker", "vetemjöl", "buljong", "fond",
        "kryddpeppar", "paprikapulver", "curry", "spiskummin", "oregano", "timjan", "chiliflakes", "kanel",
        "lagerblad", "soja", "vinäger", "smör eller margarin", "margarin", "basilika torkad", "rosmarin torkad",
        "ättika", "bakpulver", "honung", "chilipulver", "gurkmeja", "ingefära malen", "vitlökspulver",
    ]

    private static func isPantry(_ name: String, unit: String) -> Bool {
        let n = name.lowercased()
        if ["krm", "nypa"].contains(unit) { return true }
        return pantryWords.contains { n == $0 || n.hasSuffix(" \($0)") || n.hasSuffix($0) && $0.count >= 6 }
    }

    /// "port ris eller couscous" → "Ris", "kålrabbi (1 st motsvarar ca 300 g)" → "Kålrabbi".
    static func cleanName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        // "ris eller couscous" → "ris", "nöt- eller fläskfärs" → "nötfärs"
        // och "skivad färsk eller inlagd jalapeño" → "inlagd jalapeño".
        if let r = s.range(of: " eller ") {
            let a = String(s[..<r.lowerBound]), b = String(s[r.upperBound...])
            if a.hasSuffix("-") {
                s = String(a.dropLast()) + compoundHead(of: b)
            } else {
                // Fler ord efter "eller" betyder att substantivet står där: "röd eller gul lök" → "gul lök".
                let aw = a.split(separator: " ").count, bw = b.split(separator: " ").count
                s = bw > 1 && bw >= aw ? b : a
            }
        }
        for sep in [", ", " till ", " att "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        s = s.replacingOccurrences(of: #"^(port|förp|burk|paket|pkt|knippe|kruka|skivor|klyftor?|nypa)\s+"#,
                                   with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Huvudledet i ett sammansatt ord: "fläskfärs" → "färs", "kycklingbuljong" → "buljong".
    private static let heads = ["färs", "filé", "kött", "buljong", "fond", "korv", "bröd", "mjöl", "ost",
                                "yoghurt", "grädde", "sås", "lök", "olja", "kål", "bönor", "linser", "pasta"]

    private static func compoundHead(of word: String) -> String {
        let w = word.split(separator: " ").last.map(String.init) ?? word
        if let h = heads.filter({ w.hasSuffix($0) && w.count > $0.count }).max(by: { $0.count < $1.count }) { return h }
        return w.count > 4 ? String(w.suffix(4)) : w   // gissning: sista stavelsen
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

typealias Hit = ICARecipes.Hit
