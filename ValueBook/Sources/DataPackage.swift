import Foundation
import SwiftData
import SQLite3

/// 数据库与数据包。
/// 数据库位置写死在 App 自己的 Application Support，并关掉 App Group / iCloud 自动行为——
/// 第三方签名的描述文件常带 App Group、iCloud 权限，SwiftData 默认会因此把库放到别处或尝试 CloudKit 同步。
/// 数据包（.vbbackup）就是一个 SQLite 数据库文件，只用来导出备份；设备间的数据靠云同步。
enum DataPackage {
    static let ext = "vbbackup"
    static let models: [any PersistentModel.Type] = [LedgerEntry.self, Asset.self, AccountInfo.self]

    static var storeURL: URL { URL.applicationSupportDirectory.appendingPathComponent("default.store") }

    static let container: ModelContainer = {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Schema(models), configurations: config)
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
    }()

    /// 当前有数据时导出到「文稿」作备份
    @MainActor
    static func backupCurrent(in context: ModelContext) throws -> URL? {
        let has = ((try? context.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0) > 0
            || ((try? context.fetchCount(FetchDescriptor<Asset>())) ?? 0) > 0
        guard has else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return try export(from: context, to: .documentsDirectory, name: "覆盖前备份-\(f.string(from: .now))")
    }

    /// 把当前全部数据写成一个数据包文件
    @MainActor
    static func export(from context: ModelContext, to folder: URL = FileManager.default.temporaryDirectory,
                       name: String = "价值账本-数据包-\(Fmt.day.string(from: .now))") throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: work.path + s) } }
        do {
            let dst = ModelContext(try ModelContainer(for: Schema(models),
                                                      configurations: ModelConfiguration(url: work, cloudKitDatabase: .none)))
            for e in try context.fetch(FetchDescriptor<LedgerEntry>()) { dst.insert(e.copy()) }
            for a in try context.fetch(FetchDescriptor<Asset>()) { dst.insert(a.copy()) }
            for i in try context.fetch(FetchDescriptor<AccountInfo>()) { dst.insert(i.copy()) }
            try dst.save()
        }
        // 合并 WAL，得到单个文件
        let out = folder.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.removeItem(at: out)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(work.path, &db) == SQLITE_OK,
              sqlite3_exec(db, "VACUUM INTO '\(out.path.replacingOccurrences(of: "'", with: "''"))'", nil, nil, nil) == SQLITE_OK
        else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}

extension LedgerEntry {
    func copy() -> LedgerEntry {
        let e = LedgerEntry(type: type, date: date, amount: amount, category: category, subcategory: subcategory,
                            account: account, toAccount: toAccount, member: member, merchant: merchant,
                            project: project, note: note, importKey: importKey)
        e.id = id
        e.currency = currency
        e.toAmount = toAmount
        e.toCurrency = toCurrency
        e.assetID = assetID
        e.isAddOn = isAddOn
        return e
    }
}

extension Asset {
    func copy() -> Asset {
        let a = Asset(name: name, category: category, purchaseDate: purchaseDate, price: price,
                      method: method, lifeYears: lifeYears, residualRate: residualRate, note: note)
        a.id = id
        a.isRetired = isRetired
        a.retiredDate = retiredDate
        a.salePrice = salePrice
        a.valuationsData = valuationsData
        a.createdAt = createdAt
        a.targetDailyCost = targetDailyCost
        a.addOnTotal = addOnTotal
        a.addOnsData = addOnsData
        a.firstAddOnDate = firstAddOnDate
        return a
    }
}

extension AccountInfo {
    func copy() -> AccountInfo { AccountInfo(name: name, group: group, excluded: excluded, currency: currency) }
}
