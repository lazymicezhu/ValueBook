import SwiftUI
import SwiftData

/// 分类汇总（全部时间）
struct CategorySummaryView: View {
    @Query private var entries: [LedgerEntry]
    @State private var kind: EntryType = .expense

    var body: some View {
        var sums: [String: (Double, Int)] = [:]
        for e in entries where e.type == kind {
            let k = e.category.isEmpty ? "未分类" : e.category
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.0 + e.cny, cur.1 + 1)
        }
        let list = sums.sorted { $0.value.0 > $1.value.0 }
        let total = list.reduce(0) { $0 + $1.value.0 }
        return List {
            Section {
                Picker("", selection: $kind) {
                    Text("支出").tag(EntryType.expense)
                    Text("收入").tag(EntryType.income)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(list, id: \.key) { name, v in
                    NavigationLink(value: Route.category(type: kind.rawValue, name: name == "未分类" ? "" : name)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: CategoryIcon.symbol(name)).foregroundStyle(kind == .expense ? Theme.expense : Theme.income)
                                    .frame(width: 24)
                                Text(name)
                                Text("\(v.1)笔").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Fmt.plain(v.0)).monospacedDigit()
                            }
                            ProgressView(value: total > 0 ? v.0 / total : 0)
                                .tint(kind == .expense ? Theme.expense : Theme.income)
                        }
                    }
                }
            } header: {
                Text("全部时间 合计 \(Fmt.plain(total))")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("分类")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 搜索全部流水
struct SearchFlowView: View {
    @State private var text = ""
    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView("搜索流水", systemImage: "magnifyingglass", description: Text("输入备注、分类、账户等关键字"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            } else {
                EntryList(filter: Filters.search(text), limit: 500, showYear: true)
            }
        }
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }
}
