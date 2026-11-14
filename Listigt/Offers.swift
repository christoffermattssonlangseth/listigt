import Foundation
import SwiftUI

// MARK: - Modeller

/// Butikskedjor med erbjudanden. (Coop kräver en åtkomstnyckel och är inte med än.)
enum Chain: String, CaseIterable, Identifiable, Codable {
    case willys, ica

    var id: String { rawValue }

    var title: String {
        switch self {
        case .willys: "Willys"
        case .ica: "ICA"
        }
    }

    var memberLabel: String {
        switch self {
        case .willys: "Willys Plus"
        case .ica: "Stammis"
        }
    }

    var color: Color {
        switch self {
        case .willys: Color(red: 0.89, green: 0.0, blue: 0.1)
        case .ica: Color(red: 0.89, green: 0.0, blue: 0.1)
        }
    }

    var provider: OfferProvider {
        switch self {
        case .willys: WillysProvider()
        case .ica: ICAProvider()
        }
    }
}

struct Store: Identifiable, Codable, Hashable {
    let id: String
    let chain: Chain
    let name: String
    let address: String
}

struct Offer: Identifiable, Codable, Hashable {
    let id: String
    let chain: Chain
    let name: String
    let brand: String?
    let volume: String?
    /// Kampanjpriset som det skrivs i butiken: "34,90/st", "3 för 179", "119/kg"
    let priceText: String
    let ordinaryPrice: String?
    let comparePrice: String?
    let saveText: String?
    let validTo: String?
    let memberOnly: Bool
    let imageURL: URL?
    /// Ingående varianter, t.ex. "Kvarg Vanilj 500g", "Kvarg Jordgubb 500g"
    var variants: [String]
    /// Beskrivning/villkor: "Olika sorter • Gäller ej ekologiskt"
    var info: String?
    /// "Max 3 köp", "Max 1 köp/hushåll"
    var restriction: String?
    var storeName: String?

    /// "Garant · 450g"
    var detail: String {
        [brand?.capitalizedBrand, volume].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private extension String {
    /// "GARANT EKO" → "Garant Eko", men låt "ICA" och blandade versaler vara.
    var capitalizedBrand: String {
        self == uppercased() && count > 3 ? capitalized(with: Locale(identifier: "sv_SE")) : self
    }
}

enum OfferError: LocalizedError {
    case notAvailable(String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .notAvailable(let s): s
        case .badResponse: "Kunde inte läsa erbjudandena."
        }
    }
}

protocol OfferProvider {
    func searchStores(_ query: String) async throws -> [Store]
    func offers(storeId: String) async throws -> [Offer]
}

// MARK: - Hjälp för HTTP/JSON

enum HTTP {
    static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            log("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) för \(url.host ?? "")\(url.path)")
            throw OfferError.badResponse
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
}

// MARK: - Willys (Axfood)

struct WillysProvider: OfferProvider {
    func searchStores(_ query: String) async throws -> [Store] {
        var c = URLComponents(string: "https://www.willys.se/axfood/rest/search/store")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "size", value: "30")]
        let d = try await HTTP.json(c.url!) as? JSON ?? [:]
        return d.arr("results").compactMap { s in
            guard let id = s.str("storeId"), let name = s.str("displayName") ?? s.str("name") else { return nil }
            let a = s.obj("address") ?? [:]
            let address = [a.str("line1"), a.str("town")].compactMap { $0 }.joined(separator: ", ")
            return Store(id: id, chain: .willys, name: name, address: address)
        }
    }

    func offers(storeId: String) async throws -> [Offer] {
        var all: [Offer] = []
        var page = 0
        repeat {
            var c = URLComponents(string: "https://www.willys.se/search/campaigns/offline")!
            c.queryItems = [URLQueryItem(name: "q", value: storeId),
                            URLQueryItem(name: "type", value: "PERSONAL_GENERAL"),
                            URLQueryItem(name: "page", value: String(page)),
                            URLQueryItem(name: "size", value: "200")]
            let d = try await HTTP.json(c.url!) as? JSON ?? [:]
            all += d.arr("results").compactMap(Self.parse)
            let pages = (d.obj("pagination")?["numberOfPages"] as? Int) ?? 1
            page += 1
            if page >= pages || page > 10 { break }
        } while true
        return all
    }

    private static func parse(_ p: JSON) -> Offer? {
        guard let name = p.str("name") else { return nil }
        let promo = p.arr("potentialPromotions").first ?? [:]
        let condition = promo.str("conditionLabel")      // "3 för"
        let reward = promo.str("rewardLabel")            // "179,00" / "34,90/st"
        let price = [condition, reward].compactMap { $0 }.joined(separator: " ")
        guard !price.isEmpty else { return nil }
        let ordinary = p.str("priceNoUnit").map { "\($0) \(p.str("priceUnit") ?? "")".trimmingCharacters(in: .whitespaces) }
        let image = (p.obj("image")?.str("url")).flatMap(URL.init(string:))
        return Offer(
            id: "willys-" + (promo.str("code") ?? name) + "-" + (p.str("code") ?? name),
            chain: .willys, name: name, brand: p.str("manufacturer"), volume: p.str("displayVolume"),
            priceText: price.replacingOccurrences(of: ",00", with: ""),
            ordinaryPrice: ordinary, comparePrice: promo.str("comparePrice"), saveText: promo.str("savePrice"),
            validTo: promo.str("endDate").map { String($0.split(separator: "-").first ?? Substring($0)) }, memberOnly: promo.str("campaignType") == "LOYALTY", imageURL: image,
            variants: [], info: promo.str("description"), restriction: promo.str("redeemLimitLabel"))
    }
}

// MARK: - ICA

/// ICA: webbplatsen hämtar en anonym, kortlivad biljett och anropar sedan sina sök- och erbjudandetjänster.
struct ICAProvider: OfferProvider {
    private static let api = "https://apim-pub.gw.ica.se/sverige/digx"

    private actor TokenCache {
        var token: String?
        var expires = Date.distantPast
        func get() async throws -> String {
            if let token, expires > Date().addingTimeInterval(60) { return token }
            let d = try await HTTP.json(URL(string: "https://www.ica.se/e11/public-access-token")!) as? JSON ?? [:]
            guard let t = d.str("publicAccessToken") else { throw OfferError.badResponse }
            token = t
            expires = d.str("tokenExpires").flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? Date().addingTimeInterval(15 * 60)
            return t
        }
    }
    private static let tokens = TokenCache()

    private func get(_ url: URL) async throws -> Any {
        let token = try await Self.tokens.get()
        return try await HTTP.json(url, headers: ["Authorization": "Bearer \(token)"])
    }

    func searchStores(_ query: String) async throws -> [Store] {
        var c = URLComponents(string: Self.api + "/storesearch/v1/searchbyquery")!
        c.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "take", value: "30"),
                        URLQueryItem(name: "offset", value: "0"), URLQueryItem(name: "onlyOnline", value: "false"),
                        URLQueryItem(name: "onlyOnlineB2B", value: "false")]
        let d = try await get(c.url!) as? JSON ?? [:]
        return d.arr("documents").compactMap { s in
            guard let id = s.str("id"), let name = s.str("marketingName") ?? s.str("name") else { return nil }
            let address = [s.str("visitingAddress"), s.str("visitingCity")].compactMap { $0 }.joined(separator: ", ")
            return Store(id: id, chain: .ica, name: name, address: address)
        }
    }

    func offers(storeId: String) async throws -> [Offer] {
        let url = URL(string: Self.api + "/offerreader/v1/offers/store/\(storeId)")!
        let list = try await get(url) as? [JSON] ?? []
        return list.compactMap(Self.parse)
    }

    private static func parse(_ o: JSON) -> Offer? {
        let d = o.obj("details") ?? [:]
        guard let name = d.str("name"), let price = d.str("mechanicInfo") else { return nil }
        let store = o.arr("stores").first ?? [:]
        let ordinary = store.str("referencePriceText")?
            .replacingOccurrences(of: "Ord.pris ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // "2026-11-15T00:00:00" → "15/11"
        let validTo = o.str("validTo").flatMap { s -> String? in
            let p = s.prefix(10).split(separator: "-")
            guard p.count == 3, let d = Int(p[2]), let m = Int(p[1]) else { return nil }
            return "\(d)/\(m)"
        }
        let image = (o.obj("picture")?.str("fileName"))
            .flatMap { URL(string: "https://assets.icanet.se/w_300,h_300,c_fit/\($0).png") }
        return Offer(
            id: "ica-" + (o.str("id") ?? name), chain: .ica, name: name, brand: d.str("brand"),
            volume: d.str("packageInformation"), priceText: price, ordinaryPrice: ordinary,
            comparePrice: o.str("comparisonPrice"), saveText: nil, validTo: validTo,
            memberOnly: (d["requiresLoyaltyCard"] as? Bool) ?? false, imageURL: image,
            variants: variants(o), info: d.str("customerInformation"), restriction: o.str("restriction"))
    }

    /// Varianter från EAN-listan, utan dubbletter.
    private static func variants(_ o: JSON) -> [String] {
        var seen = Set<String>()
        return o.arr("eans").compactMap { $0.str("articleDescription") }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}

// MARK: - Valda butiker, cache och matchning mot listan

@MainActor
final class OfferStore: ObservableObject {
    static let shared = OfferStore()

    @Published private(set) var stores: [Chain: Store] = [:]
    @Published private(set) var offers: [Chain: [Offer]] = [:]
    @Published private(set) var loading: Set<Chain> = []
    @Published private(set) var errors: [Chain: String] = [:]
    private var fetchedAt: [Chain: Date] = [:]

    private let storesKey = "offers.stores.v1"
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offers.json")
    }

    private struct Cache: Codable {
        var offers: [Chain: [Offer]]
        var fetchedAt: [Chain: Date]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: storesKey),
           let s = try? JSONDecoder().decode([Chain: Store].self, from: data) {
            stores = s
        }
        if let data = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: data) {
            offers = c.offers
            fetchedAt = c.fetchedAt
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-icaStore") {
            stores[.ica] = Store(id: "1510", chain: .ica, name: "ICA Kvantum Uppsala", address: "Marknadsgatan 1, Uppsala")
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-willysStore") {
            stores[.willys] = Store(id: ProcessInfo.processInfo.arguments[i + 1], chain: .willys,
                                    name: "Willys Uppsala Kungsgatan", address: "Kungsgatan 95, Uppsala")
        }
        #endif
    }

    func select(_ store: Store) {
        stores[store.chain] = store
        persistStores()
        offers[store.chain] = nil
        fetchedAt[store.chain] = nil
        Task { await refresh(store.chain, force: true) }
    }

    func forget(_ chain: Chain) {
        stores[chain] = nil
        offers[chain] = nil
        fetchedAt[chain] = nil
        persistStores()
        saveCache()
    }

    /// Hämtar om erbjudandena är äldre än 6 timmar (eller om `force`).
    func refresh(_ chain: Chain, force: Bool = false) async {
        guard let store = stores[chain], !loading.contains(chain) else { return }
        if !force, let t = fetchedAt[chain], Date().timeIntervalSince(t) < 6 * 3600 { return }
        loading.insert(chain)
        defer { loading.remove(chain) }
        do {
            var list = try await chain.provider.offers(storeId: store.id)
            for i in list.indices { list[i].storeName = store.name }
            offers[chain] = list
            fetchedAt[chain] = Date()
            errors[chain] = nil
            saveCache()
            log("\(chain.title): \(list.count) erbjudanden för \(store.name)")
        } catch {
            errors[chain] = error.localizedDescription
            log("\(chain.title): fel \(error)")
        }
    }

    func refreshAll() async {
        for chain in stores.keys { await refresh(chain) }
    }

    /// Erbjudanden som verkar gälla en vara på listan.
    func matches(for itemName: String?) -> [Offer] {
        guard let itemName else { return [] }
        return offers.values.flatMap { $0 }.filter { OfferMatcher.matches(item: itemName, offer: $0.name) }
    }

    private func persistStores() {
        if let data = try? JSONEncoder().encode(stores) { UserDefaults.standard.set(data, forKey: storesKey) }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(Cache(offers: offers, fetchedAt: fetchedAt)) {
            try? data.write(to: cacheURL)
        }
    }
}

enum OfferMatcher {
    private static func words(_ s: String) -> [String] {
        s.lowercased(with: Locale(identifier: "sv_SE"))
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    /// "Kaffe" ↔ "Kaffe", "Laxfilé" ↔ "Färsk Laxfilé", "Yoghurt" ↔ "Smaksatt Yoghurt".
    /// Svenska sammansättningar har huvudordet sist, så vi matchar på ordslut.
    static func matches(item: String, offer: String) -> Bool {
        let iw = words(item), ow = words(offer)
        guard let head = iw.last, head.count >= 3, !ow.isEmpty else { return false }
        if iw == ow { return true }
        return ow.contains { $0 == head || ($0.hasSuffix(head) && head.count >= 4) }
    }
}
