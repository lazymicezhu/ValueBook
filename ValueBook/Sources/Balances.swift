import Foundation
import SwiftData

/// 根据流水算每个账户的余额（账户自己的币种）
struct AccountBalance: Identifiable, Hashable {
    var name: String
    var currency: String
    var balance: Double
    var count: Int
    var last: Date
    var group: String
    var excluded: Bool
    var id: String { name }
    var cny: Double { balance * Rates.rate(currency) }
}

enum Balances {
    static func compute(_ entries: [LedgerEntry], infos: [AccountInfo]) -> [AccountBalance] {
        var bal: [String: Double] = [:]
        var cur: [String: String] = [:]
        var count: [String: Int] = [:]
        var last: [String: Date] = [:]
        func touch(_ name: String, _ delta: Double, _ currency: String, _ date: Date) {
            guard !name.isEmpty else { return }
            bal[name, default: 0] += delta
            if cur[name] == nil { cur[name] = currency.isEmpty ? "CNY" : currency }
            count[name, default: 0] += 1
            last[name] = max(last[name] ?? .distantPast, date)
        }
        for e in entries {
            switch e.type {
            case .expense: touch(e.account, -e.amount, e.currency, e.date)
            case .income: touch(e.account, e.amount, e.currency, e.date)
            case .transfer:
                if e.isBalanceAdjust {
                    touch(e.account, e.amount, e.currency, e.date)
                } else {
                    touch(e.account, -e.amount, e.currency, e.date)
                    touch(e.toAccount, e.receivedAmount, e.toCurrency.isEmpty ? e.currency : e.toCurrency, e.date)
                }
            }
        }
        let info = Dictionary(infos.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return bal.keys.map { name in
            let i = info[name]
            let v = bal[name] ?? 0
            return AccountBalance(name: name, currency: cur[name] ?? "CNY", balance: abs(v) < 0.005 ? 0 : v,
                                  count: count[name] ?? 0, last: last[name] ?? .distantPast,
                                  group: i?.group ?? AccountGroup.guess(name), excluded: i?.excluded ?? false)
        }
    }
}
