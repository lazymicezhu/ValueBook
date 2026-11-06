import SwiftUI
import SwiftData
import Charts

struct AssetDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var asset: Asset

    @State private var showEdit = false
    @State private var showRetire = false
    @State private var showAttach = false
    @State private var showAddEntry = false
    @State private var selected: Date?
    @State private var confirmDelete = false

    var body: some View {
        let curve = asset.usesMinAmortize ? asset.dailyCostSeries() : []
        let today = asset.dailyCost
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asset.isRetired ? "最终日均花费" : "到今天，平均每天花了").font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.yuan(today)).font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text("/ 天").font(.headline).foregroundStyle(.secondary)
                    }
                    Text((asset.addOnTotal != 0
                          ? "\(asset.addOns.count + 1) 笔花费各自按付款后的天数平摊，再相加"
                          : "\(Fmt.yuan(asset.price)) ÷ \(asset.daysHeld()) 天")
                         + (asset.isRetired && asset.salePrice > 0 ? "（扣除卖出的 \(Fmt.yuan(asset.salePrice))）" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if asset.hasTarget && !asset.isRetired {
                    VStack(alignment: .leading, spacing: 8) {
                        if asset.reachedTarget {
                            Label("已经用满 \(String(format: "%g", asset.effectiveTargetYears)) 年，可以换了！", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green).font(.headline)
                            if let d = asset.targetDate {
                                Text("\(Fmt.day.string(from: d)) 达标，已经多用了 \(d.days(to: .now)) 天")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Text("目标用 \(String(format: "%g", asset.effectiveTargetYears)) 年")
                                Spacer()
                                Text("还要用 \(asset.daysLeft ?? 0) 天").bold()
                            }
                            ProgressView(value: asset.targetProgress)
                            if let d = asset.targetDate {
                                Text("\(Fmt.day.string(from: d)) 用满（第 \(asset.targetTotalDays ?? 0) 天），之后就可以换了"
                                     + (asset.dailyCostAtTarget.map { "，按现有花费到时日均约 \(Fmt.yuan($0))/天" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if asset.usesMinAmortize {
                    DailyCostChart(asset: asset, curve: curve, today: today, selected: $selected)
                } else {
                    MonthlySpendChart(asset: asset)
                }
            } footer: {
                Text(asset.usesMinAmortize
                     ? "曲线是到每一天为止的日均花费，到今天为止。每次付款那天会跳高，之后慢慢降下来；按住曲线可以看某一天。"
                     : "柱子是每个月在它身上花的钱，虚线是月均；按住可以看某个月。")
            }

            AddOnSection(asset: asset, showAttach: $showAttach, showAddEntry: $showAddEntry)

            Section("信息") {
                InfoRow("买入日期", Fmt.day.string(from: asset.purchaseDate))
                if asset.startDate < asset.purchaseDate {
                    InfoRow("开始计算日期", Fmt.day.string(from: asset.startDate))
                }
                InfoRow("已用天数", "\(asset.daysHeld()) 天（\(String(format: "%.1f", Double(asset.daysHeld()) / 365)) 年）")
                InfoRow("类别", asset.category)
                if asset.isRetired, let d = asset.retiredDate {
                    InfoRow("处置日期", Fmt.day.string(from: d))
                    InfoRow("处置价格", Fmt.yuan(asset.salePrice))
                }
                if !asset.note.isEmpty { InfoRow("备注", asset.note) }
            }

            Section {
                if asset.isRetired {
                    Button("恢复为在用") {
                        asset.isRetired = false
                        asset.retiredDate = nil
                        asset.salePrice = 0
                    }
                } else {
                    Button("换掉了：卖掉 / 报废 / 送人") { showRetire = true }
                }
                Button("删除物品", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(asset.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("编辑") { showEdit = true } }
        .sheet(isPresented: $showEdit) { AssetEditView(asset: asset) }
        .sheet(isPresented: $showAttach, onDismiss: { asset.refreshAddOns(in: context) }) { AttachEntriesView(asset: asset) }
        .sheet(isPresented: $showAddEntry, onDismiss: { asset.refreshAddOns(in: context) }) { EntryEditView(entry: nil, attachTo: asset) }
        .onAppear { asset.refreshAddOns(in: context) }
        .sheet(isPresented: $showRetire) { RetireSheet(asset: asset) }
        .confirmationDialog("删除「\(asset.name)」？关联的账单（含附属账目）会保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let id = asset.id
                if let linked = try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.assetID == id })) {
                    for e in linked { e.assetID = nil; e.isAddOn = false }
                }
                context.delete(asset)
                dismiss()
            }
        }
    }
}

struct InfoRow: View {
    let title: String, value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }
}


struct RetireSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let asset: Asset
    @State private var date = Date.now
    @State private var priceText = ""
    @State private var addIncome = true

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("处置日期", selection: $date, in: asset.purchaseDate..., displayedComponents: .date)
                TextField("卖了多少钱（报废/送人填 0）", text: $priceText).keyboardType(.decimalPad)
                if (Double(priceText) ?? 0) > 0 {
                    Toggle("同时记一笔收入", isOn: $addIncome)
                }
            }
            .navigationTitle("处置物品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        let p = Double(priceText) ?? 0
                        asset.salePrice = p
                        asset.retiredDate = date
                        asset.isRetired = true
                        if p > 0 && addIncome {
                            let e = LedgerEntry(type: .income, date: date, amount: p, category: "其他收入",
                                                subcategory: "出售闲置", note: "出售 \(asset.name)")
                            context.insert(e)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 花费明细：买入那笔 + 挂在物品下的附属账目（配件、续费等）
private struct AddOnSection: View {
    @Environment(\.modelContext) private var context
    let asset: Asset
    @Binding var showAttach: Bool
    @Binding var showAddEntry: Bool
    /// 挂在这件物品下的全部账单：买入那笔 + 附属账目
    @Query private var linked: [LedgerEntry]
    @State private var editing: LedgerEntry?
    /// 分页：每页 5 笔
    @State private var page = 0
    private let pageSize = 5

    init(asset: Asset, showAttach: Binding<Bool>, showAddEntry: Binding<Bool>) {
        self.asset = asset
        _showAttach = showAttach
        _showAddEntry = showAddEntry
        let id = asset.id
        _linked = Query(filter: #Predicate<LedgerEntry> { $0.assetID == id },
                        sort: \LedgerEntry.date, order: .reverse)
    }

    private var addOns: [LedgerEntry] { linked.filter(\.isAddOn) }

    var body: some View {
        Section {
            // 手动添加、没有对应账单的物品，补一行买入（算作列表里的第一条）
            let synthetic = !linked.contains(where: { !$0.isAddOn })
            let count = linked.count + (synthetic ? 1 : 0)
            let pages = max((count + pageSize - 1) / pageSize, 1)
            let p = min(page, pages - 1)
            let lo = p * pageSize, hi = min(lo + pageSize, count)
            let off = synthetic ? 1 : 0
            if synthetic && lo == 0 {
                row(title: "\(asset.category) · 买入", date: asset.purchaseDate, detail: "买入", amount: Fmt.yuan(asset.price), cny: asset.price)
            }
            ForEach(Array(linked[max(lo - off, 0)..<max(hi - off, 0)])) { e in
                Button { editing = e } label: {
                    row(title: e.displayCategory, date: e.date,
                        detail: [e.isAddOn ? "" : "买入", e.note].filter { !$0.isEmpty }.joined(separator: " · "),
                        amount: Fmt.money(e.amount, e.currency), cny: e.cny)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if e.isAddOn { Button("移出") { detach(e) }.tint(.orange) }
                }
            }
            if pages > 1 {
                HStack {
                    Button { page = p - 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(p == 0)
                    Spacer()
                    Text("第 \(p + 1) / \(pages) 页 · 共 \(count) 笔")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { page = p + 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(p >= pages - 1)
                }
                .buttonStyle(.borderless)
            }
            if !addOns.isEmpty {
                InfoRow("一共花了", Fmt.yuan(asset.totalCost))
            }
            Button { showAddEntry = true } label: { Label("记一笔附属账目", systemImage: "plus") }
            Button { showAttach = true } label: { Label("从账单里挑选", systemImage: "list.bullet.rectangle") }
        } header: {
            Text("花费明细")
        } footer: {
            Text("配件、续费、会员年费等都可以挂在这件物品下，一起算进日均花费。左滑可移出（账单本身保留）。")
        }
        .sheet(item: $editing, onDismiss: { asset.refreshAddOns(in: context) }) { EntryEditView(entry: $0) }
    }

    /// 每一条花费统一格式：上面「大类 · 小类」，下面日期（和备注），右边金额
    private func row(title: String, date: Date, detail: String, amount: String, cny: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(([Fmt.day.string(from: date)] + (detail.isEmpty ? [] : [detail])).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount).monospacedDigit().foregroundStyle(.secondary)
                // 这一笔自己的日均：金额 ÷ 付款到今天（或处置日）的天数
                let end = asset.isRetired ? (asset.retiredDate ?? .now) : .now
                Text("\(Fmt.yuan(Asset.dailyCost(of: [ValuePoint(date: date, value: cny)], at: end, floor: asset.usesMinAmortize)))/天")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func detach(_ e: LedgerEntry) {
        e.assetID = nil
        e.isAddOn = false
        asset.refreshAddOns(in: context)
    }
}

/// 从账单里挑选支出，挂到物品下
struct AttachEntriesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let asset: Asset
    @Query private var entries: [LedgerEntry]
    @State private var search = ""

    init(asset: Asset) {
        self.asset = asset
        let expense = EntryType.expense.rawValue
        let id = asset.id
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.typeRaw == expense && ($0.assetID == nil || ($0.assetID == id && $0.isAddOn)) },
                         sort: \LedgerEntry.date, order: .reverse)
    }

    private func text(_ e: LedgerEntry) -> String { e.category + e.subcategory + e.note + e.merchant }

    var body: some View {
        let attached = entries.filter { $0.assetID == asset.id }
        let pool = entries.filter { $0.assetID == nil }
        let keyword = search.trimmingCharacters(in: .whitespaces)
        // 没搜索时，先列出备注里带物品名的（续费账单通常写着服务名）
        let related = keyword.isEmpty && !asset.name.isEmpty
            ? pool.filter { text($0).localizedCaseInsensitiveContains(asset.name) } : []
        let shown = keyword.isEmpty ? Array(pool.prefix(300)) : pool.filter { text($0).localizedCaseInsensitiveContains(keyword) }
        NavigationStack {
            List {
                if !attached.isEmpty {
                    Section("已挂在「\(asset.name)」下") { ForEach(attached) { row($0, on: true) } }
                }
                if !related.isEmpty {
                    Section("可能相关") { ForEach(related) { row($0, on: false) } }
                }
                Section {
                    ForEach(shown) { row($0, on: false) }
                } header: {
                    Text(keyword.isEmpty ? "最近的支出" : "搜索结果")
                } footer: {
                    Text(shown.isEmpty ? "没有符合条件的支出" : "点一笔挂到这件物品下，再点取消。已经属于其他物品的账单不会出现。")
                }
            }
            .searchable(text: $search, prompt: "搜索分类、备注、商家")
            .navigationTitle("挑选附属账目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func row(_ e: LedgerEntry, on: Bool) -> some View {
        Button {
            e.assetID = on ? nil : asset.id
            e.isAddOn = !on
            asset.refreshAddOns(in: context)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.note.isEmpty ? e.displayCategory : e.note).lineLimit(1)
                    Text("\(Fmt.day.string(from: e.date)) · \(e.displayCategory)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.money(e.amount, e.currency)).monospacedDigit()
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 日均花费曲线：从第一笔付款到今天，平滑曲线 + 渐变填充
private struct DailyCostChart: View {
    let asset: Asset
    let curve: [ValueSample]
    let today: Double
    @Binding var selected: Date?

    var body: some View {
        let start = curve.first?.date ?? asset.startDate
        let end = curve.last?.date ?? .now
        let span = start.days(to: end)
        // 付款当天日均会冲得很高，纵轴以「今天的日均」为基准，冲出去的部分裁掉，曲线才看得清
        // 同时保证曲线在横轴前 15% 之内就进入画面，左边不留大片空白
        let early = curve.first { $0.date >= start.adding(days: span * 15 / 100) }?.value ?? 0
        let yMax = max(today * 2.5, early, 0.01)
        let payDays = asset.payments().map(\.date).filter { $0 >= start && $0 <= end }
        VStack(spacing: 6) {
        Chart {
            ForEach(curve) { p in
                // 冲出顶部的部分靠裁剪截掉（不压平），曲线形状保持自然
                LineMark(x: .value("日期", p.date), y: .value("日均", min(p.value, yMax * 6)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            // 付款日：横轴上的小点
            ForEach(payDays, id: \.self) { d in
                PointMark(x: .value("日期", d), y: .value("日均", 0))
                    .symbolSize(18)
                    .foregroundStyle(Theme.accent.opacity(0.7))
            }
            // 今天的点
            PointMark(x: .value("日期", end), y: .value("日均", min(today, yMax)))
                .symbolSize(50)
                .foregroundStyle(Theme.accent)
            if let selected, selected >= start, selected <= end {
                let v = asset.dailyCost(at: selected)
                RuleMark(x: .value("日期", selected))
                    .foregroundStyle(.white.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(Fmt.day.string(from: selected)).font(.caption2).foregroundStyle(.secondary)
                            Text("\(Fmt.yuan(v))/天").font(.caption.bold().monospacedDigit())
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Theme.cardHigh, in: RoundedRectangle(cornerRadius: 8))
                    }
                PointMark(x: .value("日期", selected), y: .value("日均", min(v, yMax)))
                    .symbolSize(40)
                    .foregroundStyle(.white)
            }
        }
        .chartXScale(domain: start...end, range: .plotDimension(startPadding: 4, endPadding: 8))
        .chartYScale(domain: 0...yMax)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            // 按跨度选刻度：几个月内按日、几年内按月、更久按年，避免重复的年份
            if span <= 120 {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            } else if span <= 1460 {
                AxisMarks(values: .stride(by: .month, count: max(span / 120, 1))) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.year(.twoDigits).month(.defaultDigits))
                }
            } else {
                AxisMarks(values: .stride(by: .year, count: max(span / 1460, 1))) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.year())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel { Text(Fmt.short(v.as(Double.self) ?? 0)) }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: 200)
        .padding(.top, 8)
        legend.padding(.bottom, 4)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(Theme.accent).frame(width: 14, height: 3)
                Text("日均花费")
            }
            HStack(spacing: 5) {
                Circle().fill(Theme.accent.opacity(0.7)).frame(width: 5, height: 5)
                Text("付款日")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// 不设年限的物品（订阅、云服务这类）：每月花费柱状图。
/// 这类每次续费日均都会冲高，画日均曲线全是锯齿，按月看花了多少更清楚
private struct MonthlySpendChart: View {
    let asset: Asset
    @State private var selected: Date?

    private struct Month: Identifiable {
        var date: Date
        var amount: Double
        var id: Date { date }
    }

    private var months: [Month] {
        let cal = Calendar.current
        let end = asset.isRetired ? (asset.retiredDate ?? .now) : .now
        let pays = asset.payments()
        guard let first = pays.map(\.date).min() else { return [] }
        func monthStart(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d))! }
        var sums: [Date: Double] = [:]
        for p in pays { sums[monthStart(p.date), default: 0] += p.value }
        var list: [Month] = []
        var m = monthStart(first)
        let last = monthStart(max(end, first))
        while m <= last {
            list.append(Month(date: m, amount: sums[m] ?? 0))
            m = cal.date(byAdding: .month, value: 1, to: m)!
        }
        return list
    }

    var body: some View {
        let data = months
        let avg = data.isEmpty ? 0 : data.reduce(0) { $0 + $1.amount } / Double(data.count)
        let pick = selected.flatMap { s in
            data.first { Calendar.current.isDate($0.date, equalTo: s, toGranularity: .month) }
        }
        VStack(spacing: 6) {
            Chart {
                ForEach(data) { m in
                    BarMark(x: .value("月份", m.date, unit: .month), y: .value("花费", m.amount))
                        .foregroundStyle(Theme.accent.opacity(pick == nil || pick?.date == m.date ? 1 : 0.35))
                        .cornerRadius(2)
                }
                if avg > 0 {
                    RuleMark(y: .value("月均", avg))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let pick {
                    RuleMark(x: .value("月份", pick.date, unit: .month))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(spacing: 2) {
                                Text(pick.date.formatted(.dateTime.year().month())).font(.caption2).foregroundStyle(.secondary)
                                Text(Fmt.yuan(pick.amount)).font(.caption.bold().monospacedDigit())
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.cardHigh, in: RoundedRectangle(cornerRadius: 8))
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: max(data.count / 4, 1))) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel(format: .dateTime.year(.twoDigits).month(.defaultDigits))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel { Text(Fmt.short(v.as(Double.self) ?? 0)) }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 200)
            .padding(.top, 8)
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 10)
                    Text("每月花费")
                }
                HStack(spacing: 5) {
                    HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.5)).frame(width: 4, height: 2) } }
                    Text("月均 \(Fmt.yuan(avg))")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
    }
}

/// 按 id 打开物品详情（导航路由用）；物品被删了就显示空页面
struct AssetByID: View {
    @Query private var found: [Asset]

    init(id: UUID) {
        _found = Query(filter: #Predicate<Asset> { $0.id == id })
    }

    var body: some View {
        if let a = found.first {
            AssetDetailView(asset: a)
        } else {
            ContentUnavailableView("物品已删除", systemImage: "shippingbox")
        }
    }
}
