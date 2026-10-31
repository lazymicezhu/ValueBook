import Foundation
import SwiftData
import Observation

/// 统一的导入入口：设置页选文件、从微信等「用其他应用打开」、App 文件夹里的 CSV 都走这里
@MainActor
@Observable
final class Importer {
    static let shared = Importer()

    var running = false
    var progress: Double = 0
    var stage = ""
    var message: String?

    /// 读文件：处理安全作用域、iCloud 未下载、「拷贝到」收件箱等情况
    nonisolated static func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // iCloud 里没下载到本地的文件，先触发下载
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = Result { try Data(contentsOf: readURL, options: .mappedIfSafe) }
        }
        if case .success(let data) = result { return data }
        // 协调读取失败时再直接读一次
        if let data = try? Data(contentsOf: url) { return data }
        if let coordError { throw coordError }
        return try result.get()
    }

    func importFile(at url: URL, into context: ModelContext) async {
        guard !running else { message = "正在导入，请稍候"; return }
        running = true
        progress = 0
        stage = "读取文件…"
        defer { running = false }

        let isInbox = url.path.contains("/Inbox/")
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { () -> (ParseResult, [String]) in
                let data = try Importer.readFile(url)
                let p = try CSVParser.parse(data: data)
                return (p, CSVParser.keys(for: p.rows))
            }.value
            if isInbox { try? FileManager.default.removeItem(at: url) }
            message = try await insert(parsed.0, keys: parsed.1, into: context, fileName: url.lastPathComponent)
        } catch {
            message = "导入失败：\(error.localizedDescription)\n\n文件：\(url.lastPathComponent)"
        }
    }

    /// 在主 context 里分批写入，界面能立即看到新数据（iOS 17 后台 context 写入时列表可能不刷新）
    private func insert(_ parsed: ParseResult, keys: [String], into context: ModelContext, fileName: String) async throws -> String {
        stage = "检查重复…"
        await Task.yield()
        var existing = Set<String>()
        var fetch = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.importKey != nil })
        fetch.propertiesToFetch = [\.importKey]
        for e in try context.fetch(fetch) { if let k = e.importKey { existing.insert(k) } }

        stage = "写入账单…"
        var inserted = 0, duplicates = 0
        let total = max(parsed.rows.count, 1)
        for (i, (row, key)) in zip(parsed.rows, keys).enumerated() {
            if existing.contains(key) {
                duplicates += 1
            } else {
                let entry = LedgerEntry(type: EntryType(rawValue: row.type) ?? .expense, date: row.date,
                                        amount: row.amount, category: row.category, subcategory: row.subcategory,
                                        account: row.account, toAccount: row.toAccount, member: row.member,
                                        merchant: row.merchant, project: row.project, note: row.note,
                                        importKey: key)
                entry.currency = row.currency
                entry.toAmount = row.toAmount
                entry.toCurrency = row.toCurrency
                context.insert(entry)
                inserted += 1
            }
            if i % 500 == 499 {
                progress = Double(i + 1) / Double(total)
                try context.save()
                await Task.yield()
            }
        }
        try context.save()
        progress = 1

        var text = "「\(fileName)」\n新增 \(inserted) 笔"
        if duplicates > 0 { text += "，跳过已导入的 \(duplicates) 笔" }
        if parsed.skipped > 0 { text += "，有 \(parsed.skipped) 行无法识别" }
        if let lo = parsed.rows.map(\.date).min(), let hi = parsed.rows.map(\.date).max() {
            text += "\n时间范围：\(Fmt.day.string(from: lo)) ~ \(Fmt.day.string(from: hi))"
        }
        if parsed.rows.isEmpty {
            text += "\n\n没有读到任何账单。识别到的表头：\(parsed.header.joined(separator: "、"))"
        }
        return text
    }

    /// App 文件夹（文件 App → 我的 iPhone → 价值账本）里的 CSV
    nonisolated static func documentCSVs() -> [URL] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        let dirs = [docs, docs.appendingPathComponent("Inbox")]
        return dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["csv", "txt", "tsv"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("import-log") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
