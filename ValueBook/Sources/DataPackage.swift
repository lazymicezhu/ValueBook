import Foundation
import SwiftData
import SQLite3

/// 数据库与数据包。
/// 数据库位置写死在 App 自己的 Application Support，并关掉 App Group / iCloud 自动行为——
/// 第三方签名的描述文件常带 App Group、iCloud 权限，SwiftData 默认会因此把库放到别处或尝试 CloudKit 同步。
/// 数据包（.vbbackup）就是一个 SQLite 数据库文件，恢复时逐条拷进当前库，不依赖文件位置。
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

    /// 用数据包里的数据替换当前全部数据，返回 (流水, 物品, 账户) 数量
    @MainActor
    static func replaceAll(in context: ModelContext, from file: URL) throws -> (Int, Int, Int) {
        // 拷到临时目录再打开：Bundle 里的文件只读，SQLite 需要写 -shm
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        try FileManager.default.copyItem(at: file, to: tmp)
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }

        let src = ModelContext(try ModelContainer(for: Schema(models),
                                                  configurations: ModelConfiguration(url: tmp, cloudKitDatabase: .none)))
        let entries = try src.fetch(FetchDescriptor<LedgerEntry>())
        let assets = try src.fetch(FetchDescriptor<Asset>())
        let infos = try src.fetch(FetchDescriptor<AccountInfo>())
        guard !entries.isEmpty || !assets.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        // 逐条删除再插入，最后一次 save：同一个事务，中途被杀掉也不会只删不写
        for e in try context.fetch(FetchDescriptor<LedgerEntry>()) { context.delete(e) }
        for a in try context.fetch(FetchDescriptor<Asset>()) { context.delete(a) }
        for i in try context.fetch(FetchDescriptor<AccountInfo>()) { context.delete(i) }
        for e in entries { context.insert(e.copy()) }
        for a in assets { context.insert(a.copy()) }
        for i in infos { context.insert(i.copy()) }
        try context.save()
        return (entries.count, assets.count, infos.count)
    }

    /// 用户选的 / 从别的 App 打开的数据包：先备份当前数据到「文稿」，再替换
    @MainActor
    static func restore(from url: URL, into context: ModelContext) -> String {
        do {
            let data = try Importer.readFile(url)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(ext)")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            let backup = try backupCurrent(in: context)
            let n = try replaceAll(in: context, from: tmp)
            return "已恢复：流水 \(n.0) 笔，物品 \(n.1) 件，账户 \(n.2) 个。" + (backup.map { "\n\n原数据已备份到「文件」App → 价值账本 → \($0.lastPathComponent)" } ?? "")
        } catch {
            return "恢复失败：\(error.localizedDescription)\n\n文件：\(url.lastPathComponent)"
        }
    }

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

/// 内置数据：打包时把模拟器里的数据放进 App（Seed.store + SeedDefaults.plist）。
/// 每份内置数据（按内容指纹区分）在本机只导入一次：首次打开新版时覆盖本地数据，
/// 覆盖前把原数据导出到「文稿」（文件 App 里可见）。之后在手机上的修改不会再被冲掉。
/// 更新内置数据：运行 tools/export-sim-data.sh。开了云同步后不再导入内置数据。
enum Seed {
    static let appliedKey = "seed.applied"

    static var bundled: URL? { Bundle.main.url(forResource: "Seed", withExtension: "store") }

    /// 版本号由导出脚本按记录内容算出（SeedVersion.txt）
    static var fingerprint: String? {
        guard let url = Bundle.main.url(forResource: "SeedVersion", withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static var needsInstall: Bool {
        #if targetEnvironment(simulator)
        guard UserDefaults.standard.bool(forKey: "seedTest") else { return false }
        #endif
        // 开了云同步就以云端为准，内置数据不再覆盖
        guard !CloudSync.configured, let fp = fingerprint else { return false }
        return UserDefaults.standard.string(forKey: appliedKey) != fp
    }

    /// 导入了（或失败了）返回给用户看的结果，没做事返回 nil
    @MainActor
    static func installIfNeeded(into context: ModelContext) -> String? {
        #if targetEnvironment(simulator)
        // 模拟器是数据的源头，不能被内置数据覆盖；测试时加启动参数 -seedTest YES
        guard UserDefaults.standard.bool(forKey: "seedTest") else { return nil }
        #endif
        guard !CloudSync.configured, let bundled, let fp = fingerprint else { return nil }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: appliedKey) != fp else { return nil }

        var log = "内置数据 \(fp)\n"
        do {
            if let url = try DataPackage.backupCurrent(in: context) { log += "已备份原数据：\(url.lastPathComponent)\n" }
        } catch {
            log += "备份失败：\(error)\n"
        }
        do {
            let n = try DataPackage.replaceAll(in: context, from: bundled)
            if let url = Bundle.main.url(forResource: "SeedDefaults", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                for (k, v) in dict { defaults.set(v, forKey: k) }
            }
            defaults.set(fp, forKey: appliedKey)
            defaults.synchronize()
            log += "导入成功：流水 \(n.0) 物品 \(n.1) 账户 \(n.2)\n"
        } catch {
            log += "导入失败：\(error)\n"
        }
        log += "数据库：\(DataPackage.storeURL.path)\n"
        try? log.write(to: URL.documentsDirectory.appendingPathComponent("内置数据日志.txt"), atomically: true, encoding: .utf8)
        return log
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
