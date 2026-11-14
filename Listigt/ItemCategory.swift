import Foundation

/// Kategorier i ungefärlig butiksordning.
enum ItemCategory: String, CaseIterable, Identifiable {
    case frukt, brod, mejeri, kott, frys, skafferi, dryck, godis, hushall, hygien, barn, ovrigt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frukt: "Frukt & grönt"
        case .brod: "Bröd"
        case .mejeri: "Mejeri"
        case .kott: "Kött & fisk"
        case .frys: "Frys"
        case .skafferi: "Skafferi"
        case .dryck: "Dryck"
        case .godis: "Godis & snacks"
        case .hushall: "Hushåll"
        case .hygien: "Hygien"
        case .barn: "Barn"
        case .ovrigt: "Övrigt"
        }
    }

    var emoji: String {
        switch self {
        case .frukt: "🥦"
        case .brod: "🍞"
        case .mejeri: "🥛"
        case .kott: "🥩"
        case .frys: "🧊"
        case .skafferi: "🥫"
        case .dryck: "🥤"
        case .godis: "🍫"
        case .hushall: "🧻"
        case .hygien: "🧴"
        case .barn: "👶"
        case .ovrigt: "📦"
        }
    }

    var label: String { "\(emoji) \(title)" }

    // MARK: Gissning från namn

    /// Hela fraser som går före allt annat (t.ex. "kokosmjölk" är inte mejeri).
    private static let phrases: [(String, ItemCategory)] = [
        ("kokosmjölk", .skafferi), ("jordnötssmör", .skafferi), ("krossade tomater", .skafferi),
        ("passerade tomater", .skafferi), ("skalade tomater", .skafferi), ("hela tomater", .skafferi), ("pomodoro", .skafferi), ("tomater på burk", .skafferi), ("rostad lök", .skafferi), ("tonfisk", .skafferi),
        ("disksvamp", .hushall), ("babyspenat", .frukt), ("babymorötter", .frukt), ("babyleaf", .frukt),
        ("våtservett", .barn), ("tvättservett", .barn), ("wipes", .barn), ("modersmjölk", .barn),
        ("baby", .barn), ("bebis", .barn), ("barnmat", .barn), ("barngröt", .barn), ("klämmis", .barn), ("crème fraiche", .mejeri),
        ("creme fraiche", .mejeri), ("cream cheese", .mejeri), ("fryst", .frys), ("djupfryst", .frys),
        ("frysta", .frys),
    ]

    /// Ordändelser per kategori. Svenska sammansättningar slutar på huvudordet
    /// ("vaniljglass", "kycklingfilé"), så vi matchar på slutet av varje ord.
    private static let endings: [(ItemCategory, [String])] = [
        (.frys, ["glass", "pommes", "fiskpinnar", "wokgrönsaker", "frysta"]),
        (.mejeri, ["mjölk", "yoghurt", "yogurt", "grädde", "gräddfil", "smör", "bregott", "margarin",
                   "ost", "keso", "kvarg", "kesella", "ägg", "cheddar", "mozzarella", "parmesan",
                   "halloumi", "fraiche", "havredryck", "sojadryck", "mandeldryck", "kefir", "mejeri"]),
        (.kott, ["kött", "färs", "kyckling", "filé", "fläsk", "bacon", "korv", "skinka", "kalkon",
                 "lax", "torsk", "fisk", "räkor", "sill", "biff", "entrecote", "karré", "kotlett",
                 "kotletter", "revben", "högrev", "salami", "chorizo", "pålägg", "leverpastej",
                 "kassler", "lamm", "nuggets", "köttbullar", "lövbiff", "fläskkarré", "rostbiff"]),
        (.frukt, ["äpple", "äpplen", "banan", "bananer", "päron", "apelsin", "apelsiner", "citron",
                  "citroner", "lime", "druvor", "kiwi", "mango", "ananas", "melon", "avokado",
                  "avokador", "tomat", "tomater", "gurka", "sallad", "paprika", "lök", "morot",
                  "morötter", "potatis", "broccoli", "blomkål", "kål", "spenat", "champinjoner",
                  "svamp", "zucchini", "squash", "aubergine", "selleri", "rödbetor", "ingefära",
                  "persilja", "dill", "basilika", "koriander", "bär", "jordgubbar", "hallon",
                  "frukt", "grönsaker", "ruccola", "sparris", "rädisor", "fänkål", "clementiner",
                  "mandariner", "nektariner", "plommon", "grapefrukt"]),
        (.brod, ["bröd", "limpa", "baguette", "baguetter", "fralla", "frallor", "bulle", "bullar",
                 "tortilla", "tortillas", "toast", "croissant", "croissanter", "scones", "skorpor",
                 "kaka", "wienerbröd"]),
        (.dryck, ["läsk", "cola", "juice", "saft", "vatten", "öl", "vin", "cider", "must",
                  "dryck", "kombucha", "smoothie", "lemonad", "tonic"]),
        (.godis, ["godis", "choklad", "chips", "popcorn", "kakor", "kex", "lakrits", "tuggummi",
                  "snacks", "ostbågar", "dipp", "pastiller", "praliner", "kola", "chokladkaka", "kanelbullar"]),
        (.hygien, ["tandkräm", "tandborste", "tandborstar", "schampo", "balsam", "tvål", "deodorant",
                   "bomullspads", "tamponger", "binda", "bindor", "rakhyvel", "plåster",
                   "solkräm", "handkräm", "hudkräm", "ansiktskräm", "tandtråd", "rakblad", "hudlotion"]),
        (.barn, ["blöja", "blöjor", "välling", "klämmis", "klämmisar", "napp", "nappar", "nappflaska",
                 "mjölkersättning", "barnmat", "barngröt", "babygröt", "bebismat", "pekfingermat"]),
        (.hushall, ["papper", "medel", "tabletter", "påsar", "folie", "servetter", "batterier",
                    "glödlampa", "glödlampor", "tändstickor", "ljus", "diskborste", "trasa", "trasor",
                    "sopsäckar", "kapslar"]),
        (.skafferi, ["pasta", "spaghetti", "makaroner", "penne", "ris", "mjöl", "socker", "salt",
                     "peppar", "krydda", "kryddor", "olja", "vinäger", "ketchup", "senap", "majonnäs",
                     "sås", "buljong", "fond", "bönor", "kikärtor", "linser", "puré", "havregryn",
                     "gryn", "flingor", "müsli", "granola", "kaffe", "honung", "sylt", "marmelad",
                     "nudlar", "couscous", "bulgur", "quinoa", "majs", "bakpulver", "jäst",
                     "kakao", "russin", "mandel", "mandlar", "nötter", "konserv", "oliver",
                     "tacoskal", "kanel", "vaniljsocker", "sirap", "pesto"]),
    ]

    /// Korta ord som bara ska matcha exakt (annars blir "te" en ändelse på allt).
    private static let exactOnly: [(String, ItemCategory)] = [("te", .skafferi), ("fil", .mejeri), ("deo", .hygien)]

    static func guess(_ name: String?) -> ItemCategory {
        guard let name else { return .ovrigt }
        let lower = name.lowercased(with: Locale(identifier: "sv_SE"))
        if let hit = phrases.first(where: { lower.contains($0.0) }) { return hit.1 }

        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        // Sista ordet väger tyngst ("grekisk yoghurt", "kaffe bryggmalet" → sedan "kaffe").
        for word in words.reversed() {
            if let hit = exactOnly.first(where: { $0.0 == word }) { return hit.1 }
            // knäckebröd ska till skafferi trots att det slutar på "bröd": längsta matchande ändelse vinner.
            var best: (len: Int, cat: ItemCategory)?
            for (cat, list) in endings {
                for e in list where word.hasSuffix(e) && e.count > (best?.len ?? 0) {
                    best = (e.count, cat)
                }
            }
            if let best { return best.cat }
        }
        return .ovrigt
    }

    // MARK: Från Open Food Facts

    static func fromOpenFoodFacts(_ tags: [String]) -> ItemCategory? {
        let t = Set(tags)
        func any(_ xs: String...) -> Bool { xs.contains(where: t.contains) }
        if any("en:baby-foods", "en:baby-milks", "en:baby-cereals") { return .barn }
        if any("en:frozen-foods") { return .frys }
        if any("en:plant-based-milks", "en:dairies", "en:milks", "en:cheeses", "en:yogurts", "en:eggs",
               "en:butters", "en:creams") { return .mejeri }
        if any("en:meats", "en:prepared-meats", "en:poultries", "en:fishes", "en:seafood") { return .kott }
        if any("en:breads") { return .brod }
        if any("en:coffees", "en:teas") { return .skafferi }
        if any("en:beverages") { return .dryck }
        if any("en:snacks", "en:sweet-snacks", "en:salty-snacks", "en:confectioneries",
               "en:chocolates") { return .godis }
        if any("en:fresh-fruits", "en:fresh-vegetables", "en:fruits", "en:vegetables") { return .frukt }
        if any("en:cereals-and-potatoes", "en:pastas", "en:rices", "en:canned-foods", "en:condiments",
               "en:sauces", "en:spreads", "en:breakfast-cereals", "en:groceries") { return .skafferi }
        return nil
    }
}
