import Foundation

/// 解析随手记等记账软件导出的 CSV。只依赖 Foundation，方便单独测试。
struct ParsedRow {
    var type: String      // 支出 / 收入 / 转账
    var rawType: String
    var date: Date
    var amount: Double
    var category: String
    var subcategory: String
    var account: String
    var toAccount: String
    var member: String
    var merchant: String
    var project: String
    var note: String
    var currency: String = "CNY"
    var linkID: String = ""
    var toAmount: Double = 0
    var toCurrency: String = ""
}

struct ParseResult {
    var rows: [ParsedRow]
    var skipped: Int
    var header: [String]
    var unknownTypes: [String: Int]
}

enum CSVParseError: LocalizedError {
    case encoding, noHeader(String)
    var errorDescription: String? {
        switch self {
        case .encoding: return "无法识别文件编码"
        case .noHeader(let first): return "找不到包含「日期」和「金额」的表头。文件开头：\(first)"
        }
    }
}

enum CSVParser {
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .utf16)
    }

    /// 支持引号、引号内换行、逗号或制表符分隔
    static func split(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while true {
            let c: Character
            if let p = pending { c = p; pending = nil } else if let n = chars.next() { c = n } else { break }
            if inQuotes {
                if c == "\"" {
                    if let n = chars.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    static let aliases: [String: [String]] = [
        "type": ["交易类型", "收支类型", "类型", "收/支"],
        "date": ["日期", "交易时间", "时间", "记账时间"],
        "category": ["类别", "分类", "一级分类", "一级类别", "支出大类", "收入大类", "大类"],
        "subcategory": ["子类别", "子分类", "二级分类", "二级类别", "支出小类", "收入小类", "小类"],
        "account": ["账户", "账户1", "出账账户", "支出账户", "收入账户", "付款账户", "转出账户"],
        "toAccount": ["账户2", "入账账户", "转入账户", "收款账户"],
        "amount": ["金额", "交易金额", "金额(元)", "人民币金额"],
        "member": ["成员"],
        "merchant": ["商家"],
        "project": ["项目"],
        "note": ["备注", "说明", "描述"],
        "currency": ["账户币种", "币种", "货币"],
        "linkID": ["关联Id", "关联ID", "关联id"],
    ]

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\t")))
    }

    static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd",
        "yyyy/M/d HH:mm:ss", "yyyy/M/d H:mm", "yyyy/M/d",
        "yyyy-M-d HH:mm:ss", "yyyy-M-d H:mm", "yyyy-M-d",
        "yyyy年M月d日 HH:mm:ss", "yyyy年M月d日 HH:mm", "yyyy年M月d日",
        "yyyy.MM.dd HH:mm", "yyyy.MM.dd", "yyyyMMdd",
    ]

    static let formatters: [DateFormatter] = dateFormats.map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = $0
        return f
    }

    static func parseDate(_ s: String) -> Date? {
        let s = clean(s)
        guard !s.isEmpty else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        // Excel 序列号
        if let n = Double(s), n > 20000, n < 80000 {
            return Date(timeIntervalSince1970: (n - 25569) * 86400 - Double(TimeZone.current.secondsFromGMT()))
        }
        return nil
    }

    static func parseAmount(_ s: String) -> Double? {
        var t = clean(s)
        for junk in ["¥", "￥", ",", "，", "元", "RMB", "CNY", " "] { t = t.replacingOccurrences(of: junk, with: "") }
        if t.hasPrefix("(") && t.hasSuffix(")") { t = "-" + t.dropFirst().dropLast() }
        return Double(t)
    }

    static func normalizeType(_ raw: String) -> String? {
        if raw.contains("支出") || raw == "支" { return "支出" }
        if raw.contains("收入") || raw == "收" { return "收入" }
        if raw.contains("转") { return "转账" }
        return nil
    }

    static func parse(data: Data) throws -> ParseResult {
        guard let text = decode(data) else { throw CSVParseError.encoding }
        let firstLines = text.split(whereSeparator: \.isNewline).prefix(12).map(String.init)
        let tabs = firstLines.reduce(0) { $0 + $1.filter { $0 == "\t" }.count }
        let commas = firstLines.reduce(0) { $0 + $1.filter { $0 == "," }.count }
        let table = split(text, delimiter: tabs > commas ? "\t" : ",")

        // 随手记导出的文件前面可能有标题行，找真正的表头
        guard let headerIndex = table.prefix(30).firstIndex(where: { row in
            let cells = row.map(clean)
            return cells.contains(where: { aliases["date"]!.contains($0) }) && cells.contains(where: { $0.contains("金额") })
        }) else {
            throw CSVParseError.noHeader(firstLines.prefix(3).joined(separator: " / "))
        }
        let header = table[headerIndex].map(clean)
        var col: [String: Int] = [:]
        for (key, names) in aliases {
            for name in names {
                if let i = header.firstIndex(of: name), !col.values.contains(i) { col[key] = i; break }
            }
        }
        if col["amount"] == nil, let i = header.firstIndex(where: { $0.contains("金额") }) { col["amount"] = i }

        var rows: [ParsedRow] = []
        var skipped = 0
        var unknown: [String: Int] = [:]
        for raw in table[(headerIndex + 1)...] {
            func get(_ k: String) -> String {
                guard let i = col[k], i < raw.count else { return "" }
                return clean(raw[i])
            }
            guard let date = parseDate(get("date")), let amt = parseAmount(get("amount")) else { skipped += 1; continue }
            let rawType = get("type")
            var type: String
            if let t = normalizeType(rawType) {
                type = t
            } else if rawType.isEmpty {
                type = amt < 0 ? "支出" : "收入"
            } else {
                unknown[rawType, default: 0] += 1
                type = "转账"
            }
            var category = get("category")
            if type == "转账" && category.isEmpty && !["", "转账", "转出", "转入"].contains(rawType) { category = rawType }
            let currency = get("currency").isEmpty ? "CNY" : get("currency").uppercased()
            rows.append(ParsedRow(type: type, rawType: rawType, date: date,
                                  amount: amt,
                                  category: category, subcategory: get("subcategory"),
                                  account: get("account"), toAccount: get("toAccount"),
                                  member: get("member"), merchant: get("merchant"),
                                  project: get("project"), note: get("note"),
                                  currency: currency, linkID: get("linkID")))
        }
        rows = mergeTransfers(rows)
        return ParseResult(rows: rows, skipped: skipped, header: header, unknownTypes: unknown)
    }

    /// 随手记把一笔转账拆成「转出」「转入」两行，用关联Id 合并成一行
    static func mergeTransfers(_ rows: [ParsedRow]) -> [ParsedRow] {
        var byLink: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() where !r.linkID.isEmpty && (r.rawType == "转出" || r.rawType == "转入") {
            byLink[r.linkID, default: []].append(i)
        }
        var drop = Set<Int>()
        var out = rows
        for (_, idx) in byLink where idx.count == 2 {
            guard let o = idx.first(where: { rows[$0].rawType == "转出" }),
                  let n = idx.first(where: { rows[$0].rawType == "转入" }) else { continue }
            var m = rows[o]
            let into = rows[n]
            m.toAccount = into.account
            m.toAmount = into.amount
            m.toCurrency = into.currency
            if m.note.isEmpty { m.note = into.note }
            out[o] = m
            drop.insert(n)
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// 生成去重 key：同样内容的记录在文件中出现第 n 次
    static func keys(for rows: [ParsedRow]) -> [String] {
        var seen: [String: Int] = [:]
        return rows.map { r in
            let base = "\(Int(r.date.timeIntervalSince1970))|\(r.type)|\(String(format: "%.2f", r.amount))|\(r.category)|\(r.subcategory)|\(r.account)|\(r.toAccount)|\(r.currency)|\(r.note)"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return "\(base)#\(n)"
        }
    }
}
