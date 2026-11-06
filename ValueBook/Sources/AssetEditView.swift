import SwiftUI
import SwiftData

struct AssetEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let asset: Asset?
    /// 从某笔账单生成物品
    var source: LedgerEntry? = nil

    @State private var name = ""
    @State private var category = "数码"
    @State private var date = Date.now
    @State private var priceText = ""
    @State private var targetText = ""
    @State private var targetEdited = false
    /// targetText 是想用的年数。有的物品（比如订阅）不需要设
    @State private var useTarget = true
    @State private var method: DepreciationMethod = .accelerated
    @State private var lifeYears = 4.0
    @State private var residualPct = 10.0
    @State private var note = ""
    @State private var addExpense = false
    @State private var account = ""
    @State private var loaded = false
    @State private var groupName = ""
    @State private var askGroup = false
    @State private var newGroup = ""
    @Query private var allAssets: [Asset]

    private var price: Double? { Double(priceText).flatMap { $0 >= 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如 MacBook Pro）", text: $name)
                    Picker("类别", selection: $category) {
                        ForEach(AssetCategory.all, id: \.self) { Label($0, systemImage: AssetCategory.icon($0)).tag($0) }
                    }
                    .onChange(of: category) { _, c in
                        guard loaded else { return }
                        if asset == nil {
                            let d = AssetCategory.defaults(c)
                            method = d.0; lifeYears = d.1; residualPct = d.2 * 100
                        }
                        suggestTarget()
                    }
                    HStack {
                        Text("买入价格")
                        TextField("0.00", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    DatePicker("买入日期", selection: $date, displayedComponents: .date)
                    HStack {
                        Text("大类")
                        Spacer()
                        Menu {
                            Button("不归类") { groupName = "" }
                            let names = Set(AssetGroups.names(allAssets) + (groupName.isEmpty ? [] : [groupName])).sorted()
                            if !names.isEmpty {
                                Divider()
                                ForEach(names, id: \.self) { n in
                                    Button { groupName = n } label: {
                                        if n == groupName { Label(n, systemImage: "checkmark") } else { Text(n) }
                                    }
                                }
                            }
                            Divider()
                            Button { newGroup = ""; askGroup = true } label: { Label("新建大类…", systemImage: "plus") }
                        } label: {
                            HStack(spacing: 4) {
                                Text(groupName.isEmpty ? "不归类" : groupName)
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                            .foregroundStyle(groupName.isEmpty ? .secondary : Theme.accent)
                        }
                    }
                }

                TargetSection(price: price, purchaseDate: date, addOns: asset?.addOns ?? [], enabled: $useTarget,
                              targetText: $targetText, edited: $targetEdited)
                    .onChange(of: useTarget) { _, on in if on { suggestTarget() } }

                Section("备注") { TextField("备注", text: $note, axis: .vertical) }
                if asset == nil && source == nil {
                    Section {
                        Toggle("同时在账本记一笔支出", isOn: $addExpense)
                        if addExpense { TextField("付款账户", text: $account) }
                    }
                }
            }
            .alert("新建大类", isPresented: $askGroup) {
                TextField("如 摄影、家具", text: $newGroup)
                Button("取消", role: .cancel) {}
                Button("好") {
                    let n = newGroup.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { groupName = n }
                }
            }
            .navigationTitle(asset == nil ? "添加物品" : "编辑物品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(name.isEmpty || price == nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                if let a = asset {
                    name = a.name; category = a.category; date = a.purchaseDate
                    priceText = String(format: "%g", a.price); method = a.method
                    lifeYears = a.lifeYears; residualPct = a.residualRate * 100; note = a.note
                    groupName = a.groupName
                    if a.hasTarget { targetText = String(format: "%g", a.effectiveTargetYears); targetEdited = true }
                    useTarget = a.hasTarget
                } else if let e = source {
                    name = e.note.isEmpty ? e.subcategory : e.note
                    category = AssetCategory.guess(from: e)
                    let d = AssetCategory.defaults(category)
                    method = d.0; lifeYears = d.1; residualPct = d.2 * 100
                    date = e.date
                    priceText = String(format: "%.2f", e.cny)
                }
                suggestTarget()
                DispatchQueue.main.async { loaded = true }
            }
        }
    }

    /// 用户没手动改过年数时，按类别推荐一个
    private func suggestTarget() {
        guard !targetEdited || targetText.isEmpty else { return }
        targetText = String(format: "%g", AssetCategory.targetYears(category))
    }

    private func save() {
        guard let price else { return }
        let a = asset ?? Asset(name: name, price: price)
        a.name = name
        a.category = category
        a.purchaseDate = date
        a.price = price
        a.targetYears = useTarget ? max(Double(targetText) ?? 0, 0) : 0
        a.targetDailyCost = 0
        a.method = method
        a.lifeYears = lifeYears
        a.residualRate = residualPct / 100
        a.note = note
        AssetGroups.assign(a, to: groupName, in: allAssets)
        if asset == nil {
            context.insert(a)
            if let source {
                source.assetID = a.id
            } else if addExpense {
                let e = LedgerEntry(type: .expense, date: date, amount: price, category: "购物",
                                    subcategory: category, account: account, note: name)
                e.assetID = a.id
                context.insert(e)
            }
        } else {
            let id = a.id
            if let linked = try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.assetID == id })) {
                for e in linked where e.currency == "CNY" && !e.isAddOn { e.amount = price; e.date = date }
            }
        }
        dismiss()
    }
}

/// 设置想用多少年：用满就可以换了，跟花了多少钱无关
struct TargetSection: View {
    let price: Double?
    let purchaseDate: Date
    /// 附属账目（各自按付款日平摊），只用来估算到时的日均
    var addOns: [ValuePoint] = []
    @Binding var enabled: Bool
    /// 年数
    @Binding var targetText: String
    @Binding var edited: Bool

    var body: some View {
        Section {
            Toggle("设定使用年限", isOn: $enabled.animation())
            if enabled {
                HStack {
                    Text("想用")
                    TextField("如 3", text: $targetText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: targetText) { _, _ in edited = true }
                    Text("年").foregroundStyle(.secondary)
                }
                HStack {
                    ForEach([1.0, 2, 3, 5, 8], id: \.self) { y in
                        Button("\(Int(y))年") {
                            targetText = String(format: "%g", y)
                            edited = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let y = Double(targetText), y > 0 {
                    let payments = [ValuePoint(date: purchaseDate, value: price ?? 0)] + addOns
                    let start = payments.map(\.date).min() ?? purchaseDate
                    let total = max(Int((y * 365).rounded()), 1)
                    let reach = start.adding(days: total - 1)
                    let left = total - max(start.days(to: .now) + 1, 1)
                    let cost = Asset.dailyCost(of: payments, at: reach)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(left > 0
                             ? "用满 \(total) 天，\(Fmt.day.string(from: reach)) 可以换，还有 \(left) 天"
                             : "已经用满 \(total) 天（\(Fmt.day.string(from: reach))），可以换了 ✓")
                            .foregroundStyle(left > 0 ? Color.secondary : Color.green)
                        if (price ?? 0) > 0 {
                            Text("按现有花费，到那天日均约 \(Fmt.yuan(cost))/天").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("什么时候可以换")
        } footer: {
            Text(enabled ? "从第一笔付款起用满这么多年就可以换新的，之后再加配件、续费也不会推迟。日均花费照常记录，只作参考。"
                 : "不设年限：只记录日均花费，不显示进度和达标提醒。适合订阅、会员这类一直在用的东西。")
        }
    }
}
