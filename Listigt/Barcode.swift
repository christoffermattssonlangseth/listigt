import SwiftUI
import VisionKit
import AVFoundation

enum EAN {
    /// EAN-13 som börjar på 2 skrivs ut av butiken själv (vägda eller prismärkta varor)
    /// och innehåller pris eller vikt.
    static func isInStore(_ code: String) -> Bool {
        code.count == 13 && code.first == "2"
    }

    /// Nyckel för att komma ihåg en kod. För butikskoder används bara varunumret
    /// (de första 7 siffrorna), så samma vara känns igen oavsett pris eller vikt.
    static func memoryKey(_ code: String) -> String {
        isInStore(code) ? "butik:" + code.prefix(7) : code
    }

    static func isValid(_ code: String) -> Bool {
        guard [8, 12, 13, 14].contains(code.count), code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber) else {
            return false
        }
        var digits = code.compactMap { $0.wholeNumberValue }
        let check = digits.removeLast()
        let sum = digits.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
        return (10 - sum % 10) % 10 == check
    }
}

enum ProductLookup {
    private struct Response: Decodable {
        let product: [String: JSONValue]?
    }

    /// Godtyckligt JSON-värde; vi behöver bara strängar och stränglistor.
    private enum JSONValue: Decodable {
        case string(String), strings([String]), other
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([String].self) { self = .strings(a) }
            else { self = .other }
        }
        var string: String? {
            if case .string(let s) = self {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return nil
        }
        var strings: [String] { if case .strings(let a) = self { return a } else { return [] } }
    }

    struct Product {
        let name: String
        let category: ItemCategory?
    }

    /// Open Food Facts och dess systerdatabaser (samma API).
    private static let sources: [(host: String, fallback: ItemCategory?)] = [
        ("world.openfoodfacts.org", nil),
        ("world.openbeautyfacts.org", .hygien),
        ("world.openproductsfacts.org", nil),
    ]

    /// Namnfält i prioritetsordning: svenska, nordiska, generiska, engelska, övriga.
    private static let nameFields = [
        "product_name_sv", "abbreviated_product_name_sv", "generic_name_sv",
        "product_name_no", "product_name_nb", "product_name_da", "product_name_fi",
        "product_name", "abbreviated_product_name", "product_name_en", "generic_name", "generic_name_en",
        "product_name_de", "product_name_fr",
    ]

    /// Slår upp produktnamn och kategori. Frågar alla källor parallellt; första med namn vinner.
    static func product(for ean: String) async -> Product? {
        await withTaskGroup(of: (Int, Product?).self) { group in
            for (i, src) in sources.enumerated() {
                group.addTask { (i, await fetch(ean, host: src.host, fallback: src.fallback)) }
            }
            var results = [Int: Product]()
            for await (i, p) in group { if let p { results[i] = p } }
            let hit = results.sorted { $0.key < $1.key }.first?.value
            log("EAN \(ean): \(hit.map { "\($0.name) [\($0.category?.title ?? "-")]" } ?? "hittades inte i någon databas")")
            return hit
        }
    }

    private static func fetch(_ ean: String, host: String, fallback: ItemCategory?) async -> Product? {
        var c = URLComponents(string: "https://\(host)/api/v2/product/\(ean).json")!
        c.queryItems = [URLQueryItem(name: "fields",
                                     value: (nameFields + ["brands", "quantity", "categories_tags"]).joined(separator: ","))]
        var req = URLRequest(url: c.url!, timeoutInterval: 8)
        req.setValue("Listigt/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = (try? JSONDecoder().decode(Response.self, from: data))?.product else { return nil }

        let brand = p["brands"]?.string?.split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let quantity = p["quantity"]?.string ?? ""
        let full: String
        if let name = nameFields.lazy.compactMap({ p[$0]?.string }).first {
            full = brand.isEmpty || name.localizedCaseInsensitiveContains(brand) ? name : "\(name) (\(brand))"
        } else if !brand.isEmpty {
            // Inget namn, men märke (och ev. storlek) är bättre än ingenting.
            full = quantity.isEmpty ? brand : "\(brand) \(quantity)"
        } else {
            return nil
        }
        let tags = p["categories_tags"]?.strings ?? []
        return Product(name: full, category: ItemCategory.fromOpenFoodFacts(tags) ?? fallback)
    }
}

// MARK: - Scanner

struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manual = ""

    private var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if DataScannerViewController.isSupported && !cameraDenied {
                    BarcodeScanner(onCode: onCode)
                        .overlay { ScanFrame() }
                        .overlay(alignment: .bottom) {
                            Text("Håll streckkoden i rutan")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 12)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ContentUnavailableView(
                        cameraDenied ? "Kameran är avstängd" : "Scanning stöds inte",
                        systemImage: "barcode.viewfinder",
                        description: Text(cameraDenied
                            ? "Tillåt kameran för Listigt i Inställningar, eller skriv in koden nedan."
                            : "Skriv in streckkoden nedan."))
                }
                HStack {
                    TextField("…eller skriv EAN-koden", text: $manual)
                        .keyboardType(.numberPad)
                        .toolbar {
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("Klar") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                                    to: nil, from: nil, for: nil)
                                }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    Button("OK") { onCode(manual) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!EAN.isValid(manual))
                }
            }
            .padding()
            .navigationTitle("Scanna vara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Stäng") { dismiss() } }
            }
        }
    }
}

/// Andel av kamerabilden där streckkoden måste vara (bredd, höjd).
private let scanArea = CGSize(width: 0.8, height: 0.3)

private struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        // Läs bara i rutan mitt i bilden, så att varor i bakgrunden inte plockas upp.
        DispatchQueue.main.async {
            let b = vc.view.bounds
            guard b.width > 0 else { return }
            let w = b.width * scanArea.width, h = b.height * scanArea.height
            vc.regionOfInterest = CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
            if !vc.isScanning { try? vc.startScanning() }
        }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        /// Hur många gånger i rad varje kod setts. En kod godkänns först efter flera stabila avläsningar.
        private var seen: [String: Int] = [:]
        private let needed = 3

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        private func handle(_ items: [RecognizedItem]) {
            guard !done else { return }
            let codes = items.compactMap { item -> String? in
                guard case .barcode(let b) = item, let code = b.payloadStringValue, EAN.isValid(code) else { return nil }
                return code
            }
            // Koder som inte syns längre börjar om från noll.
            seen = seen.filter { codes.contains($0.key) }
            for code in codes {
                seen[code, default: 0] += 1
                if seen[code]! >= needed {
                    done = true
                    log("Scannern läste \(code)")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(code)
                    return
                }
            }
        }

        func dataScanner(_ s: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(allItems)
        }

        func dataScanner(_ s: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(allItems)
        }
    }
}

/// Ram som visar var streckkoden ska vara.
private struct ScanFrame: View {
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: geo.size.width * scanArea.width, height: geo.size.height * scanArea.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .shadow(radius: 4)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Flöde: streckkod → namn → bekräfta → lägg till

/// En scannad vara som väntar på bekräftelse i produktkortet.
private struct PendingScan: Identifiable {
    let ean: String
    let name: String?
    var id: String { ean }
}

/// Hanterar scanning och uppslag. Sätt `ean` (t.ex. från inmatat fält) eller `isScanning` för att starta.
/// Efter uppslaget visas ett produktkort där mängd, namn och kategori kan ändras innan varan läggs till.
struct ScanFlow: ViewModifier {
    @Binding var isScanning: Bool
    @Binding var ean: String?
    /// true för basvaror (visar "Hur ofta" i kortet)
    var forBase = false
    let onConfirmed: (_ edit: ProductEdit, _ ean: String) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var pending: PendingScan?
    @State private var lookingUp = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isScanning) {
                ScannerSheet { code in
                    isScanning = false
                    ean = code
                }
            }
            .onChange(of: ean) { _, code in
                guard let code else { return }
                ean = nil
                Task { await resolve(code) }
            }
            .sheet(item: $pending) { p in
                ProductSheet(
                    initial: ProductEdit(name: p.name ?? "", quantity: .one,
                                         category: model.category(for: p.name),
                                         intervalDays: forBase ? 0 : nil),
                    ean: p.ean,
                    saveLabel: "Lägg till",
                    showDelete: false,
                    message: message(for: p),
                    categoryFor: { model.category(for: $0) },
                    onSave: { e in
                        model.remember(ean: p.ean, name: e.name)
                        if let c = e.category, c != model.category(for: e.name) { model.setCategory(c, for: e.name) }
                        onConfirmed(e, p.ean)
                    },
                    onDelete: {})
            }
            .overlay {
                if lookingUp {
                    ProgressView("Söker vara…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    private func message(for p: PendingScan) -> String? {
        if p.name == nil {
            return EAN.isInStore(p.ean)
                ? "Butikens egen kod för en vägd eller prismärkt vara. Skriv vad den heter – den känns igen nästa gång."
                : "Streckkoden hittades inte. Skriv vad varan heter – den känns igen nästa gång."
        }
        if !forBase, let existing = model.openItem(named: p.name, ean: p.ean) {
            return "Står redan på listan (\(existing.quantity.text)). Det du anger läggs till."
        }
        return nil
    }

    @MainActor
    private func resolve(_ code: String) async {
        lookingUp = true
        let started = Date()
        let name = await model.lookup(code)
        // Scannerrutan måste hinna stänga innan produktkortet kan visas.
        let waited = Date().timeIntervalSince(started)
        if waited < 0.6 { try? await Task.sleep(for: .seconds(0.6 - waited)) }
        lookingUp = false
        pending = PendingScan(ean: code, name: name)
    }
}

extension View {
    func scanFlow(isScanning: Binding<Bool>, ean: Binding<String?>, forBase: Bool = false,
                  onConfirmed: @escaping (ProductEdit, String) -> Void) -> some View {
        modifier(ScanFlow(isScanning: isScanning, ean: ean, forBase: forBase, onConfirmed: onConfirmed))
    }
}
