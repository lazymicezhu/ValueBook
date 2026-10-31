import Foundation
import SwiftData

enum DataTransfer {
    static func csvField(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func exportEntries(_ entries: [LedgerEntry]) throws -> URL {
        var lines = ["交易类型,日期,类别,子类别,账户,账户2,账户币种,金额,成员,商家,项目,备注"]
        for e in entries.sorted(by: { $0.date < $1.date }) {
            lines.append([e.typeRaw, stamp.string(from: e.date), e.category, e.subcategory, e.account,
                          e.toAccount, e.currency, String(format: "%.2f", e.amount), e.member, e.merchant, e.project, e.note]
                .map(csvField).joined(separator: ","))
        }
        return try write(lines, name: "价值账本-流水-\(Fmt.day.string(from: .now)).csv")
    }

    static func exportAssets(_ assets: [Asset]) throws -> URL {
        var lines = ["名称,类别,购买日期,购买价格,折旧方式,使用年限,残值率,当前价值,持有天数,日均成本,状态,处置日期,处置价格,备注"]
        for a in assets.sorted(by: { $0.purchaseDate < $1.purchaseDate }) {
            lines.append([a.name, a.category, Fmt.day.string(from: a.purchaseDate), String(format: "%.2f", a.price),
                          a.methodRaw, String(format: "%g", a.lifeYears), String(format: "%g", a.residualRate),
                          String(format: "%.2f", a.currentValue), "\(a.daysHeld())", String(format: "%.2f", a.dailyCost),
                          a.isRetired ? "已处置" : "在用", a.retiredDate.map { Fmt.day.string(from: $0) } ?? "",
                          a.isRetired ? String(format: "%.2f", a.salePrice) : "", a.note]
                .map(csvField).joined(separator: ","))
        }
        return try write(lines, name: "价值账本-物品-\(Fmt.day.string(from: .now)).csv")
    }

    private static func write(_ lines: [String], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var data = Data([0xEF, 0xBB, 0xBF]) // BOM，Excel 打开不乱码
        data.append(lines.joined(separator: "\n").data(using: .utf8)!)
        try data.write(to: url)
        return url
    }
}
