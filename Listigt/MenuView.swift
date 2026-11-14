import SwiftUI
import CoreData

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @FetchRequest private var dishes: FetchedResults<MenuDish>

    @AppStorage("menu.people") private var people = 2
    @AppStorage("menu.days") private var days = 5
    @AppStorage("menu.dishes") private var dishCount = 5
    @AppStorage("menu.wishes") private var wishes = ""
    /// "" = alla butiker, annars en kedjas rawValue.
    @AppStorage("menu.chain") private var chainRaw = ""

    @State private var hasKey = APIKey.value != nil
    @State private var showSettings = false
    @State private var showKey = false
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
        MenuRequest(people: people, days: days, dishes: min(dishCount, days), wishes: wishes)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dishes.isEmpty && !working {
                    if hasKey { settingsForm(inSheet: false) } else { KeyForm { hasKey = APIKey.value != nil } }
                } else {
                    menuList
                }
            }
            .navigationTitle("Veckomeny")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showKey = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("API-nyckel")
                }
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
            .sheet(isPresented: $showKey) {
                NavigationStack {
                    KeyForm { hasKey = APIKey.value != nil; showKey = false }
                        .navigationTitle("API-nyckel")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Stäng") { hasKey = APIKey.value != nil; showKey = false } }
                }
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
            .task { await offerStore.refreshAll() }
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
                TextField("T.ex. barnvänligt, en vegetarisk, inget fläsk", text: $wishes, axis: .vertical)
                    .lineLimit(1...3)
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
                Text(n > 0 ? "Claude utgår från \(n) erbjudanden \(chain.map { "på \($0.title)" } ?? "hos dina butiker"). Det tar ungefär en halv minut."
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
                        Text("Claude planerar veckans middagar…").foregroundStyle(.secondary)
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

    // MARK: Claude

    private func generate() async {
        working = true
        defer { working = false }
        do {
            let planned = try await MenuPlanner.plan(request, offers: offers)
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
        var req = request
        req.days = Int(d.days)
        req.dishes = 1
        do {
            let others = dishes.compactMap(\.title)
            if let new = try await MenuPlanner.plan(req, offers: offers, avoid: others, single: true).first {
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
                            Text(ing.quantity?.text ?? "efter smak").foregroundStyle(.secondary).monospacedDigit()
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

// MARK: - API-nyckel

private struct KeyForm: View {
    let onSaved: () -> Void
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                Text("Veckomenyn skapas av Claude. Det kräver en API-nyckel från Anthropic. En meny kostar ungefär en krona.")
                Link("Skaffa nyckel på console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
            Section {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Spara nyckel") {
                    APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                    key = ""
                    onSaved()
                }
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(APIKey.value != nil
                     ? "En nyckel är sparad. Klistra in en ny för att byta."
                     : "Nyckeln sparas bara i nyckelringen på den här telefonen. Menyn delas ändå med alla som delar listan.")
            }
            if APIKey.value != nil {
                Section {
                    Button("Ta bort nyckel", role: .destructive) { APIKey.save(nil); onSaved() }
                }
            }
        }
    }
}
