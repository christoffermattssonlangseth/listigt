import SwiftUI
import CoreData

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @FetchRequest private var dishes: FetchedResults<MenuDish>

    @AppStorage("menu.people") private var people = 2
    @AppStorage("menu.days") private var days = 5
    @AppStorage("menu.dishes") private var dishCount = 5
    @AppStorage("menu.quick") private var quick = false
    @AppStorage("menu.vegetarian") private var vegetarian = false
    /// "" = alla butiker, annars en kedjas rawValue.
    @AppStorage("menu.chain") private var chainRaw = ""

    @State private var showSettings = false
    @State private var working = false
    @State private var replacing: NSManagedObjectID?
    @State private var error: String?
    @State private var open: MenuDish?
    @State private var toast: String?

    init(household: Household) {
        _dishes = FetchRequest(sortDescriptors: [NSSortDescriptor(key: "order", ascending: true)],
                               predicate: NSPredicate(format: "household == %@", household), animation: .default)
    }

    private var chain: Chain? { Chain(rawValue: chainRaw) }
    private var offers: [Offer] { MenuPlanner.foodOffers(from: chain) }

    private var request: MenuRequest {
        MenuRequest(people: people, days: days, dishes: min(dishCount, days), quick: quick, vegetarian: vegetarian)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dishes.isEmpty && !working {
                    settingsForm(inSheet: false)
                } else {
                    menuList
                }
            }
            .navigationTitle("Veckomeny")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !dishes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Ny meny") { showSettings = true }.disabled(working)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    settingsForm(inSheet: true)
                        .navigationTitle("Ny veckomeny")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Avbryt") { showSettings = false } }
                }
                .presentationDetents([.large])
            }
            .sheet(item: $open) { d in
                DishDetail(dish: d, replacing: replacing == d.objectID,
                           onAdd: { pantry in
                               let n = model.addIngredients(of: [d], includePantry: pantry)
                               show("\(n) varor lagda på listan")
                           },
                           onReplace: { open = nil; Task { await replace(d) } })
            }
            .alert("Det gick inte", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .overlay(alignment: .bottom) { ToastText(text: toast) }
            .task {
                await offerStore.refreshAll()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-planMenu") {
                    await generate()
                    for d in dishes {
                        log("RÄTT \(d.title ?? "") – \(d.days) d, \(d.servings) port, \(d.minutes) min")
                        for i in d.ingredients { log("   \(i.name) | \(i.amountText)\(i.pantry ? " [skafferi]" : "")\(i.offer.isEmpty ? "" : " 🏷️ " + i.offer)") }
                    }
                }
                #endif
            }
        }
    }

    // MARK: Inställningar

    private func settingsForm(inSheet: Bool) -> some View {
        Form {
            Section {
                Stepper("Personer: \(people)", value: $people, in: 1...10)
                Stepper("Middagar: \(days)", value: $days, in: 1...7)
                Stepper("Olika rätter: \(min(dishCount, days))", value: $dishCount, in: 1...days)
            } footer: {
                if dishCount < days {
                    Text("Färre rätter än middagar: vissa lagas i större sats och räcker flera dagar.")
                }
            }
            Section {
                Picker("Handla på", selection: $chainRaw) {
                    Text("Alla mina butiker").tag("")
                    ForEach(Chain.allCases) { c in
                        Text(offerStore.stores[c].map { "\(c.title) – \($0.name)" } ?? "\(c.title) (ingen butik vald)")
                            .tag(c.rawValue)
                    }
                }
            } header: {
                Text("Butik")
            } footer: {
                if let chain, offerStore.stores[chain] == nil {
                    Text("Välj en \(chain.title)-butik under Erbjudanden först.")
                }
            }
            Section("Önskemål") {
                Toggle("Snabba rätter (max 30 min)", isOn: $quick)
                Toggle("Vegetariskt", isOn: $vegetarian)
            }
            Section {
                Button {
                    showSettings = false
                    Task { await generate() }
                } label: {
                    Label("Skapa veckomeny", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .disabled(working)
            } footer: {
                let n = offers.count
                Text(n > 0 ? "Recepten kommer från ICA och väljs efter \(n) erbjudanden \(chain.map { "på \($0.title)" } ?? "hos dina butiker")."
                           : "Inga erbjudanden hämtade – välj butiker under Erbjudanden för billigare förslag.")
            }
        }
    }

    // MARK: Menyn

    private var menuList: some View {
        List {
            if working && replacing == nil {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Letar recept med veckans erbjudanden…").foregroundStyle(.secondary)
                    }
                }
            }
            if !dishes.isEmpty {
                Section {
                    ForEach(dishes) { d in
                        Button { open = d } label: { DishRow(dish: d, busy: replacing == d.objectID) }
                            .tint(.primary)
                            .swipeActions {
                                Button { Task { await replace(d) } } label: {
                                    Label("Byt", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
                            }
                    }
                } footer: {
                    Text("Tryck på en rätt för recept. Svep för att byta ut den.")
                }
                Section {
                    Button { Task { await generate() } } label: {
                        Label("Slumpa nya recept", systemImage: "dice")
                    }
                    .disabled(working)
                    Button {
                        let n = model.addIngredients(of: Array(dishes))
                        show("\(n) varor lagda på listan")
                    } label: {
                        Label("Lägg alla ingredienser på listan", systemImage: "cart.badge.plus")
                    }
                } footer: {
                    Text("Salt, olja, kryddor och annat som brukar finnas hemma tas inte med. Det kan du lägga till inne i varje recept.")
                }
            }
        }
    }

    // MARK: Planering

    private func generate() async {
        working = true
        defer { working = false }
        do {
            let days = MenuPlanner.split(days: request.days, into: request.dishes)
            // Undvik recepten i nuvarande meny; räcker det inte får de vara med igen.
            let current = Set(dishes.map { Int($0.recipeId) })
            var planned = (try? await MenuPlanner.plan(request, offers: offers, days: days, avoid: current)) ?? []
            if planned.count < days.count {
                planned = try await MenuPlanner.plan(request, offers: offers, days: days)
            }
            model.replaceMenu(with: planned)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replace(_ d: MenuDish) async {
        guard !working else { return }
        working = true
        replacing = d.objectID
        defer { working = false; replacing = nil }
        do {
            let avoid = Set(dishes.map { Int($0.recipeId) })
            if let new = try await MenuPlanner.plan(request, offers: offers, days: [Int(d.days)], avoid: avoid).first {
                model.replaceDish(d, with: new)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}

// MARK: - Rad och recept

private struct DishRow: View {
    @ObservedObject var dish: MenuDish
    let busy: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(dish.title ?? "").font(.body.weight(.medium))
                if let info = dish.info, !info.isEmpty {
                    Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    if dish.offerCount > 0 {
                        Label("\(dish.offerCount) på erbjudande", systemImage: "tag.fill").foregroundStyle(.green)
                    }
                    if dish.minutes > 0 { Label("\(dish.minutes) min", systemImage: "clock") }
                    if dish.days > 1 { Label("\(dish.days) dagar", systemImage: "calendar") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView() }
        }
        .padding(.vertical, 2)
    }
}

private struct DishDetail: View {
    @ObservedObject var dish: MenuDish
    let replacing: Bool
    let onAdd: (_ includePantry: Bool) -> Void
    let onReplace: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let img = dish.imageURL.flatMap(URL.init(string:)) {
                        AsyncImage(url: img) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .listRowInsets(EdgeInsets())
                    }
                    if let info = dish.info, !info.isEmpty { Text(info) }
                    HStack(spacing: 14) {
                        Label("\(dish.servings) portioner", systemImage: "person.2")
                        if dish.minutes > 0 { Label("\(dish.minutes) min", systemImage: "clock") }
                        if dish.days > 1 { Label("\(dish.days) dagar", systemImage: "calendar") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ingredienser") {
                    ForEach(dish.ingredients, id: \.self) { ing in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ing.name).foregroundStyle(ing.pantry ? .secondary : .primary)
                                if !ing.offer.isEmpty {
                                    Text("🏷️ \(ing.offer)").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            Text(ing.amountText).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Section {
                    Button { onAdd(false); dismiss() } label: {
                        Label("Lägg ingredienserna på listan", systemImage: "cart.badge.plus")
                    }
                    if dish.ingredients.contains(where: \.pantry) {
                        Button { onAdd(true); dismiss() } label: {
                            Label("…inklusive skafferivaror", systemImage: "cart.badge.plus")
                        }
                    }
                } footer: {
                    Text("Gråa ingredienser brukar finnas hemma.")
                }
                Section("Gör så här") {
                    ForEach(Array(dish.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1).").font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
                Section {
                    if let url = dish.url.flatMap(URL.init(string:)) {
                        Link(destination: url) { Label("Visa receptet på ica.se", systemImage: "safari") }
                    }
                    Button(action: onReplace) {
                        Label("Byt ut rätten", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(replacing)
                }
            }
            .navigationTitle(dish.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Klar") { dismiss() } }
        }
    }
}
