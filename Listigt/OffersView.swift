import SwiftUI

struct OffersView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var offerStore: OfferStore
    @AppStorage("offers.chain") private var chainRaw = Chain.willys.rawValue
    @State private var search = ""
    @State private var onlyMyList = false
    @State private var pick: Offer?
    @State private var choosingStore = false
    @State private var toast: String?

    private var chain: Chain { Chain(rawValue: chainRaw) ?? .willys }

    private var visibleOffers: [Offer] {
        var list = offerStore.offers[chain] ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.brand ?? "").localizedCaseInsensitiveContains(q) }
        }
        if onlyMyList {
            let names = (model.household?.items ?? []).filter { !$0.checked }.compactMap(\.name)
                + (model.household?.baseItems ?? []).compactMap(\.name)
            list = list.filter { o in names.contains { OfferMatcher.matches(item: $0, offer: o.name) } }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store = offerStore.stores[chain] {
                    offersList(store)
                } else {
                    StorePicker(chain: chain) { offerStore.select($0) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Kedja", selection: $chainRaw) {
                    ForEach(Chain.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Erbjudanden")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosingStore) {
                NavigationStack {
                    StorePicker(chain: chain) { offerStore.select($0); choosingStore = false }
                        .navigationTitle("Välj \(chain.title)-butik")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Avbryt") { choosingStore = false } }
                }
            }
            .sheet(item: $pick) { o in
                ProductSheet(
                    initial: ProductEdit(name: o.name, quantity: .one,
                                         category: model.category(for: o.name), intervalDays: nil),
                    saveLabel: "Lägg till",
                    showDelete: false,
                    categoryFor: { model.category(for: $0) },
                    offers: [o],
                    onSave: { e in
                        if let c = e.category, c != model.category(for: e.name) { model.setCategory(c, for: e.name) }
                        model.addItem(e.name, quantity: e.quantity)
                        show("\(e.name) tillagd")
                    },
                    onDelete: {})
            }
            .overlay(alignment: .bottom) { ToastText(text: toast) }
            .task(id: chainRaw) { await offerStore.refresh(chain) }
        }
    }

    @ViewBuilder
    private func offersList(_ store: Store) -> some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.name).font(.headline)
                        Text(store.address).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Byt butik") { choosingStore = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Toggle("Bara varor på mina listor", isOn: $onlyMyList)
            }

            if let error = offerStore.errors[chain], (offerStore.offers[chain] ?? []).isEmpty {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else if offerStore.loading.contains(chain) && (offerStore.offers[chain] ?? []).isEmpty {
                Section { HStack { Spacer(); ProgressView("Hämtar erbjudanden…"); Spacer() } }
            } else if visibleOffers.isEmpty {
                Section {
                    Text(onlyMyList ? "Inget på dina listor är på extrapris just nu." : "Inga erbjudanden hittades.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.grouped(visibleOffers, name: \.name), id: \.0) { cat, group in
                Section(cat.label) {
                    ForEach(group) { o in
                        OfferRow(offer: o, onList: model.openItem(named: o.name, ean: nil) != nil) { pick = o }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Sök bland erbjudanden")
        .refreshable { await offerStore.refresh(chain, force: true) }
    }

    private func show(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { if toast == msg { toast = nil } }
        }
    }
}

// MARK: - Rad

private struct OfferRow: View {
    let offer: Offer
    let onList: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: offer.imageURL) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.secondary.opacity(0.08)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(offer.name).font(.body.weight(.medium))
                if !offer.detail.isEmpty {
                    Text(offer.detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(offer.priceText)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(offer.chain.color, in: RoundedRectangle(cornerRadius: 5))
                    if offer.memberOnly {
                        Text(offer.chain.memberLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(offer.chain.color)
                    }
                }
                let sub = [offer.saveText, offer.ordinaryPrice.map { "Ord. \($0)" }, offer.comparePrice.map { "Jfr \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onAdd) {
                Image(systemName: onList ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(onList ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(onList ? "Står redan på listan" : "Lägg till i listan")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detaljer i produktkortet

struct OfferDetail: View {
    let offer: Offer
    @State private var showAllVariants = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: offer.imageURL) { img in img.resizable().scaledToFit() }
                    placeholder: { Color.secondary.opacity(0.08) }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(offer.chain.title)\(offer.storeName.map { " · \($0)" } ?? "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(offer.chain.color)
                    Text(offer.name).font(.body.weight(.medium))
                    if !offer.detail.isEmpty {
                        Text(offer.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(offer.priceText)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(offer.chain.color, in: RoundedRectangle(cornerRadius: 5))
                        if offer.memberOnly {
                            Text(offer.chain.memberLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(offer.chain.color)
                        }
                    }
                }
            }

            let prices = [offer.saveText, offer.ordinaryPrice.map { "Ord. \($0)" }, offer.comparePrice.map { "Jfr \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !prices.isEmpty { Text(prices).font(.caption).foregroundStyle(.secondary) }
            if let info = offer.info { Label(info, systemImage: "info.circle").font(.caption) }
            let terms = [offer.restriction, offer.validTo.map { "Gäller t.o.m. \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !terms.isEmpty { Label(terms, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }

            if !offer.variants.isEmpty {
                let shown = showAllVariants ? offer.variants : Array(offer.variants.prefix(4))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ingår (\(offer.variants.count))").font(.caption.weight(.semibold))
                    ForEach(shown, id: \.self) { Text("• \($0)").font(.caption) }
                    if offer.variants.count > 4 {
                        Button(showAllVariants ? "Visa färre" : "Visa alla \(offer.variants.count)") {
                            withAnimation { showAllVariants.toggle() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Välj butik

private struct StorePicker: View {
    let chain: Chain
    let onSelect: (Store) -> Void

    @State private var query = ""
    @State private var results: [Store] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Ort eller butiksnamn", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await runSearch() } }
                    if searching { ProgressView() }
                }
            } header: {
                Text("Välj din \(chain.title)-butik")
            } footer: {
                if let error { Text(error) }
            }
            ForEach(results) { s in
                Button { onSelect(s) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).foregroundStyle(.primary)
                        Text(s.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: query) {
            // Sök medan man skriver, med kort fördröjning.
            guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await chain.provider.searchStores(q)
            error = results.isEmpty ? "Inga butiker hittades." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ToastText: View {
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
