import Foundation
import SwiftData
import CryptoKit
import UIKit
import Observation

/// 云同步（Cloudflare Worker + D1，服务端代码在 cloud/）。
/// 每条流水 / 物品 / 账户和一份设置是服务器上的一条记录。本地存着「上次同步时每条记录的指纹」，
/// 和现在的数据一比就知道改了哪些、删了哪些，所以编辑代码不用关心同步。
/// 同一条两边都改了：本机改过的推上去覆盖（后同步的为准）；第一次同步时以云端为准，本机独有的记录传上去。
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    /// 默认服务器地址，编译时从 Config/Secrets.xcconfig 的 SYNC_HOST 注入；没配置就是空的
    static let defaultURL: String = {
        let url = Bundle.main.object(forInfoDictionaryKey: "SyncURL") as? String ?? ""
        return url == "https://" ? "" : url
    }()
    nonisolated private static let urlKey = "sync.url"
    nonisolated private static let tokenKey = "sync.token"
    nonisolated private static let lastKey = "sync.last"

    var running = false
    var status = ""
    var lastSync: Date? = UserDefaults.standard.object(forKey: CloudSync.lastKey) as? Date

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.urlKey) }
    }
    var token: String {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey) }
    }
    var enabled: Bool { !token.isEmpty && URL(string: serverURL) != nil }
    /// 内置数据判断用（不在主线程也能读）
    nonisolated static var configured: Bool { !(UserDefaults.standard.string(forKey: tokenKey) ?? "").isEmpty }

    private var pending: Task<Void, Never>?
    private var again = false
    /// 正在把云端数据写进本地：这期间的保存通知是自己发出的，不再触发同步
    private var applying = false

    // MARK: 触发

    /// 数据或设置变了：等一会儿再同步，连续修改只同步一次
    func schedule(_ context: ModelContext, delay: Double = 3) {
        guard enabled, !applying else { return }
        if running { again = true; return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await sync(context)
        }
    }

    /// 切到后台时申请一点后台时间，把改动推上去
    func syncInBackground(_ context: ModelContext) {
        guard enabled else { return }
        pending?.cancel()
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(id) }
        Task {
            await sync(context)
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: 同步

    func sync(_ context: ModelContext) async {
        guard enabled else { return }
        guard !running else { again = true; return }
        running = true
        status = "同步中…"
        defer { running = false }
        do {
            let n = try await run(context)
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: Self.lastKey)
            status = n.down + n.up == 0 ? "已是最新" : "收到 \(n.down) 条，上传 \(n.up) 条"
        } catch {
            status = "同步失败：\(error.localizedDescription)"
        }
        if again {
            again = false
            schedule(context, delay: 0.5)
        }
    }

    private func run(_ context: ModelContext) async throws -> (down: Int, up: Int) {
        var base = Base.load()
        let first = base.cursor == 0 && base.hashes.isEmpty

        // 1. 拉取云端变化（同一条只留最新的）
        var remote: [String: Remote] = [:]
        var order: [String] = []
        var cursor = base.cursor
        while true {
            let page: PullPage = try await request("pull?since=\(cursor)&limit=1000")
            for r in page.records {
                if remote[r.key] == nil { order.append(r.key) }
                remote[r.key] = r
            }
            cursor = page.cursor
            if !page.more { break }
        }

        // 2. 本地现状
        var local = try Snapshot(context)
        func changed(_ key: String) -> Bool { local.hashes[key] != base.hashes[key] }

        // 3. 应用云端变化：本机没改过的才收（第一次同步以云端为准）
        let incoming = order.compactMap { remote[$0] }.filter { r in
            let h = r.deleted ? nil : Self.hash(r.data)
            if local.hashes[r.key] == h { base.hashes[r.key] = h; return false }   // 已经一样
            return first || !changed(r.key)
        }
        if first && !incoming.isEmpty { _ = try? DataPackage.backupCurrent(in: context) }
        for r in incoming {
            try local.apply(r, in: context)
            base.hashes[r.key] = r.deleted ? nil : Self.hash(r.data)
        }
        if !incoming.isEmpty {
            applying = true
            defer { applying = false }
            Asset.refreshAllAddOns(in: context)
            try context.save()
        }
        base.cursor = cursor
        base.save()

        // 4. 推送本机改动（新增、修改、删除）
        var outgoing: [Outgoing] = []
        for (key, h) in local.hashes where base.hashes[key] != h {
            outgoing.append(Outgoing(key: key, kind: local.kinds[key] ?? "", data: local.data[key], deleted: false))
        }
        for key in base.hashes.keys where local.hashes[key] == nil {
            outgoing.append(Outgoing(key: key, kind: Snapshot.kind(of: key), data: nil, deleted: true))
        }
        for chunk in stride(from: 0, to: outgoing.count, by: 400).map({ Array(outgoing[$0..<min($0 + 400, outgoing.count)]) }) {
            let res: PushResult = try await request("push", body: ["records": chunk])
            for o in chunk { base.hashes[o.key] = o.deleted ? nil : local.hashes[o.key] }
            // 期间没有别的设备写入，游标可以直接跳过自己刚写的；否则下次拉取时会补上
            if res.cursor == base.cursor + chunk.count { base.cursor = res.cursor }
            base.save()
        }
        return (incoming.count, outgoing.count)
    }

    // MARK: 网络

    private struct PullPage: Decodable { var records: [Remote]; var cursor: Int; var more: Bool }
    private struct PushResult: Decodable { var cursor: Int }
    private struct Outgoing: Encodable { var key: String; var kind: String; var data: String?; var deleted: Bool }
    private struct ServerError: Decodable { var error: String }

    private func request<T: Decodable>(_ path: String, body: [String: [Outgoing]]? = nil) async throws -> T {
        guard let url = URL(string: serverURL.hasSuffix("/") ? serverURL + path : serverURL + "/" + path) else {
            throw SyncError("服务器地址不对")
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw SyncError("密钥不对") }
            throw SyncError((try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? "服务器返回 \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct SyncError: LocalizedError {
    var errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

/// 服务器上的一条记录
struct Remote: Decodable {
    var key: String
    var kind: String
    var data: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey { case key, kind, data, deleted }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(String.self, forKey: .kind)
        data = try c.decode(String.self, forKey: .data)
        deleted = try c.decode(Int.self, forKey: .deleted) != 0
    }
}

/// 上次同步完时的状态：游标 + 每条记录的指纹（存在 Application Support，不进 UserDefaults，免得被内置数据带到别的设备）
private struct Base: Codable {
    var cursor = 0
    var hashes: [String: String] = [:]

    static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("sync-base.json") }
    static func load() -> Base {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Base.self, from: $0) } ?? Base()
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic) }
}

// MARK: 本地数据 ⇄ 记录

/// 本地全部数据编码成记录。key：e:<流水id> / a:<物品id> / c:<账户名> / settings
@MainActor
private struct Snapshot {
    var data: [String: String] = [:]
    var hashes: [String: String] = [:]
    var kinds: [String: String] = [:]
    var entries: [UUID: [LedgerEntry]] = [:]
    var assets: [UUID: [Asset]] = [:]
    var accounts: [String: [AccountInfo]] = [:]

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    static func kind(of key: String) -> String {
        switch key.prefix(2) {
        case "e:": return "entry"
        case "a:": return "asset"
        case "c:": return "account"
        default: return "settings"
        }
    }

    init(_ context: ModelContext) throws {
        for e in try context.fetch(FetchDescriptor<LedgerEntry>()) {
            entries[e.id, default: []].append(e)
            put("e:\(e.id.uuidString)", try Self.encoder.encode(EntryRecord(e)))
        }
        for a in try context.fetch(FetchDescriptor<Asset>()) {
            assets[a.id, default: []].append(a)
            put("a:\(a.id.uuidString)", try Self.encoder.encode(AssetRecord(a)))
        }
        for i in try context.fetch(FetchDescriptor<AccountInfo>()) {
            accounts[i.name, default: []].append(i)
            put("c:\(i.name)", try Self.encoder.encode(AccountRecord(i)))
        }
        put("settings", try JSONSerialization.data(withJSONObject: SyncedSettings.current(), options: .sortedKeys))
    }

    private mutating func put(_ key: String, _ json: Data) {
        let s = String(decoding: json, as: UTF8.self)
        data[key] = s
        hashes[key] = CloudSync.hash(s)
        kinds[key] = Self.kind(of: key)
    }

    /// 把云端的一条记录写进本地
    mutating func apply(_ r: Remote, in context: ModelContext) throws {
        let json = Data(r.data.utf8)
        let id = String(r.key.dropFirst(2))
        switch Self.kind(of: r.key) {
        case "entry":
            guard let uuid = UUID(uuidString: id) else { return }
            let list = entries[uuid] ?? []
            if r.deleted {
                for x in list { context.delete(x) }
                entries[uuid] = nil
            } else {
                let rec = try JSONDecoder().decode(EntryRecord.self, from: json)
                let e = list.first ?? { let n = LedgerEntry(); n.id = uuid; context.insert(n); return n }()
                rec.write(to: e)
                for x in list.dropFirst() { context.delete(x) }
                entries[uuid] = [e]
            }
        case "asset":
            guard let uuid = UUID(uuidString: id) else { return }
            let list = assets[uuid] ?? []
            if r.deleted {
                for x in list { context.delete(x) }
                assets[uuid] = nil
            } else {
                let rec = try JSONDecoder().decode(AssetRecord.self, from: json)
                let a = list.first ?? { let n = Asset(name: "", price: 0); n.id = uuid; context.insert(n); return n }()
                rec.write(to: a)
                for x in list.dropFirst() { context.delete(x) }
                assets[uuid] = [a]
            }
        case "account":
            let list = accounts[id] ?? []
            if r.deleted {
                for x in list { context.delete(x) }
                accounts[id] = nil
            } else {
                let rec = try JSONDecoder().decode(AccountRecord.self, from: json)
                let i = list.first ?? { let n = AccountInfo(name: id, group: ""); context.insert(n); return n }()
                rec.write(to: i)
                for x in list.dropFirst() { context.delete(x) }
                accounts[id] = [i]
            }
        default:
            guard !r.deleted, let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            SyncedSettings.apply(dict)
        }
        if r.deleted {
            data[r.key] = nil; hashes[r.key] = nil; kinds[r.key] = nil
        } else {
            data[r.key] = r.data; hashes[r.key] = CloudSync.hash(r.data); kinds[r.key] = r.kind
        }
    }
}

/// 跟着数据走的设置：汇率、账户分类、分类排序、挑选物品的条件、物品排序
enum SyncedSettings {
    static func synced(_ key: String) -> Bool {
        key.hasPrefix("rate.") || key.hasPrefix("catOrder.") || key.hasPrefix("pick.")
            || key == "accountGroups" || key == "assetSort"
    }

    static func current() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { synced($0.key) && JSONSerialization.isValidJSONObject([$0.value]) }
    }

    static func apply(_ dict: [String: Any]) {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where synced(k) && dict[k] == nil { d.removeObject(forKey: k) }
        for (k, v) in dict where synced(k) { d.set(v, forKey: k) }
    }
}

private struct EntryRecord: Codable {
    var type, category, subcategory, account, toAccount, member, merchant, project, note, currency, toCurrency: String
    var date: Date
    var amount, toAmount: Double
    var assetID: UUID?
    var isAddOn: Bool
    var importKey: String?

    init(_ e: LedgerEntry) {
        type = e.typeRaw; category = e.category; subcategory = e.subcategory; account = e.account
        toAccount = e.toAccount; member = e.member; merchant = e.merchant; project = e.project; note = e.note
        currency = e.currency; toCurrency = e.toCurrency; date = e.date; amount = e.amount; toAmount = e.toAmount
        assetID = e.assetID; isAddOn = e.isAddOn; importKey = e.importKey
    }

    func write(to e: LedgerEntry) {
        e.typeRaw = type; e.category = category; e.subcategory = subcategory; e.account = account
        e.toAccount = toAccount; e.member = member; e.merchant = merchant; e.project = project; e.note = note
        e.currency = currency; e.toCurrency = toCurrency; e.date = date; e.amount = amount; e.toAmount = toAmount
        e.assetID = assetID; e.isAddOn = isAddOn; e.importKey = importKey
    }
}

/// 附属账目的合计（addOnTotal 等）由流水算出来，不同步
private struct AssetRecord: Codable {
    var name, category, method, note: String
    var purchaseDate, createdAt: Date
    var retiredDate: Date?
    var price, lifeYears, residualRate, salePrice, targetDailyCost: Double
    var isRetired: Bool
    var valuations: Data?

    init(_ a: Asset) {
        name = a.name; category = a.category; method = a.methodRaw; note = a.note
        purchaseDate = a.purchaseDate; createdAt = a.createdAt; retiredDate = a.retiredDate
        price = a.price; lifeYears = a.lifeYears; residualRate = a.residualRate; salePrice = a.salePrice
        targetDailyCost = a.targetDailyCost; isRetired = a.isRetired; valuations = a.valuationsData
    }

    func write(to a: Asset) {
        a.name = name; a.category = category; a.methodRaw = method; a.note = note
        a.purchaseDate = purchaseDate; a.createdAt = createdAt; a.retiredDate = retiredDate
        a.price = price; a.lifeYears = lifeYears; a.residualRate = residualRate; a.salePrice = salePrice
        a.targetDailyCost = targetDailyCost; a.isRetired = isRetired; a.valuationsData = valuations
    }
}

private struct AccountRecord: Codable {
    var group, currency: String
    var excluded: Bool

    init(_ i: AccountInfo) { group = i.group; currency = i.currency; excluded = i.excluded }
    func write(to i: AccountInfo) { i.group = group; i.currency = currency; i.excluded = excluded }
}
