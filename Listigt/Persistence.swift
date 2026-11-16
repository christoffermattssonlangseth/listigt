import CoreData
import CloudKit

let cloudKitContainerID = "iCloud.se.langseth.listigt"

// MARK: - Entiteter
//
// Ett "hushåll" är roten som delas via iCloud. Allt som hänger på det
// (varor, basvaror, inlärda streckkoder) följer med i delningen.

@objc(Household)
final class Household: NSManagedObject {
    @NSManaged var name: String?
    @NSManaged var created: Date?
    @NSManaged var items: Set<ShopItem>?
    @NSManaged var baseItems: Set<BaseItem>?
    @NSManaged var eanNames: Set<EanName>?
    @NSManaged var categoryChoices: Set<CategoryChoice>?
    @NSManaged var purchases: Set<Purchase>?
    @NSManaged var menuDishes: Set<MenuDish>?
}

@objc(ShopItem)
final class ShopItem: NSManagedObject, Identifiable {
    @NSManaged var name: String?
    @NSManaged var qty: Int64
    @NSManaged var ean: String?
    @NSManaged var checked: Bool
    /// När varan bockades av (för att städa bort den när köptillfället är slut).
    @NSManaged var checkedAt: Date?
    @NSManaged var fromBase: Bool
    @NSManaged var created: Date?
    /// Mängd för andra enheter än st (st ligger i qty för bakåtkompatibilitet).
    @NSManaged var amount: Double
    @NSManaged var unit: String?
    @NSManaged var household: Household?
}

extension ShopItem {
    var quantity: Quantity {
        get {
            if let u = MeasureUnit(stored: unit), amount > 0 {
                return Quantity(amount: amount, unit: u)
            }
            return Quantity(amount: Double(max(qty, 1)), unit: .st)
        }
        set {
            if newValue.unit == .st {
                qty = Int64(max(1, newValue.amount.rounded())); unit = nil; amount = 0
            } else {
                qty = 1; unit = newValue.unit.rawValue; amount = newValue.amount
            }
        }
    }
}

@objc(BaseItem)
final class BaseItem: NSManagedObject, Identifiable {
    @NSManaged var name: String?
    @NSManaged var ean: String?
    @NSManaged var created: Date?
    /// 0 = varje inköpsrunda, annars antal dagar mellan gångerna.
    @NSManaged var intervalDays: Int64
    /// När varan senast lades (eller redan stod) på inköpslistan.
    @NSManaged var lastAdded: Date?
    /// Standardmängd när basvaran läggs på listan (0 = 1 st).
    @NSManaged var amount: Double
    @NSManaged var unit: String?
    @NSManaged var household: Household?
}

extension BaseItem {
    var quantity: Quantity {
        get {
            guard amount > 0 else { return .one }
            return Quantity(amount: amount, unit: MeasureUnit(stored: unit) ?? .st)
        }
        set {
            if newValue.isOne { amount = 0; unit = nil }
            else { amount = newValue.amount; unit = newValue.unit.rawValue }
        }
    }
}

@objc(EanName)
final class EanName: NSManagedObject {
    @NSManaged var ean: String?
    @NSManaged var name: String?
    @NSManaged var household: Household?
}

/// Hushållets egna kategorival per varunamn (överstyr gissningen).
@objc(CategoryChoice)
final class CategoryChoice: NSManagedObject {
    @NSManaged var key: String?
    @NSManaged var category: String?
    @NSManaged var household: Household?
}

/// En avbockad vara. Köptillfällen räknas fram ur tidpunkterna (se PurchaseHistory),
/// så två telefoner som handlar samtidigt hamnar i samma tillfälle utan konflikter.
@objc(Purchase)
final class Purchase: NSManagedObject, Identifiable {
    @NSManaged var name: String?
    @NSManaged var ean: String?
    @NSManaged var amount: Double
    @NSManaged var unit: String?
    @NSManaged var date: Date?
    @NSManaged var household: Household?
}

extension Purchase {
    var quantity: Quantity {
        get { amount > 0 ? Quantity(amount: amount, unit: MeasureUnit(stored: unit) ?? .st) : .one }
        set { amount = newValue.amount; unit = newValue.unit.rawValue }
    }
}

/// En rätt i veckomenyn. Ingredienser och steg sparas som JSON (se MenuPlanner).
@objc(MenuDish)
final class MenuDish: NSManagedObject, Identifiable {
    @NSManaged var title: String?
    @NSManaged var info: String?
    @NSManaged var days: Int64
    @NSManaged var servings: Int64
    @NSManaged var minutes: Int64
    @NSManaged var ingredientsJSON: String?
    @NSManaged var stepsJSON: String?
    @NSManaged var order: Int64
    @NSManaged var created: Date?
    /// ICA:s recept-id, länk och bild.
    @NSManaged var recipeId: Int64
    @NSManaged var url: String?
    @NSManaged var imageURL: String?
    @NSManaged var household: Household?
}

// MARK: - Modell (byggd i kod; CloudKit kräver valfria fält och inverser)

enum Model {
    static let shared: NSManagedObjectModel = {
        func entity(_ name: String) -> NSEntityDescription {
            let e = NSEntityDescription()
            e.name = name
            e.managedObjectClassName = name
            return e
        }
        func attr(_ name: String, _ type: NSAttributeType, _ def: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = true
            a.defaultValue = def
            return a
        }
        func link(_ parent: NSEntityDescription, _ many: String,
                  _ child: NSEntityDescription) -> (NSRelationshipDescription, NSRelationshipDescription) {
            let toMany = NSRelationshipDescription()
            toMany.name = many
            toMany.destinationEntity = child
            toMany.minCount = 0
            toMany.maxCount = 0
            toMany.isOptional = true
            toMany.deleteRule = .cascadeDeleteRule
            let toOne = NSRelationshipDescription()
            toOne.name = "household"
            toOne.destinationEntity = parent
            toOne.maxCount = 1
            toOne.isOptional = true
            toOne.deleteRule = .nullifyDeleteRule
            toMany.inverseRelationship = toOne
            toOne.inverseRelationship = toMany
            return (toMany, toOne)
        }

        let household = entity("Household")
        let item = entity("ShopItem")
        let base = entity("BaseItem")
        let ean = entity("EanName")
        let choice = entity("CategoryChoice")
        let purchase = entity("Purchase")
        let dish = entity("MenuDish")

        let (hItems, iHouse) = link(household, "items", item)
        let (hBase, bHouse) = link(household, "baseItems", base)
        let (hEans, eHouse) = link(household, "eanNames", ean)
        let (hChoices, cHouse) = link(household, "categoryChoices", choice)
        let (hPurchases, pHouse) = link(household, "purchases", purchase)
        let (hDishes, dHouse) = link(household, "menuDishes", dish)

        household.properties = [attr("name", .stringAttributeType), attr("created", .dateAttributeType),
                                hItems, hBase, hEans, hChoices, hPurchases, hDishes]
        item.properties = [attr("name", .stringAttributeType), attr("qty", .integer64AttributeType, 1),
                           attr("ean", .stringAttributeType), attr("checked", .booleanAttributeType, false),
                           attr("checkedAt", .dateAttributeType),
                           attr("fromBase", .booleanAttributeType, false), attr("created", .dateAttributeType),
                           attr("amount", .doubleAttributeType, 0.0), attr("unit", .stringAttributeType),
                           iHouse]
        base.properties = [attr("name", .stringAttributeType), attr("ean", .stringAttributeType),
                           attr("created", .dateAttributeType),
                           attr("intervalDays", .integer64AttributeType, 0),
                           attr("lastAdded", .dateAttributeType),
                           attr("amount", .doubleAttributeType, 0.0), attr("unit", .stringAttributeType), bHouse]
        ean.properties = [attr("ean", .stringAttributeType), attr("name", .stringAttributeType), eHouse]
        choice.properties = [attr("key", .stringAttributeType), attr("category", .stringAttributeType), cHouse]
        purchase.properties = [attr("name", .stringAttributeType), attr("ean", .stringAttributeType),
                               attr("amount", .doubleAttributeType, 0.0), attr("unit", .stringAttributeType),
                               attr("date", .dateAttributeType), pHouse]
        dish.properties = [attr("title", .stringAttributeType), attr("info", .stringAttributeType),
                           attr("days", .integer64AttributeType, 1), attr("servings", .integer64AttributeType, 2),
                           attr("minutes", .integer64AttributeType, 0),
                           attr("ingredientsJSON", .stringAttributeType), attr("stepsJSON", .stringAttributeType),
                           attr("order", .integer64AttributeType, 0), attr("created", .dateAttributeType),
                           attr("recipeId", .integer64AttributeType, 0), attr("url", .stringAttributeType),
                           attr("imageURL", .stringAttributeType), dHouse]

        let model = NSManagedObjectModel()
        model.entities = [household, item, base, ean, choice, purchase, dish]
        return model
    }()
}

extension NSManagedObjectContext {
    func insert<T: NSManagedObject>(_ type: T.Type, into store: NSPersistentStore?) -> T {
        let obj = NSEntityDescription.insertNewObject(forEntityName: String(describing: type), into: self) as! T
        if let store { assign(obj, to: store) }
        return obj
    }
}

// MARK: - Lagring: en privat och en delad iCloud-databas

final class Persistence {
    let container: NSPersistentCloudKitContainer
    let privateStore: NSPersistentStore
    let sharedStore: NSPersistentStore
    lazy var ckContainer = CKContainer(identifier: cloudKitContainerID)

    init() {
        container = NSPersistentCloudKitContainer(name: "Listigt", managedObjectModel: Model.shared)
        let dir = NSPersistentContainer.defaultDirectoryURL()

        func description(_ file: String, scope: CKDatabase.Scope) -> NSPersistentStoreDescription {
            let d = NSPersistentStoreDescription(url: dir.appendingPathComponent(file))
            let opts = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudKitContainerID)
            opts.databaseScope = scope
            d.cloudKitContainerOptions = opts
            d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            return d
        }
        let privateDesc = description("private.sqlite", scope: .private)
        let sharedDesc = description("shared.sqlite", scope: .shared)
        container.persistentStoreDescriptions = [privateDesc, sharedDesc]

        container.loadPersistentStores { desc, error in
            if let error { fatalError("Kunde inte öppna databasen \(desc.url?.lastPathComponent ?? ""): \(error)") }
        }
        let psc = container.persistentStoreCoordinator
        privateStore = psc.persistentStore(for: privateDesc.url!)!
        sharedStore = psc.persistentStore(for: sharedDesc.url!)!

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "app"
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func share(for object: NSManagedObject) -> CKShare? {
        (try? container.fetchShares(matching: [object.objectID]))?[object.objectID]
    }
}
