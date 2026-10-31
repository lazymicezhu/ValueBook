import SwiftUI
import SwiftData
import Charts

enum AssetSort: String, CaseIterable, Identifiable {
    case daysLeft = "离达标最近"
    case dailyCost = "日均花费最高"
    case purchase = "最近买入"
    case price = "花费最高"
    var id: String { rawValue }
}

struct AssetsView: View {
    @Query(sort: \Asset.purchaseDate, order: .reverse) private var assets: [Asset]
    @AppStorage("assetSort") private var sort: AssetSort = .daysLeft
    @State private var showRetired = false
    @State private var showAdd = false
    @State private var showPick = false
    @State private var debugAsset: Asset?

    private var active: [Asset] { assets.filter { !$0.isRetired } }

    private func sorted(_ list: [Asset]) -> [Asset] {
        switch sort {
        case .daysLeft: return list.sorted { ($0.daysLeft ?? .max) < ($1.daysLeft ?? .max) }
        case .dailyCost: return list.sorted { $0.dailyCost > $1.dailyCost }
        case .purchase: return list.sorted { $0.purchaseDate > $1.purchaseDate }
        case .price: return list.sorted { $0.totalCost > $1.totalCost }
        }
    }

    var body: some View {
        Group {
            List {
                Section { TotalCard(assets: active) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Section {
                    Picker("", selection: $showRetired) {
                        Text("在用 \(active.count)").tag(false)
                        Text("已处置 \(assets.count - active.count)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if showRetired {
                    let retired = assets.filter(\.isRetired)
                    if retired.isEmpty {
                        ContentUnavailableView("没有已处置的物品", systemImage: "shippingbox").listRowBackground(Color.clear)
                    }
                    ForEach(sorted(retired)) { a in
                        NavigationLink { AssetDetailView(asset: a) } label: { AssetRow(asset: a) }
                    }
                } else {
                    if active.isEmpty {
                        ContentUnavailableView("还没有物品", systemImage: "shippingbox",
                                               description: Text("点右上角 +，可以从账单里挑出买过的东西"))
                            .listRowBackground(Color.clear)
                    }
                    let done = active.filter(\.reachedTarget)
                    if !done.isEmpty {
                        Section("🎉 已达标，可以换了") {
                            ForEach(sorted(done)) { a in
                                NavigationLink { AssetDetailView(asset: a) } label: { AssetRow(asset: a) }
                            }
                        }
                    }
                    let using = active.filter { $0.hasTarget && !$0.reachedTarget }
                    let noTarget = active.filter { !$0.hasTarget }
                    if !using.isEmpty {
                        Section(done.isEmpty && noTarget.isEmpty ? "" : "还在用回本") {
                            ForEach(sorted(using)) { a in
                                NavigationLink { AssetDetailView(asset: a) } label: { AssetRow(asset: a) }
                            }
                        }
                    }
                    if !noTarget.isEmpty {
                        Section("不设目标") {
                            ForEach(sorted(noTarget)) { a in
                                NavigationLink { AssetDetailView(asset: a) } label: { AssetRow(asset: a) }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("我的物品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $sort) {
                            ForEach(AssetSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showPick = true } label: { Label("从账单挑选物品", systemImage: "list.bullet.rectangle") }
                        Button { showAdd = true } label: { Label("手动添加物品", systemImage: "plus") }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .sheet(isPresented: $showAdd) { AssetEditView(asset: nil) }
            .sheet(isPresented: $showPick) { PickFromLedgerView() }
            .navigationDestination(item: $debugAsset) { AssetDetailView(asset: $0) }
            #if DEBUG
            // 测试用：启动参数 -openAsset 名称 直接打开物品详情
            .onAppear {
                if let n = UserDefaults.standard.string(forKey: "openAsset"), debugAsset == nil {
                    debugAsset = assets.first { $0.name == n }
                }
            }
            #endif
        }
    }
}

struct TotalCard: View {
    /// 在用的物品
    let assets: [Asset]

    var body: some View {
        let daily = assets.reduce(0) { $0 + $1.dailyCost }
        let cost = assets.reduce(0) { $0 + $1.totalCost }
        let done = assets.filter(\.reachedTarget).count
        let targetSum = assets.filter(\.hasTarget).reduce(0) { $0 + $1.targetDailyCost }
        VStack(alignment: .leading, spacing: 12) {
            Text("所有物品每天花我").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.yuan(daily)).font(Theme.bigNumber(40))
                Text("/ 天").font(.headline)
            }
            .foregroundStyle(.white)
            HStack {
                Stat(title: "总花费", value: Fmt.yuan(cost))
                Spacer()
                Stat(title: "目标合计", value: targetSum > 0 ? "\(Fmt.yuan(targetSum))/天" : "未设置")
                Spacer()
                Stat(title: "可以换了", value: "\(done) / \(assets.filter(\.hasTarget).count) 件")
            }
            let series = totalSeries()
            if series.count > 1 {
                Chart(series) {
                    LineMark(x: .value("日期", $0.date), y: .value("日均", $0.value))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.stepEnd)
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.8)) } }
                .chartYAxis { AxisMarks { v in AxisValueLabel { Text(Fmt.short(v.as(Double.self) ?? 0)) }.foregroundStyle(.white.opacity(0.8)) } }
                .frame(height: 90)
                Text("近一年「每天花费」的变化").font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
        .background(LinearGradient(colors: [Theme.cardHigh, Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    struct Stat: View {
        var title: String
        var value: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(value).font(.subheadline.monospacedDigit().bold()).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    /// 近一年里，每天所有在用物品的日均花费合计
    private func totalSeries() -> [ValueSample] {
        guard !assets.isEmpty else { return [] }
        let start = Date.now.adding(days: -365)
        let extras = Dictionary(assets.map { ($0.id, $0.addOns) }, uniquingKeysWith: { a, _ in a })
        return stride(from: 0, through: 365, by: 7).map { i in
            let d = start.adding(days: i)
            let owned = assets.filter { $0.startDate.startOfDay <= d }
            return ValueSample(date: d, value: owned.reduce(0) { $0 + $1.dailyCost(at: d, addOns: extras[$1.id]) })
        }
    }
}

struct AssetRow: View {
    let asset: Asset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: AssetCategory.icon(asset.category))
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(asset.reachedTarget ? Theme.expense : Theme.accent)
                    .background((asset.reachedTarget ? Theme.expense : Theme.accent).opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(asset.hasTarget && !asset.isRetired
                         ? "\(costText) · 用了\(asset.daysHeld())天 · 目标\(Fmt.yuan(asset.targetDailyCost))"
                         : "\(costText) · 用了\(asset.daysHeld())天")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Fmt.yuan(asset.dailyCost))/天").lineLimit(1).font(.body.monospacedDigit().weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(asset.reachedTarget ? .green : .secondary)
                }
            }
            if asset.hasTarget && !asset.isRetired {
                ProgressView(value: asset.targetProgress)
                    .tint(asset.reachedTarget ? Theme.expense : Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }

    private var costText: String {
        let n = asset.addOns.count
        return n > 0 ? "\(Fmt.yuan(asset.totalCost))（含\(n)笔附属）" : Fmt.yuan(asset.price)
    }

    private var statusText: String {
        if asset.isRetired { return "最终日均" }
        guard asset.hasTarget else { return "日均花费" }
        if asset.reachedTarget { return "已达标 ✓" }
        return "还差 \(asset.daysLeft ?? 0) 天"
    }
}
