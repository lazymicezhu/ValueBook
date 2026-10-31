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
    /// 有的物品（比如订阅）不需要目标日均
    @State private var useTarget = true
    @State private var method: DepreciationMethod = .accelerated
    @State private var lifeYears = 4.0
    @State private var residualPct = 10.0
    @State private var note = ""
    @State private var addExpense = false
    @State private var account = ""
    @State private var loaded = false

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
                    .onChange(of: priceText) { _, _ in suggestTarget() }
                    DatePicker("买入日期", selection: $date, displayedComponents: .date)
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
                    if a.hasTarget { targetText = String(format: "%g", a.targetDailyCost); targetEdited = true }
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

    /// 用户没手动改过目标时，按类别推荐一个
    private func suggestTarget() {
        guard !targetEdited || targetText.isEmpty, let price, price > 0 else { return }
        targetText = String(format: "%g", AssetCategory.suggestedTarget(price: price, category: category))
    }

    private func save() {
        guard let price else { return }
        let a = asset ?? Asset(name: name, price: price)
        a.name = name
        a.category = category
        a.purchaseDate = date
        a.price = price
        a.targetDailyCost = useTarget ? (Double(targetText) ?? 0) : 0
        a.method = method
        a.lifeYears = lifeYears
        a.residualRate = residualPct / 100
        a.note = note
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

/// 设置目标日均花费
struct TargetSection: View {
    let price: Double?
    let purchaseDate: Date
    /// 附属账目（各自按付款日平摊）
    var addOns: [ValuePoint] = []
    @Binding var enabled: Bool
    @Binding var targetText: String
    @Binding var edited: Bool

    var body: some View {
        Section {
            Toggle("设定目标日均", isOn: $enabled.animation())
            if enabled {
            HStack {
                Text("目标日均")
                TextField("如 10", text: $targetText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: targetText) { _, _ in edited = true }
                Text("元/天").foregroundStyle(.secondary)
            }
            if let price, price > 0 {
                HStack {
                    Text("按年数").font(.subheadline).foregroundStyle(.secondary)
                    ForEach([1.0, 2, 3, 5, 8], id: \.self) { y in
                        Button("\(Int(y))年") {
                            targetText = String(format: "%g", AssetCategory.niceRound(price / (y * 365)))
                            edited = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let t = Double(targetText), t > 0 {
                    let payments = [ValuePoint(date: purchaseDate, value: price)] + addOns
                    let start = payments.map(\.date).min() ?? purchaseDate
                    let reach = Asset.reachDate(of: payments, target: t)
                    let days = max(start.days(to: reach) + 1, 1)
                    let left = Date.now.days(to: reach)
                    Text(left > 0
                         ? "要用满 \(days) 天（约 \(String(format: "%.1f", Double(days) / 365)) 年），\(Fmt.day.string(from: reach)) 达标，还有 \(left) 天"
                         : "要用满 \(days) 天，已经在 \(Fmt.day.string(from: reach)) 达标，可以换了 ✓")
                        .font(.caption)
                        .foregroundStyle(left > 0 ? Color.secondary : Color.green)
                }
            }
            }
        } header: {
            Text("什么时候可以换")
        } footer: {
            Text(enabled ? "日均花费：每一笔钱（买入、配件、续费）各自 ÷ 它付款到今天的天数，再加起来。用得越久日均越低，降到目标就算用回本了，可以换新的。"
                 : "不设目标：只记录日均花费，不显示进度和达标提醒。适合订阅、会员这类一直在用的东西。")
        }
    }
}
