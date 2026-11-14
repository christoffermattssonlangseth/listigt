import SwiftUI
import CoreData

// MARK: - Köptillfällen och mest köpta, räknat ur avbockningarna

enum PurchaseHistory {
    /// Allt som bockas av inom två timmar från tillfällets första vara hör till samma köptillfälle.
    static let tripWindow: TimeInterval = 2 * 3600

    struct Trip: Identifiable {
        var id: Date { start }
        let start: Date
        var end: Date
        var purchases: [Purchase]
    }

    struct Frequent: Identifiable {
        var id: String { key }
        let key: String
        var name: String
        var trips: Int
        var last: Date
        var quantity: Quantity
    }

    /// Nyaste tillfället först.
    static func trips(_ purchases: [Purchase]) -> [Trip] {
        var trips: [Trip] = []
        for p in purchases.sorted(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
            guard let d = p.date else { continue }
            if let last = trips.last, d.timeIntervalSince(last.start) <= tripWindow {
                trips[trips.count - 1].purchases.append(p)
                trips[trips.count - 1].end = d
            } else {
                trips.append(Trip(start: d, end: d, purchases: [p]))
            }
        }
        return trips.reversed()
    }

    /// Varor sorterade efter hur många köptillfällen de varit med i.
    static func frequent(_ purchases: [Purchase]) -> [Frequent] {
        var byKey: [String: Frequent] = [:]
        for trip in trips(purchases).reversed() {           // äldst först, så senaste namnet/mängden vinner
            var seen = Set<String>()
            for p in trip.purchases {
                guard let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                let key = name.lowercased()
                let date = p.date ?? trip.start
                if var f = byKey[key] {
                    if !seen.contains(key) { f.trips += 1 }
                    f.name = name; f.last = date; f.quantity = p.quantity
                    byKey[key] = f
                } else {
                    byKey[key] = Frequent(key: key, name: name, trips: 1, last: date, quantity: p.quantity)
                }
                seen.insert(key)
            }
        }
        return byKey.values.sorted { ($0.trips, $0.last) > ($1.trips, $1.last) }
    }

    static func relative(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "idag" }
        if cal.isDateInYesterday(d) { return "igår" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "i " + d.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "sv_SE"))) + "s" }
        return d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "sv_SE")))
    }
}

// MARK: - Fliken "Mina varor"

struct MyItemsView: View {
    let household: Household
    @AppStorage("myItems.section") private var section = 0

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case 1: FrequentView(household: household)
                case 2: HistoryView(household: household)
                default: BaseListView(household: household)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Visa", selection: $section) {
                    Text("Basvaror").tag(0)
                    Text("Ofta köpta").tag(1)
                    Text("Historik").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Mina varor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { ShareButton() } }
        }
    }
}

// MARK: - Ofta köpta

private struct FrequentView: View {
    @EnvironmentObject private var model: AppModel
    @FetchRequest private var purchases: FetchedResults<Purchase>
    @FetchRequest private var bases: FetchedResults<BaseItem>
    @FetchRequest private var items: FetchedResults<ShopItem>
    @State private var toast: String?

    init(household: Household) {
        let pred = NSPredicate(format: "household == %@", household)
        _purchases = FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)], predicate: pred)
        _bases = FetchRequest(sortDescriptors: [], predicate: pred)
        _items = FetchRequest(sortDescriptors: [], predicate: pred)
    }

    var body: some View {
        let all = PurchaseHistory.frequent(Array(purchases))
        let others = all.filter { !model.isBase($0.name) }
        List {
            if all.isEmpty {
                Section {
                    Text("Här visas det ni köper oftast. Varor räknas när de bockas av på inköpslistan – av alla som delar listan.")
                        .foregroundStyle(.secondary)
                }
            } else if others.isEmpty {
                Section { Text("Allt ni köpt ofta finns redan bland basvarorna. 👍").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(others) { f in
                        let onList = model.openItem(named: f.name, ean: nil) != nil
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name)
                                Text("Köpt \(f.trips) \(f.trips == 1 ? "gång" : "gånger") · senast \(PurchaseHistory.relative(f.last))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.addItem(f.name, quantity: f.quantity)
                                show("\(f.name) tillagd på listan")
                            } label: {
                                Image(systemName: onList ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(onList ? Color.secondary : Color.accentColor)
                            }
                            .buttonStyle(.borderless)
                            .disabled(onList)
                            .accessibilityLabel(onList ? "Står redan på listan" : "Lägg till i listan")
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                show(model.addBase(f.name, quantity: f.quantity.isOne ? nil : f.quantity)
                                     ?? "\(f.name) är nu en basvara")
                            } label: { Label("Basvara", systemImage: "star") }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                show(model.addBase(f.name, quantity: f.quantity.isOne ? nil : f.quantity)
                                     ?? "\(f.name) är nu en basvara")
                            } label: { Label("Gör till basvara", systemImage: "star") }
                        }
                    }
                } footer: {
                    Text("Svep åt höger eller håll inne för att göra en vara till basvara.")
                }
            }
        }
        .overlay(alignment: .bottom) { ToastView(text: toast) }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}

// MARK: - Historik

private struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @FetchRequest private var purchases: FetchedResults<Purchase>
    let household: Household

    init(household: Household) {
        self.household = household
        _purchases = FetchRequest(sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)],
                                  predicate: NSPredicate(format: "household == %@", household))
    }

    var body: some View {
        let trips = PurchaseHistory.trips(Array(purchases))
        List {
            if trips.isEmpty {
                Section {
                    Text("Varje gång ni handlar sparas här. Allt som bockas av inom två timmar räknas som samma köptillfälle.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(trips) { t in
                NavigationLink {
                    TripDetailView(household: household, start: t.start)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TripDetailView.title(t.start)).font(.body.weight(.medium))
                        Text("\(timeRange(t)) · \(t.purchases.count) \(t.purchases.count == 1 ? "vara" : "varor")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { model.deletePurchases(t.purchases) } label: {
                        Label("Ta bort", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func timeRange(_ t: PurchaseHistory.Trip) -> String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "sv_SE"))
        let a = t.start.formatted(f), b = t.end.formatted(f)
        return a == b ? a : "\(a)–\(b)"
    }
}

private struct TripDetailView: View {
    @EnvironmentObject private var model: AppModel
    @FetchRequest private var purchases: FetchedResults<Purchase>
    let start: Date
    @State private var toast: String?

    init(household: Household, start: Date) {
        self.start = start
        _purchases = FetchRequest(
            sortDescriptors: [NSSortDescriptor(key: "date", ascending: true)],
            predicate: NSPredicate(format: "household == %@ AND date >= %@ AND date <= %@", household,
                                   start as NSDate, start.addingTimeInterval(PurchaseHistory.tripWindow) as NSDate))
    }

    static func title(_ d: Date) -> String {
        let s = d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "sv_SE")))
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    var body: some View {
        List {
            ForEach(model.grouped(Array(purchases), name: \.name), id: \.0) { cat, group in
                Section(cat.label) {
                    ForEach(group) { p in
                        HStack {
                            Text(p.name ?? "")
                            Spacer()
                            if !p.quantity.isOne {
                                Text(p.quantity.text).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .onDelete { model.deletePurchases($0.map { group[$0] }) }
                }
            }
            if !purchases.isEmpty {
                Section {
                    Button {
                        for p in purchases where model.openItem(named: p.name, ean: p.ean) == nil {
                            model.addItem(p.name ?? "", ean: p.ean, quantity: p.quantity)
                        }
                        show("Lagt på inköpslistan")
                    } label: {
                        Label("Lägg allt på inköpslistan igen", systemImage: "cart.badge.plus")
                    }
                }
            }
        }
        .navigationTitle(Self.title(start))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { ToastView(text: toast) }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}
