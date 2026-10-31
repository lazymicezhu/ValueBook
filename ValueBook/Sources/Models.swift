import Foundation
import SwiftData

enum EntryType: String, CaseIterable, Identifiable {
    case expense = "支出"
    case income = "收入"
    case transfer = "转账"
    var id: String { rawValue }
}

/// 一笔账
@Model
final class LedgerEntry {
    var id: UUID = UUID()
    var typeRaw: String = EntryType.expense.rawValue
    var date: Date = Date()
    var amount: Double = 0
    var category: String = ""
    var subcategory: String = ""
    var account: String = ""
    var toAccount: String = ""
    var member: String = ""
    var merchant: String = ""
    var project: String = ""
    var note: String = ""
    /// 币种，金额按这个币种记
    var currency: String = "CNY"
    /// 转账到账金额（换汇时和转出金额不同），0 表示和转出金额一样
    var toAmount: Double = 0
    var toCurrency: String = ""
    /// 关联的物品（买东西那笔支出，或挂在物品下的附属账目）
    var assetID: UUID?
    /// 是物品的附属账目（配件、续费等），不是买入那笔
    var isAddOn: Bool = false
    /// 导入去重用
    var importKey: String?

    init(type: EntryType = .expense, date: Date = .now, amount: Double = 0,
         category: String = "", subcategory: String = "", account: String = "",
         toAccount: String = "", member: String = "", merchant: String = "",
         project: String = "", note: String = "", importKey: String? = nil) {
        self.typeRaw = type.rawValue
        self.date = date
        self.amount = amount
        self.category = category
        self.subcategory = subcategory
        self.account = account
        self.toAccount = toAccount
        self.member = member
        self.merchant = merchant
        self.project = project
        self.note = note
        self.importKey = importKey
    }

    var type: EntryType {
        get { EntryType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    /// 折算成人民币，用于汇总
    var cny: Double { amount * Rates.rate(currency) }

    /// 是否余额调整（随手记的「余额变更」）
    var isBalanceAdjust: Bool { type == .transfer && toAccount.isEmpty }

    /// 转入账户实际收到的金额
    var receivedAmount: Double { toAmount != 0 ? toAmount : amount }

    var displayCategory: String {
        if subcategory.isEmpty { return category.isEmpty ? type.rawValue : category }
        return category.isEmpty ? subcategory : "\(category) · \(subcategory)"
    }
}

/// 外币汇率（1 外币 = ? 人民币），可在「我的」里修改
enum Rates {
    static let defaults: [String: Double] = ["HKD": 0.848957, "USD": 7.1, "EUR": 7.7, "JPY": 0.047, "GBP": 9.0, "MOP": 0.88, "TWD": 0.22]

    /// 旧版本打开设置页时会把 0.91 存下来，清掉它，改用和随手记一致的默认汇率
    static func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "rates.migrated.v2") else { return }
        if d.double(forKey: "rate.HKD") == 0.91 { d.removeObject(forKey: "rate.HKD") }
        d.set(true, forKey: "rates.migrated.v2")
    }

    static func rate(_ code: String) -> Double {
        if code.isEmpty || code == "CNY" || code == "RMB" { return 1 }
        let saved = UserDefaults.standard.double(forKey: "rate.\(code)")
        return saved > 0 ? saved : (defaults[code] ?? 1)
    }

    static func set(_ code: String, _ value: Double) {
        UserDefaults.standard.set(value, forKey: "rate.\(code)")
    }

    static func symbol(_ code: String) -> String {
        switch code {
        case "", "CNY", "RMB": return "¥"
        case "HKD": return "HK$"
        case "USD": return "$"
        case "EUR": return "€"
        case "JPY": return "JP¥"
        case "GBP": return "£"
        default: return code + " "
        }
    }
}

enum DepreciationMethod: String, CaseIterable, Identifiable {
    case straight = "直线折旧"
    case accelerated = "加速折旧"
    case none = "不折旧"
    var id: String { rawValue }

    var explain: String {
        switch self {
        case .straight: return "每天贬值相同金额，到使用年限时剩下残值"
        case .accelerated: return "前期贬值快、后期慢，适合电子产品、汽车"
        case .none: return "价值不变，适合黄金、收藏品等"
        }
    }
}

/// 手动估值点（比如查了二手价）
struct ValuePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var value: Double
    var note: String = ""
}

/// 一件物品
@Model
final class Asset {
    var id: UUID = UUID()
    var name: String = ""
    var category: String = "其他"
    var purchaseDate: Date = Date()
    var price: Double = 0
    var methodRaw: String = DepreciationMethod.straight.rawValue
    var lifeYears: Double = 5
    /// 残值率 0~1
    var residualRate: Double = 0.1
    var isRetired: Bool = false
    var retiredDate: Date?
    var salePrice: Double = 0
    var note: String = ""
    var valuationsData: Data?
    var createdAt: Date = Date()
    /// 目标日均花费：日均降到这个数，就算「用回本了」，可以换了。0 表示没设
    var targetDailyCost: Double = 0
    /// 附属账目（配件、续费）的金额合计和明细，由 refreshAddOns 根据流水维护
    var addOnTotal: Double = 0
    var addOnsData: Data?
    /// 最早一笔附属账目的日期（续费可能早于标记为「买入」的那笔）
    var firstAddOnDate: Date?

    init(name: String, category: String = "其他", purchaseDate: Date = .now, price: Double,
         method: DepreciationMethod = .straight, lifeYears: Double = 5, residualRate: Double = 0.1,
         note: String = "") {
        self.name = name
        self.category = category
        self.purchaseDate = purchaseDate
        self.price = price
        self.methodRaw = method.rawValue
        self.lifeYears = lifeYears
        self.residualRate = residualRate
        self.note = note
    }

    var method: DepreciationMethod {
        get { DepreciationMethod(rawValue: methodRaw) ?? .straight }
        set { methodRaw = newValue.rawValue }
    }

    /// 附属账目：日期 + 金额（人民币）
    var addOns: [ValuePoint] {
        guard let addOnsData else { return [] }
        return (try? JSONDecoder().decode([ValuePoint].self, from: addOnsData)) ?? []
    }

    /// 买入价 + 附属账目，一共花了多少
    var totalCost: Double { price + addOnTotal }

    /// 开始花钱的那天：买入日和附属账目里最早的一天，日均从这天算起
    var startDate: Date {
        guard let firstAddOnDate, firstAddOnDate < purchaseDate else { return purchaseDate }
        return firstAddOnDate
    }

    /// 按挂在这件物品下的附属流水，重新算附属金额
    func refreshAddOns(in context: ModelContext) {
        let id = self.id
        let list = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.assetID == id && $0.isAddOn }))) ?? []
        let points = list.map { ValuePoint(date: $0.date, value: $0.cny, note: $0.note) }.sorted { $0.date < $1.date }
        addOnTotal = points.reduce(0) { $0 + $1.value }
        addOnsData = points.isEmpty ? nil : try? JSONEncoder().encode(points)
        firstAddOnDate = points.first?.date
    }

    /// 刷新全部物品（导入数据、删除流水后用）
    static func refreshAllAddOns(in context: ModelContext) {
        for a in (try? context.fetch(FetchDescriptor<Asset>())) ?? [] { a.refreshAddOns(in: context) }
    }

    /// 刷新某个 id 的物品
    static func refreshAddOns(id: UUID?, in context: ModelContext) {
        guard let id else { return }
        try? context.fetch(FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })).first?.refreshAddOns(in: context)
    }

    var valuations: [ValuePoint] {
        get {
            guard let valuationsData else { return [] }
            return (try? JSONDecoder().decode([ValuePoint].self, from: valuationsData)) ?? []
        }
        set {
            valuationsData = try? JSONEncoder().encode(newValue.sorted { $0.date < $1.date })
        }
    }
}

enum AssetCategory {
    static let all = ["数码", "家电", "家具", "交通", "服饰", "运动", "乐器", "珠宝", "收藏", "房产", "其他"]

    static func icon(_ name: String) -> String {
        switch name {
        case "数码": return "laptopcomputer"
        case "家电": return "tv"
        case "家具": return "sofa"
        case "交通": return "car"
        case "服饰": return "tshirt"
        case "运动": return "figure.run"
        case "乐器": return "guitars"
        case "珠宝": return "sparkles"
        case "收藏": return "star"
        case "房产": return "house"
        default: return "shippingbox"
        }
    }

    /// 根据账单分类猜物品类别
    static func guess(from e: LedgerEntry) -> String {
        let text = e.category + e.subcategory + e.note
        let rules: [(String, [String])] = [
            ("数码", ["数码", "电子", "手机", "电脑", "摄像", "相机", "iPad", "Mac", "耳机", "大疆"]),
            ("家电", ["家电", "电器"]),
            ("家具", ["家具", "家居"]),
            ("服饰", ["衣", "鞋", "包", "服"]),
            ("运动", ["运动", "健身", "球"]),
            ("乐器", ["乐器", "琴", "吉他"]),
            ("珠宝", ["珠宝", "首饰", "黄金", "手表"]),
            ("收藏", ["收藏", "ptcg", "卡牌", "手办", "二次元"]),
            ("交通", ["汽车", "电动车", "自行车"]),
        ]
        return rules.first { $0.1.contains { text.localizedCaseInsensitiveContains($0) } }?.0 ?? "其他"
    }

    /// 不同类别默认打算用几年（用来推荐目标日均）
    static func targetYears(_ name: String) -> Double {
        switch name {
        case "数码": return 3
        case "家电": return 8
        case "家具": return 10
        case "交通": return 8
        case "服饰": return 2
        case "运动": return 3
        case "乐器": return 10
        case "珠宝", "收藏": return 10
        case "房产": return 30
        default: return 3
        }
    }

    static func suggestedTarget(price: Double, category: String) -> Double {
        niceRound(price / (targetYears(category) * 365))
    }

    /// 取整成好记的数
    static func niceRound(_ v: Double) -> Double {
        if v >= 100 { return (v / 10).rounded() * 10 }
        if v >= 10 { return v.rounded() }
        if v >= 1 { return (v * 2).rounded() / 2 }
        return max((v * 10).rounded() / 10, 0.1)
    }

    /// 不同类别的默认折旧参数
    static func defaults(_ name: String) -> (DepreciationMethod, Double, Double) {
        switch name {
        case "数码": return (.accelerated, 4, 0.1)
        case "家电": return (.straight, 8, 0.05)
        case "家具": return (.straight, 10, 0.05)
        case "交通": return (.accelerated, 10, 0.2)
        case "服饰": return (.straight, 3, 0)
        case "运动": return (.straight, 5, 0.1)
        case "乐器": return (.straight, 15, 0.3)
        case "珠宝", "收藏", "房产": return (.none, 30, 1)
        default: return (.straight, 5, 0.05)
        }
    }
}

/// 账户设置：分组、是否计入净资产
@Model
final class AccountInfo {
    var name: String = ""
    var group: String = ""
    var excluded: Bool = false
    var currency: String = "CNY"

    init(name: String, group: String, excluded: Bool = false, currency: String = "CNY") {
        self.name = name
        self.group = group
        self.excluded = excluded
        self.currency = currency
    }
}

enum AccountGroup {
    static let defaults = ["银行卡", "电子钱包", "信用账户", "储值卡", "投资理财", "其他"]
    private static let key = "accountGroups"

    /// 账户分类（用户可新建、改名、删除、排序）
    static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? defaults }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 分类列表，再补上数据里用到但列表里没有的
    static func ordered(including used: some Sequence<String>) -> [String] {
        var list = all
        for g in used where !g.isEmpty && !list.contains(g) { list.append(g) }
        return list
    }

    static func guess(_ name: String) -> String {
        let n = name.lowercased()
        if ["花呗", "白条", "月付", "信用", "借呗"].contains(where: n.contains) { return "信用账户" }
        if ["理财", "基金", "定存", "股票", "证券"].contains(where: n.contains) { return "投资理财" }
        if ["银行", "招行", "汇丰", "工行", "建行", "农行", "中行", "交行", "存款"].contains(where: n.contains) { return "银行卡" }
        if ["微信", "支付宝", "零钱", "余额宝", "paypal"].contains(where: n.contains) { return "电子钱包" }
        if ["余额", "卡", "卷", "券", "会员", "储值"].contains(where: n.contains) { return "储值卡" }
        return "其他"
    }

    static func icon(_ group: String) -> String {
        switch group {
        case "银行卡": return "building.columns"
        case "电子钱包": return "iphone"
        case "信用账户": return "creditcard"
        case "储值卡": return "giftcard"
        case "投资理财": return "chart.line.uptrend.xyaxis"
        default: return "wallet.pass"
        }
    }
}
