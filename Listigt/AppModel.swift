import CoreData
import CloudKit
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let persistence = Persistence()
    @Published private(set) var household: Household?
    @Published private(set) var isShared = false
    @Published var errorMessage: String?

    private var ctx: NSManagedObjectContext { persistence.viewContext }
    private let shareDelegate = ShareDelegate()
    private let mergeKey = "mergePrivateIntoShared"

    private init() {
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo"), (household?.items ?? []).isEmpty {
            ["Mjölk", "Bröd", "Ägg", "Smör"].forEach { addBase($0) }
            addItem("Bananer"); addItem("Bananer")
            addItem("Kaffe", ean: "7310050001234")
            if let it = household?.items?.first(where: { $0.name == "Ägg" }) { toggle(it) }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-openItem") {
            addItem(ProcessInfo.processInfo.arguments[i + 1])
        }
        if ProcessInfo.processInfo.arguments.contains("-demoQty") {
            for t in ["Mjöl 2 kg", "500 g köttfärs", "Grädde 3 dl", "Ägg 12", "Mjölk 1,5%"] {
                let p = QuantityParser.parse(t)
                addItem(p.name, quantity: p.quantity)
            }
            _ = addBase("Mjölk", quantity: Quantity(amount: 3, unit: .l))
        }
        if ProcessInfo.processInfo.arguments.contains("-demoMenu"), (household?.menuDishes ?? []).isEmpty {
            func ing(_ n: String, _ a: Double, _ u: String, pantry: Bool = false, offer: String = "") -> MenuIngredient {
                MenuIngredient(name: n, amount: a, unit: u, pantry: pantry, offer: offer)
            }
            replaceMenu(with: [
                PlannedDish(title: "Krämig kycklinggryta med ris", description: "Mild gryta med paprika och grädde.",
                            days: 2, servings: 8, minutes: 35,
                            ingredients: [ing("Kycklingfilé", 1.2, "kg", offer: "Willys: 89,90/kg"),
                                          ing("Matlagningsgrädde", 5, "dl", offer: "ICA: 2 för 25 kr"),
                                          ing("Paprika", 2, "st"), ing("Gul lök", 1, "st"), ing("Ris", 6, "dl"),
                                          ing("Salt", 0, "", pantry: true), ing("Olja", 2, "dl", pantry: true)],
                            steps: ["Skär kycklingen i bitar och bryn i olja.", "Tillsätt lök och paprika.",
                                    "Häll på grädden och låt puttra 15 minuter.", "Servera med ris."]),
                PlannedDish(title: "Fiskpinnar med potatismos", description: "Snabbt och barnvänligt.",
                            days: 1, servings: 4, minutes: 25,
                            ingredients: [ing("Fiskpinnar", 1, "st", offer: "Willys: 39,90/st"), ing("Potatis", 1, "kg")],
                            steps: ["Koka potatisen.", "Stek fiskpinnarna.", "Mosa potatisen med mjölk och smör."]),
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("-demoHistory"), let h = household, (h.purchases ?? []).isEmpty {
            let day: TimeInterval = 86_400
            let trips: [(Double, [String])] = [
                (1.2, ["Mjölk", "Bröd", "Kaffe", "Bananer", "Kvarg"]),
                (4.9, ["Mjölk", "Ost", "Bananer", "Tvättservetter"]),
                (8.1, ["Mjölk", "Bröd", "Bananer", "Kvarg", "Köttfärs", "Tacoskal"]),
                (12.0, ["Mjölk", "Kaffe", "Kvarg", "Pasta"]),
            ]
            for (ago, names) in trips {
                for (i, n) in names.enumerated() {
                    let p = ctx.insert(Purchase.self, into: h.objectID.persistentStore)
                    p.name = n; p.quantity = .one; p.household = h
                    p.date = Date().addingTimeInterval(-ago * day + Double(i) * 90)
                }
            }
            save()
        }
        if ProcessInfo.processInfo.arguments.contains("-demoIntervals"), let h = household {
            let day: TimeInterval = 86_400
            for b in h.baseItems ?? [] {
                switch b.name {
                case "Smör": b.intervalDays = 14; b.lastAdded = Date().addingTimeInterval(-20 * day)
                case "Ägg": b.intervalDays = 7; b.lastAdded = Date().addingTimeInterval(-2 * day)
                default: break
                }
            }
            (h.items ?? []).filter { $0.name == "Smör" || $0.name == "Ägg" }.forEach(ctx.delete)
            save()
            addDueBaseItems()
        }
        #endif
    }

    // MARK: Hushåll

    /// Väljer aktivt hushåll: en lista som delats med mig går före min egen.
    /// Slår även ihop dubbletter som kan uppstå när en ny enhet startar innan iCloud hunnit synka.
    func refresh() {
        let req = NSFetchRequest<Household>(entityName: "Household")
        req.sortDescriptors = [NSSortDescriptor(key: "created", ascending: true)]
        let all = (try? ctx.fetch(req)) ?? []
        let shared = all.filter { $0.objectID.persistentStore == persistence.sharedStore }
        var mine = all.filter { $0.objectID.persistentStore == persistence.privateStore }

        if mine.count > 1 {
            let shares = (try? persistence.container.fetchShares(matching: mine.map(\.objectID))) ?? [:]
            let keeper = mine.first { shares[$0.objectID] != nil } ?? mine[0]
            for h in mine where h != keeper {
                copyContents(from: h, to: keeper)
                ctx.delete(h)
            }
            mine = [keeper]
        }

        if mine.isEmpty && shared.isEmpty {
            let h = ctx.insert(Household.self, into: persistence.privateStore)
            h.name = "Inköpslista"
            h.created = Date()
            mine = [h]
        }

        // Efter att ha accepterat en inbjudan: flytta in det jag redan hade skrivit upp.
        if UserDefaults.standard.bool(forKey: mergeKey), let target = shared.first, let own = mine.first {
            copyContents(from: own, to: target)
            own.items?.forEach(ctx.delete)
            own.baseItems?.forEach(ctx.delete)
            UserDefaults.standard.set(false, forKey: mergeKey)
        }

        save()
        let active = shared.first ?? mine.first
        if household != active {
            household = active
            addDueBaseItems()
        }
        isShared = active.map { persistence.share(for: $0) != nil } ?? false
    }

    private func copyContents(from src: Household, to dst: Household) {
        let store = dst.objectID.persistentStore
        for i in src.items ?? [] where !(dst.items ?? []).contains(where: { same($0.name, i.name) }) {
            let n = ctx.insert(ShopItem.self, into: store)
            n.name = i.name; n.quantity = i.quantity; n.ean = i.ean; n.checked = i.checked
            n.fromBase = i.fromBase; n.created = i.created; n.household = dst
        }
        for b in src.baseItems ?? [] where !(dst.baseItems ?? []).contains(where: { same($0.name, b.name) }) {
            let n = ctx.insert(BaseItem.self, into: store)
            n.name = b.name; n.ean = b.ean; n.created = b.created
            n.intervalDays = b.intervalDays; n.lastAdded = b.lastAdded; n.quantity = b.quantity
            n.household = dst
        }
        for e in src.eanNames ?? [] where !(dst.eanNames ?? []).contains(where: { $0.ean == e.ean }) {
            let n = ctx.insert(EanName.self, into: store)
            n.ean = e.ean; n.name = e.name; n.household = dst
        }
        for c in src.categoryChoices ?? [] where !(dst.categoryChoices ?? []).contains(where: { $0.key == c.key }) {
            let n = ctx.insert(CategoryChoice.self, into: store)
            n.key = c.key; n.category = c.category; n.household = dst
        }
        for p in src.purchases ?? [] {
            let n = ctx.insert(Purchase.self, into: store)
            n.name = p.name; n.ean = p.ean; n.amount = p.amount; n.unit = p.unit; n.date = p.date
            n.household = dst
        }
    }

    // MARK: Inköpslistan

    func addItem(_ rawName: String, ean: String? = nil, quantity: Quantity? = nil) {
        guard let h = household else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let ex = (h.items ?? []).first(where: { matches($0.name, $0.ean, name, ean) }) {
            if ex.checked {
                ex.checked = false
                if let quantity { ex.quantity = quantity }
            } else {
                ex.quantity = quantity.map { ex.quantity.adding($0) } ?? ex.quantity.stepped(1)
            }
            if ex.ean == nil { ex.ean = ean }
        } else {
            let it = ctx.insert(ShopItem.self, into: h.objectID.persistentStore)
            it.name = name
            it.ean = ean
            it.quantity = quantity ?? .one
            it.created = Date()
            it.fromBase = (h.baseItems ?? []).contains { same($0.name, name) }
            it.household = h
        }
        save()
    }

    func toggle(_ item: ShopItem) {
        item.checked.toggle()
        if item.checked { recordPurchase(of: item) } else { undoPurchase(of: item) }
        save()
    }

    // MARK: Köphistorik

    private func recordPurchase(of item: ShopItem) {
        guard let h = household else { return }
        let p = ctx.insert(Purchase.self, into: h.objectID.persistentStore)
        p.name = item.name
        p.ean = item.ean
        p.quantity = item.quantity
        p.date = Date()
        p.household = h
    }

    /// Avbockning ångrad: ta bort den senaste registreringen av varan (inom samma tillfälle).
    private func undoPurchase(of item: ShopItem) {
        let cutoff = Date().addingTimeInterval(-PurchaseHistory.tripWindow)
        let recent = (household?.purchases ?? [])
            .filter { same($0.name, item.name) && ($0.date ?? .distantPast) > cutoff }
            .max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        if let recent { ctx.delete(recent) }
    }

    func deletePurchases(_ ps: [Purchase]) {
        ps.forEach(ctx.delete)
        save()
    }

    // MARK: Veckomeny

    func replaceMenu(with dishes: [PlannedDish]) {
        guard let h = household else { return }
        h.menuDishes?.forEach(ctx.delete)
        for (i, d) in dishes.enumerated() { insertDish(d, order: i, into: h) }
        save()
    }

    func replaceDish(_ old: MenuDish, with d: PlannedDish) {
        guard let h = household else { return }
        let order = Int(old.order)
        ctx.delete(old)
        insertDish(d, order: order, into: h)
        save()
    }

    private func insertDish(_ d: PlannedDish, order: Int, into h: Household) {
        let m = ctx.insert(MenuDish.self, into: h.objectID.persistentStore)
        m.title = d.title; m.info = d.description
        m.days = Int64(max(d.days, 1)); m.servings = Int64(d.servings); m.minutes = Int64(d.minutes)
        m.ingredients = d.ingredients; m.steps = d.steps
        m.order = Int64(order); m.created = Date(); m.household = h
    }

    /// Lägger rätternas ingredienser på inköpslistan (skafferivaror bara om man vill). Returnerar antal.
    @discardableResult
    func addIngredients(of dishes: [MenuDish], includePantry: Bool = false) -> Int {
        var n = 0
        for d in dishes {
            for ing in d.ingredients where includePantry || !ing.pantry {
                addItem(ing.name, quantity: ing.quantity)
                n += 1
            }
        }
        return n
    }

    func isBase(_ name: String?) -> Bool {
        (household?.baseItems ?? []).contains { same($0.name, name) }
    }
    func step(_ item: ShopItem, _ direction: Double) { item.quantity = item.quantity.stepped(direction); save() }

    /// Oavbockad vara på listan med samma namn eller streckkod.
    func openItem(named name: String?, ean: String?) -> ShopItem? {
        (household?.items ?? []).first { !$0.checked && matches($0.name, $0.ean, name ?? "", ean) }
    }

    // MARK: Produktkort

    func update(_ item: ShopItem, with e: ProductEdit) {
        let oldName = item.name
        item.name = e.name
        item.quantity = e.quantity
        applyNameAndCategory(oldName: oldName, ean: item.ean, e)
        save()
    }

    func update(_ base: BaseItem, with e: ProductEdit) {
        let oldName = base.name
        // Öppna varor på listan som kom från basvaran följer med vid namnbyte.
        if !same(oldName, e.name) {
            for it in household?.items ?? [] where it.fromBase && !it.checked && same(it.name, oldName) {
                it.name = e.name
            }
        }
        base.name = e.name
        base.quantity = e.quantity
        if let days = e.intervalDays, days != base.intervalDays { setInterval(base, days: days) }
        applyNameAndCategory(oldName: oldName, ean: base.ean, e)
        save()
    }

    private func applyNameAndCategory(oldName: String?, ean: String?, _ e: ProductEdit) {
        if let c = e.category, c != category(for: e.name) { setCategory(c, for: e.name) }
        // Rättat namn på en scannad vara: kom ihåg det till nästa scanning.
        if let ean, !same(oldName, e.name) { remember(ean: ean, name: e.name) }
        objectWillChange.send()
    }
    func delete(_ items: [ShopItem]) { items.forEach(ctx.delete); save() }

    func clearChecked() {
        delete((household?.items ?? []).filter(\.checked))
    }

    /// Tar bort avbockade varor och lägger till alla basvaror som saknas. Returnerar antal tillagda.
    @discardableResult
    func newRound() -> Int {
        guard let h = household else { return 0 }
        (h.items ?? []).filter(\.checked).forEach(ctx.delete)
        let n = addMissingBase(to: h, from: Array(h.baseItems ?? []))
        save()
        return n
    }

    /// Lägger basvarorna på listan. Varor med intervall tas bara med när det är dags;
    /// står varan redan på listan räknas det som en gång (intervallet börjar om).
    private func addMissingBase(to h: Household, from bases: [BaseItem], now: Date = Date()) -> Int {
        let open = (h.items ?? []).filter { !$0.checked && !$0.isDeleted }
        var added = 0
        for (i, b) in bases.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }).enumerated()
        where Schedule.isDue(b, now: now) {
            b.lastAdded = now
            if open.contains(where: { matches($0.name, $0.ean, b.name ?? "", b.ean) }) { continue }
            let it = ctx.insert(ShopItem.self, into: h.objectID.persistentStore)
            it.name = b.name
            it.ean = b.ean
            it.quantity = b.quantity
            it.fromBase = true
            // Basvaror hamnar sist bland de oavbockade.
            it.created = Date(timeIntervalSince1970: Double(i))
            it.household = h
            added += 1
        }
        return added
    }

    /// Lägger automatiskt till basvaror med intervall som har blivit aktuella.
    /// Körs när appen startar eller kommer till förgrunden.
    @discardableResult
    func addDueBaseItems() -> Int {
        guard let h = household else { return 0 }
        let due = (h.baseItems ?? []).filter { $0.intervalDays > 0 && Schedule.isDue($0, now: Date()) }
        guard !due.isEmpty else { return 0 }
        let n = addMissingBase(to: h, from: Array(due))
        save()
        return n
    }

    func setInterval(_ b: BaseItem, days: Int64) {
        guard b.intervalDays != days else { return }
        // Saknas historik räknas intervallet från idag.
        if b.lastAdded == nil { b.lastAdded = Date() }
        b.intervalDays = days
        save()
    }

    // MARK: Basvaror

    /// Returnerar ett meddelande att visa, eller nil.
    @discardableResult
    func addBase(_ rawName: String, ean: String? = nil, intervalDays: Int64 = 0, quantity: Quantity? = nil) -> String? {
        guard let h = household else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if (h.baseItems ?? []).contains(where: { matches($0.name, $0.ean, name, ean) }) {
            return "\(name) finns redan bland basvarorna"
        }
        let b = ctx.insert(BaseItem.self, into: h.objectID.persistentStore)
        b.name = name
        b.ean = ean
        b.created = Date()
        b.intervalDays = intervalDays
        if let quantity { b.quantity = quantity }
        b.household = h
        let added = addMissingBase(to: h, from: [b])
        save()
        return added > 0 ? "\(name) lades även till på inköpslistan" : nil
    }

    func deleteBase(_ bases: [BaseItem]) {
        for b in bases {
            for it in household?.items ?? [] where same(it.name, b.name) { it.fromBase = false }
            ctx.delete(b)
        }
        save()
    }

    // MARK: Streckkoder

    func knownName(for ean: String) -> String? {
        let key = EAN.memoryKey(ean)
        return household?.eanNames?.first { $0.ean == key }?.name
    }

    func lookup(_ ean: String) async -> String? {
        if let n = knownName(for: ean) { return n }
        // Butikens egna koder (vägda/prismärkta varor) finns inte i någon databas.
        if EAN.isInStore(ean) {
            log("EAN \(ean): butikens egen kod, hoppar över databaserna")
            return nil
        }
        guard let p = await ProductLookup.product(for: ean) else { return nil }
        // Kategorin från Open Food Facts används om hushållet inte redan valt en.
        if let c = p.category, choice(for: p.name) == nil { setCategory(c, for: p.name) }
        return p.name
    }

    // MARK: Kategorier

    private func categoryKey(_ name: String?) -> String {
        (name ?? "").trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "sv_SE"))
    }

    private func choice(for name: String?) -> CategoryChoice? {
        let key = categoryKey(name)
        return household?.categoryChoices?.first { $0.key == key }
    }

    func category(for name: String?) -> ItemCategory {
        choice(for: name)?.category.flatMap(ItemCategory.init(rawValue:)) ?? ItemCategory.guess(name)
    }

    /// Sparar kategorin om användaren valt en annan än den gissade.
    func remember(category c: ItemCategory?, for name: String) {
        if let c, c != category(for: name) { setCategory(c, for: name) }
    }

    func setCategory(_ c: ItemCategory, for name: String?) {
        guard let h = household, let name, !name.isEmpty else { return }
        objectWillChange.send()
        if let existing = choice(for: name) {
            existing.category = c.rawValue
        } else {
            let ch = ctx.insert(CategoryChoice.self, into: h.objectID.persistentStore)
            ch.key = categoryKey(name)
            ch.category = c.rawValue
            ch.household = h
        }
        save()
    }

    /// Grupperar i butiksordning; tomma kategorier utelämnas.
    func grouped<T>(_ things: [T], name: (T) -> String?) -> [(ItemCategory, [T])] {
        let dict = Dictionary(grouping: things) { category(for: name($0)) }
        return ItemCategory.allCases.compactMap { c in dict[c].map { (c, $0) } }
    }

    func remember(ean rawEan: String, name: String) {
        guard let h = household else { return }
        let ean = EAN.memoryKey(rawEan)
        if let e = h.eanNames?.first(where: { $0.ean == ean }) {
            if e.name != name { e.name = name }
        } else {
            let e = ctx.insert(EanName.self, into: h.objectID.persistentStore)
            e.ean = ean
            e.name = name
            e.household = h
        }
        save()
    }

    // MARK: Delning via iCloud

    @Published private(set) var preparingShare = false

    func presentSharing() {
        guard let h = household, !preparingShare else { return }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do {
                let status = try await persistence.ckContainer.accountStatus()
                log("iCloud-kontostatus: \(status.rawValue)")
                guard status == .available else {
                    errorMessage = "Du behöver vara inloggad i iCloud (Inställningar → ditt namn → iCloud) för att dela listan."
                    return
                }
                let share: CKShare
                if let existing = persistence.share(for: h) {
                    log("Använder befintlig delning \(existing.recordID.recordName)")
                    share = existing
                } else {
                    log("Skapar ny delning…")
                    let (_, newShare, _) = try await persistence.container.share([h], to: nil)
                    newShare[CKShare.SystemFieldKey.title] = "Inköpslista"
                    try await persistence.container.persistUpdatedShare(newShare, in: persistence.privateStore)
                    log("Delning skapad: \(newShare.url?.absoluteString ?? "ingen url")")
                    share = newShare
                }
                let vc = UICloudSharingController(share: share, container: persistence.ckContainer)
                vc.availablePermissions = [.allowReadWrite, .allowPrivate]
                vc.delegate = shareDelegate
                guard let top = topViewController() else {
                    log("Hittade ingen vy att visa delningen i")
                    errorMessage = "Kunde inte visa delningsrutan."
                    return
                }
                log("Visar delningsruta från \(type(of: top))")
                top.present(vc, animated: true)
            } catch {
                log("Delningsfel: \(error)")
                errorMessage = "Kunde inte dela listan: \(error.localizedDescription)"
            }
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            try await persistence.container.acceptShareInvitations(from: [metadata], into: persistence.sharedStore)
            UserDefaults.standard.set(true, forKey: mergeKey)
            refresh()
        } catch {
            errorMessage = "Kunde inte öppna den delade listan: \(error.localizedDescription)"
        }
    }

    fileprivate func sharingStopped(_ share: CKShare) {
        // Deltagare som lämnar: rensa bort den delade listan lokalt.
        if share.currentUserParticipant != share.owner {
            persistence.container.purgeObjectsAndRecordsInZone(
                with: share.recordID.zoneID, in: persistence.sharedStore) { _, _ in
                Task { @MainActor in AppModel.shared.refresh() }
            }
        } else {
            refresh()
        }
    }

    fileprivate func shareSaved(_ share: CKShare) {
        let store = household?.objectID.persistentStore ?? persistence.privateStore
        persistence.container.persistUpdatedShare(share, in: store, completion: nil)
        refresh()
    }

    // MARK: Hjälpare

    func save() {
        guard ctx.hasChanges else { return }
        do { try ctx.save() } catch {
            ctx.rollback()
            errorMessage = "Kunde inte spara: \(error.localizedDescription)"
        }
    }

    private func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces),
            options: [.caseInsensitive], locale: Locale(identifier: "sv_SE")) == .orderedSame
    }

    private func matches(_ name: String?, _ ean: String?, _ otherName: String, _ otherEan: String?) -> Bool {
        if let ean, let otherEan, ean == otherEan { return true }
        return same(name, otherName)
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

private final class ShareDelegate: NSObject, UICloudSharingControllerDelegate {
    func itemTitle(for csc: UICloudSharingController) -> String? { "Inköpslista" }

    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        log("UICloudSharingController misslyckades: \(error)")
        Task { @MainActor in AppModel.shared.errorMessage = "Delningen misslyckades: \(error.localizedDescription)" }
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        guard let share = csc.share else { return }
        Task { @MainActor in AppModel.shared.shareSaved(share) }
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        guard let share = csc.share else { return }
        Task { @MainActor in AppModel.shared.sharingStopped(share) }
    }
}

func log(_ msg: String) {
    print("[Listigt] \(msg)")
}

// MARK: - Intervall för basvaror

enum Schedule {
    static let options: [(days: Int64, label: String)] = [
        (0, "Varje inköpsrunda"),
        (7, "Varje vecka"),
        (14, "Varannan vecka"),
        (21, "Var tredje vecka"),
        (30, "En gång i månaden"),
        (60, "Varannan månad"),
        (90, "Var tredje månad"),
    ]

    static func label(_ days: Int64) -> String {
        options.first { $0.days == days }?.label ?? "Var \(days):e dag"
    }

    static func nextDate(_ b: BaseItem) -> Date? {
        guard b.intervalDays > 0, let last = b.lastAdded else { return nil }
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: Int(b.intervalDays), to: cal.startOfDay(for: last))
    }

    static func isDue(_ b: BaseItem, now: Date) -> Bool {
        guard b.intervalDays > 0 else { return true }
        guard let next = nextDate(b) else { return true }
        return now >= next
    }

    /// "idag", "imorgon", "om 5 dagar", "om 3 veckor"
    static func describeNext(_ b: BaseItem, now: Date = Date()) -> String? {
        guard let next = nextDate(b) else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: next).day ?? 0
        switch days {
        case ..<1: return "nästa gång: idag"
        case 1: return "nästa gång: imorgon"
        case 2..<14: return "nästa gång: om \(days) dagar"
        default: return "nästa gång: om \(days / 7) veckor"
        }
    }
}
