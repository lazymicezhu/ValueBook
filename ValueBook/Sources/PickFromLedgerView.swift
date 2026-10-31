import SwiftUI
import SwiftData

/// 从历史支出里挑出买过的东西，一键变成物品
struct PickFromLedgerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pick.minAmount") private var minAmount = 500.0
    @AppStorage("pick.goodsOnly") private var goodsOnly = true
    @State private var search = ""
    @State private var picking: LedgerEntry?

    var body: some View {
        NavigationStack {
            PickList(minAmount: minAmount, goodsOnly: goodsOnly, search: search, picking: $picking)
                .searchable(text: $search, prompt: "搜索分类、备注")
                .safeAreaInset(edge: .top) {
                    VStack(spacing: 6) {
                        HStack {
                            Text("金额不低于")
                            Picker("", selection: $minAmount) {
                                ForEach([100.0, 300, 500, 1000, 2000, 5000], id: \.self) { Text("¥\(Int($0))").tag($0) }
                            }
                            Spacer()
                            Toggle("只看购物类", isOn: $goodsOnly).fixedSize()
                        }
                        .font(.subheadline)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .background(.bar)
                }
                .navigationTitle("从账单挑选物品")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $picking) { AssetEditView(asset: nil, source: $0) }
        }
    }
}

private struct PickList: View {
    @Query private var entries: [LedgerEntry]
    let goodsOnly: Bool
    let search: String
    @Binding var picking: LedgerEntry?

    static let goodsWords = ["购物", "数码", "电子", "衣", "鞋", "包", "摄像", "相机", "家电", "家具", "家居", "健身", "运动",
                             "乐器", "ptcg", "收藏", "手办", "首饰", "珠宝", "手表", "电脑", "手机"]

    init(minAmount: Double, goodsOnly: Bool, search: String, picking: Binding<LedgerEntry?>) {
        self.goodsOnly = goodsOnly
        self.search = search
        _picking = picking
        let expense = EntryType.expense.rawValue
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.typeRaw == expense && $0.amount >= minAmount && $0.assetID == nil },
                         sort: \LedgerEntry.date, order: .reverse)
    }

    private var shown: [LedgerEntry] {
        entries.filter { e in
            let text = e.category + e.subcategory + e.note + e.merchant
            if goodsOnly && !Self.goodsWords.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return false }
            if !search.isEmpty && !text.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(shown) { e in
                    Button { picking = e } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.note.isEmpty ? e.displayCategory : e.note)
                                Text("\(Fmt.day.string(from: e.date)) · \(e.displayCategory)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.money(e.amount, e.currency)).monospacedDigit()
                            Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(shown.isEmpty ? "没有符合条件的支出" : "共 \(shown.count) 笔，点一笔把它变成物品。已经变成物品的不会再出现。")
            }
        }
    }
}
