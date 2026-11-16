import SwiftUI
import CoreData

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = ProcessInfo.processInfo.arguments.contains("-baseTab") ? 1
        : ProcessInfo.processInfo.arguments.contains("-offersTab") ? 2
        : ProcessInfo.processInfo.arguments.contains("-menuTab") ? 3 : 0

    var body: some View {
        Group {
            if let h = model.household {
                TabView(selection: $tab) {
                    ShoppingListView(household: h)
                        .tabItem { Label("Inköpslista", systemImage: "cart") }
                        .tag(0)
                    MyItemsView(household: h)
                        .tabItem { Label("Mina varor", systemImage: "star") }
                        .tag(1)
                    MenuView(household: h)
                        .tabItem { Label("Veckomeny", systemImage: "fork.knife") }
                        .tag(3)
                    OffersView()
                        .tabItem { Label("Erbjudanden", systemImage: "tag") }
                        .tag(2)
                }
                .id(h.objectID)
            } else {
                ProgressView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.removeFinishedTripItems()
                model.addDueBaseItems()
                Task { await OfferStore.shared.refreshAll() }
            }
        }
        .task {
            // Städa även medan appen står öppen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                model.removeFinishedTripItems()
            }
        }
        .alert("Något gick fel", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Inmatningsrad

private struct AddRow: View {
    let placeholder: String
    @Binding var text: String
    /// Retur: lägg till direkt.
    let onSubmit: () -> Void
    /// Plusknappen: öppna produktkortet.
    let onDetails: () -> Void
    let onScan: () -> Void
    var suggestions: [String] = []
    @FocusState private var focused: Bool

    private var matching: [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return [] }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(t) && $0.lowercased() != t.lowercased() }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit {
                        // Retur lägger till direkt och låter en skriva nästa vara. Tom rad stänger tangentbordet.
                        if text.trimmingCharacters(in: .whitespaces).isEmpty { focused = false }
                        else { onSubmit(); focused = true }
                    }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Klar") { focused = false }
                        }
                    }
                Button(action: { focused = false; onDetails() }) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .accessibilityLabel("Lägg till med mängd och kategori")
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(action: onScan) {
                    Image(systemName: "barcode.viewfinder").font(.title2)
                }
                .accessibilityLabel("Scanna streckkod")
            }
            .buttonStyle(.borderless)

            if !matching.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(matching, id: \.self) { s in
                            Button(s) { text = s; onSubmit() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lista A: Inköpslista

struct ShoppingListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @FetchRequest private var items: FetchedResults<ShopItem>
    let household: Household

    @State private var text = ""
    @State private var scanning = false
    @State private var pendingEan: String?
    @State private var toast: String?
    @State private var draft: Draft?

    init(household: Household) {
        self.household = household
        _items = FetchRequest(
            sortDescriptors: [NSSortDescriptor(key: "created", ascending: false),
                              NSSortDescriptor(key: "name", ascending: true)],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default)
    }

    private var toBuy: [ShopItem] { items.filter { !$0.checked } }
    private var inCart: [ShopItem] { items.filter(\.checked) }

    private var suggestions: [String] {
        Array(Set((household.baseItems ?? []).compactMap(\.name) + (household.eanNames ?? []).compactMap(\.name)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AddRow(placeholder: "Lägg till vara…", text: $text, onSubmit: quickAdd,
                           onDetails: submit, onScan: { scanning = true }, suggestions: suggestions)
                }

                if toBuy.isEmpty {
                    Section {
                        Text(inCart.isEmpty ? "Listan är tom." : "Allt är i korgen! 🎉")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.grouped(toBuy, name: \.name), id: \.0) { cat, group in
                    Section(cat.label) {
                        ForEach(group) { it in ItemRow(item: it).contextMenu { CategoryMenu(name: it.name) } }
                            .onDelete { model.delete($0.map { group[$0] }) }
                    }
                }

                if !inCart.isEmpty {
                    Section("I korgen (\(inCart.count))") {
                        ForEach(inCart) { it in ItemRow(item: it).contextMenu { CategoryMenu(name: it.name) } }
                            .onDelete { model.delete($0.map { inCart[$0] }) }
                    }
                }
            }
            .navigationTitle("Inköpslista")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ShareButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            let n = model.newRound()
                            show(n == 0 ? "Alla basvaror finns redan på listan"
                                        : "\(n) basvar\(n == 1 ? "a" : "or") tillagd\(n == 1 ? "" : "a")")
                        } label: {
                            Label("Ny inköpsrunda", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) { model.clearChecked() } label: {
                            Label("Ta bort avbockade", systemImage: "checkmark.circle.badge.xmark")
                        }
                        .disabled(inCart.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !inCart.isEmpty && toBuy.isEmpty {
                    Button {
                        let n = model.newRound()
                        show(n == 0 ? "Klart!" : "Ny runda – \(n) basvaror tillagda")
                    } label: {
                        Label("Ny inköpsrunda", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                }
            }
            .overlay(alignment: .bottom) { ToastView(text: toast) }
            #if DEBUG
            .task {
                if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-scanTest"),
                   i + 1 < ProcessInfo.processInfo.arguments.count {
                    try? await Task.sleep(for: .seconds(1))
                    pendingEan = ProcessInfo.processInfo.arguments[i + 1]
                }
            }
            #endif
            .scanFlow(isScanning: $scanning, ean: $pendingEan) { e, ean in
                model.addItem(e.name, ean: ean, quantity: e.quantity)
                show("\(e.name) tillagd")
            }
            .sheet(item: $draft) { d in
                ProductSheet(
                    initial: d.edit,
                    saveLabel: "Lägg till",
                    showDelete: false,
                    message: model.openItem(named: d.edit.name, ean: nil).map {
                        "Står redan på listan (\($0.quantity.text)) – mängden läggs till."
                    },
                    categoryFor: { model.category(for: $0) },
                    offers: offerStore.matches(for: d.edit.name),
                    onSave: { e in
                        model.remember(category: e.category, for: e.name)
                        model.addItem(e.name, quantity: e.quantity)
                        show("\(e.name) tillagd")
                    },
                    onDelete: {})
            }
        }
    }

    private func submit() {
        let v = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !v.isEmpty else { return }
        if EAN.isValid(v) { pendingEan = v; return }
        let parsed = QuantityParser.parse(v)
        draft = Draft(edit: ProductEdit(name: parsed.name, quantity: parsed.quantity ?? .one,
                                        category: model.category(for: parsed.name), intervalDays: nil))
    }

    private func quickAdd() {
        let v = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !v.isEmpty else { return }
        if EAN.isValid(v) { pendingEan = v; return }
        let parsed = QuantityParser.parse(v)
        model.addItem(parsed.name, quantity: parsed.quantity)
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}

private struct ItemRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @ObservedObject var item: ShopItem
    @State private var editing = false

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation { model.toggle(item) } } label: {
                Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(item.checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.checked ? "Avbockad" : "Bocka av")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name ?? "")
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? .secondary : .primary)
                    if item.fromBase {
                        Text("bas")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if !item.checked, let o = offerStore.matches(for: item.name).first {
                    Text("🏷️ \(o.chain.title) \(o.priceText)\(o.memberOnly ? " · \(o.chain.memberLabel)" : "")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(o.chain.color)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = true }

            if !item.checked {
                let q = item.quantity
                HStack(spacing: 6) {
                    Button { model.step(item, -1) } label: { Image(systemName: "minus.circle") }
                        .disabled(q.amount <= q.unit.step)
                        .font(.title3)
                    Button { editing = true } label: {
                        Text(q.unit == .st ? Quantity.format(q.amount) : q.text)
                            .monospacedDigit()
                            .frame(minWidth: 24)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Mängd \(q.text), tryck för att ändra")
                    Button { model.step(item, 1) } label: { Image(systemName: "plus.circle") }
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            } else if !item.quantity.isOne {
                Text(item.quantity.text).foregroundStyle(.secondary)
            }
        }
        #if DEBUG
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-openItem"), i + 1 < args.count, item.name == args[i + 1] { editing = true }
        }
        #endif
        .sheet(isPresented: $editing) {
            ProductSheet(
                initial: ProductEdit(name: item.name ?? "", quantity: item.quantity,
                                     category: model.category(for: item.name), intervalDays: nil),
                ean: item.ean,
                offers: offerStore.matches(for: item.name),
                onSave: { model.update(item, with: $0) },
                onDelete: { model.delete([item]) })
        }
    }
}

/// En inskriven vara som väntar på att bekräftas i produktkortet.
struct Draft: Identifiable {
    let id = UUID()
    var edit: ProductEdit
}

struct ProductEdit {
    var name: String
    var quantity: Quantity
    /// nil vid sparande = kategorin ändrades inte (gissas då från namnet).
    var category: ItemCategory?
    var intervalDays: Int64?
}

/// Produktkort: ändra namn, mängd, kategori (och intervall för basvaror).
struct ProductSheet: View {
    let initial: ProductEdit
    var ean: String? = nil
    var deleteLabel = "Ta bort från listan"
    var saveLabel = "Spara"
    var showDelete = true
    /// Informationsrad överst (t.ex. "Streckkoden hittades inte").
    var message: String? = nil
    /// Föreslår kategori medan namnet skrivs, tills användaren själv väljer.
    var categoryFor: ((String) -> ItemCategory)? = nil
    /// Aktuella erbjudanden som gäller varan.
    var offers: [Offer] = []
    let onSave: (ProductEdit) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amountText = ""
    @State private var unit = MeasureUnit.st
    @State private var category = ItemCategory.ovrigt
    @State private var interval: Int64 = 0
    @State private var confirmDelete = false
    @State private var categoryTouched = false

    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil }
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func stepAmount(_ direction: Double) {
        let current = Quantity(amount: amount ?? 0, unit: unit)
        amountText = Quantity.format(current.stepped(direction).amount)
    }

    /// Byter enhet; från ett litet tal till g/ml blir det ett rimligt startvärde.
    private func changeUnit(to u: MeasureUnit) {
        unit = u
        if (amount ?? 0) < u.step { amountText = Quantity.format(u.defaultAmount) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let message {
                    Section { Label(message, systemImage: "info.circle").font(.subheadline) }
                }
                Section("Namn") {
                    TextField("Vad heter varan?", text: $name)
                        .font(.title3)
                        .onChange(of: name) { _, n in
                            if !categoryTouched, let categoryFor { category = categoryFor(n) }
                        }
                }

                Section {
                    HStack(spacing: 16) {
                        Button { stepAmount(-1) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 34))
                        }
                        .disabled((amount ?? 0) <= unit.step)
                        .accessibilityLabel("Minska")
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            TextField("Mängd", text: $amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.title2.monospacedDigit().weight(.semibold))
                                .frame(width: 90)
                            Text(unit.label).font(.title2).foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                        Button { stepAmount(1) } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 34))
                        }
                        .accessibilityLabel("Öka")
                    }
                    .buttonStyle(.borderless)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(MeasureUnit.allCases) { u in
                            Button { changeUnit(to: u) } label: {
                                Text(u.label)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(u == unit ? Color.accentColor : Color.secondary.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(u == unit ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Mängd")
                }

                Section {
                    Picker("Kategori", selection: Binding(
                        get: { category }, set: { category = $0; categoryTouched = true })) {
                        ForEach(ItemCategory.allCases) { Text($0.label).tag($0) }
                    }
                    if initial.intervalDays != nil {
                        Picker("Hur ofta", selection: $interval) {
                            ForEach(Schedule.options, id: \.days) { Text($0.label).tag($0.days) }
                        }
                    }
                } footer: {
                    if let ean {
                        Label(ean, systemImage: "barcode")
                            .font(.footnote.monospacedDigit())
                            .padding(.top, 8)
                    }
                }

                if !offers.isEmpty {
                    Section("Erbjudanden") {
                        ForEach(offers) { OfferDetail(offer: $0) }
                    }
                }

                if showDelete {
                    Section {
                        Button(deleteLabel, role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(initial.name.isEmpty ? "Ny vara" : initial.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel) {
                        if let amount {
                            onSave(ProductEdit(name: trimmedName, quantity: Quantity(amount: amount, unit: unit),
                                               category: categoryTouched ? category : nil,
                                               intervalDays: initial.intervalDays == nil ? nil : interval))
                        }
                        dismiss()
                    }
                    .bold()
                    .disabled(amount == nil || trimmedName.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Klar") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            }
            .confirmationDialog("Ta bort \(initial.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(deleteLabel, role: .destructive) { onDelete(); dismiss() }
            }
            .onAppear {
                name = initial.name
                amountText = Quantity.format(initial.quantity.amount)
                unit = initial.quantity.unit
                category = initial.category ?? .ovrigt
                interval = initial.intervalDays ?? 0
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Lista B: Basvaror

struct BaseListView: View {
    @EnvironmentObject private var model: AppModel
    @FetchRequest private var bases: FetchedResults<BaseItem>

    @State private var text = ""
    @State private var scanning = false
    @State private var draft: Draft?
    @State private var pendingEan: String?
    @State private var toast: String?

    init(household: Household) {
        _bases = FetchRequest(
            sortDescriptors: [NSSortDescriptor(key: "name", ascending: true,
                                               selector: #selector(NSString.localizedCaseInsensitiveCompare))],
            predicate: NSPredicate(format: "household == %@", household),
            animation: .default)
    }

    var body: some View {
            List {
                Section {
                    AddRow(placeholder: "Ny basvara…", text: $text, onSubmit: quickAdd, onDetails: submit, onScan: { scanning = true })
                } footer: {
                    Text("Retur lägger till direkt, ＋ öppnar kortet med mängd och intervall. Basvaror läggs automatiskt på inköpslistan. Tryck på intervallet för att välja hur ofta. Håll inne en vara för att byta kategori.")
                }

                ForEach(model.grouped(Array(bases), name: \.name), id: \.0) { cat, group in
                    Section(cat.label) {
                        ForEach(group) { b in BaseRow(base: b).contextMenu { CategoryMenu(name: b.name) } }
                            .onDelete { model.deleteBase($0.map { group[$0] }) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if !bases.isEmpty { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            }
            .overlay(alignment: .bottom) { ToastView(text: toast) }
            .scanFlow(isScanning: $scanning, ean: $pendingEan, forBase: true) { e, ean in
                show(model.addBase(e.name, ean: ean, intervalDays: e.intervalDays ?? 0, quantity: e.quantity)
                     ?? "\(e.name) tillagd som basvara")
            }
            .sheet(item: $draft) { d in
                ProductSheet(
                    initial: d.edit,
                    saveLabel: "Lägg till",
                    showDelete: false,
                    categoryFor: { model.category(for: $0) },
                    onSave: { e in
                        model.remember(category: e.category, for: e.name)
                        show(model.addBase(e.name, intervalDays: e.intervalDays ?? 0, quantity: e.quantity)
                             ?? "\(e.name) tillagd som basvara")
                    },
                    onDelete: {})
            }
    }

    private func submit() {
        let v = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !v.isEmpty else { return }
        if EAN.isValid(v) { pendingEan = v; return }
        let parsed = QuantityParser.parse(v)
        draft = Draft(edit: ProductEdit(name: parsed.name, quantity: parsed.quantity ?? .one,
                                        category: model.category(for: parsed.name), intervalDays: 0))
    }

    private func quickAdd() {
        let v = text.trimmingCharacters(in: .whitespaces)
        text = ""
        guard !v.isEmpty else { return }
        if EAN.isValid(v) { pendingEan = v; return }
        let parsed = QuantityParser.parse(v)
        if let msg = model.addBase(parsed.name, quantity: parsed.quantity) { show(msg) }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}

private struct BaseRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @ObservedObject var base: BaseItem
    @State private var editing = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(base.name ?? "")
                    Button { editing = true } label: {
                        Text(base.quantity.isOne ? "1 st" : base.quantity.text)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Mängd \(base.quantity.text), tryck för att ändra")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            Menu {
                Picker("Hur ofta", selection: Binding(
                    get: { base.intervalDays },
                    set: { model.setInterval(base, days: $0) })) {
                    ForEach(Schedule.options, id: \.days) { Text($0.label).tag($0.days) }
                }
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(Schedule.label(base.intervalDays))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline)
                    if let next = Schedule.describeNext(base) {
                        Text(next).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            ProductSheet(
                initial: ProductEdit(name: base.name ?? "", quantity: base.quantity,
                                     category: model.category(for: base.name), intervalDays: base.intervalDays),
                ean: base.ean,
                deleteLabel: "Ta bort basvara",
                offers: offerStore.matches(for: base.name),
                onSave: { model.update(base, with: $0) },
                onDelete: { model.deleteBase([base]) })
        }
    }
}

private struct CategoryMenu: View {
    @EnvironmentObject private var model: AppModel
    let name: String?
    var body: some View {
        Menu {
            Picker("Kategori", selection: Binding(
                get: { model.category(for: name) },
                set: { model.setCategory($0, for: name) })) {
                ForEach(ItemCategory.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Kategori: \(model.category(for: name).title)", systemImage: "tag")
        }
    }
}

// MARK: - Småbitar

struct ShareButton: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Button { model.presentSharing() } label: {
            if model.preparingShare {
                ProgressView()
            } else {
                Image(systemName: model.isShared ? "person.2.fill" : "person.crop.circle.badge.plus")
            }
        }
        .disabled(model.preparingShare)
        .accessibilityLabel(model.isShared ? "Hantera delning" : "Dela listan")
    }
}

struct ToastView: View {
    let text: String?
    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thickMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
