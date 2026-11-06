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
    /// 收起的大类（只存在本机）
    @AppStorage("assetGroupCollapsed") private var collapsedRaw = ""
    @State private var showGroupOrder = false
    /// 大类顺序等存在 UserDefaults，改完后刷新列表
    @State private var orderVersion = 0
    @State private var showAdd = false
    @State private var showPick = false
    @State private var debugAsset: Asset?
    #if DEBUG
    private static var debugOpened = false
    #endif
    @State private var askGroupName = false
    @State private var newGroupName = ""
    @State private var pickGroup: String?

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

                if assets.isEmpty {
                    ContentUnavailableView("还没有物品", systemImage: "shippingbox",
                                           description: Text("点右上角 +，可以从账单里挑出买过的东西"))
                        .listRowBackground(Color.clear)
                }
                groupSections
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
                        Divider()
                        Button { showGroupOrder = true } label: { Label("调整大类顺序", systemImage: "line.3.horizontal") }
                        Button { setCollapsed(Set(AssetGroups.names(assets))) } label: {
                            Label("全部收起", systemImage: "rectangle.compress.vertical")
                        }
                        Button { setCollapsed([]) } label: { Label("全部展开", systemImage: "rectangle.expand.vertical") }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showPick = true } label: { Label("从账单挑选物品", systemImage: "list.bullet.rectangle") }
                        Button { showAdd = true } label: { Label("手动添加物品", systemImage: "plus") }
                        Divider()
                        Button { newGroupName = ""; askGroupName = true } label: {
                            Label("新建大类", systemImage: "square.stack.3d.up")
                        }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                }
            }
            .sheet(isPresented: $showAdd) { AssetEditView(asset: nil) }
            .sheet(isPresented: $showPick) { PickFromLedgerView() }
            .sheet(isPresented: $showGroupOrder, onDismiss: { orderVersion += 1 }) { GroupOrderView() }
            .onAppear { AssetGroups.migrateDefaults(assets); orderVersion += 1 }
            .alert("新建大类", isPresented: $askGroupName) {
                TextField("如 摄影、家具", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("下一步") {
                    let n = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { pickGroup = n }
                }
            } message: {
                Text("建好后勾选要放进来的物品")
            }
            .sheet(isPresented: Binding(get: { pickGroup != nil }, set: { if !$0 { pickGroup = nil } }),
                   onDismiss: { orderVersion += 1 }) {
                if let g = pickGroup { GroupMemberPicker(name: g) }
            }
            .navigationDestination(item: $debugAsset) { AssetDetailView(asset: $0) }
            #if DEBUG
            // 测试用：启动参数 -openAsset 名称 直接打开物品详情（每次启动只跳一次）
            .onAppear {
                if !Self.debugOpened, let n = UserDefaults.standard.string(forKey: "openAsset") {
                    Self.debugOpened = true
                    debugAsset = assets.first { $0.name == n }
                }
            }
            #endif
        }
    }

    private func link(_ a: Asset) -> some View {
        NavigationLink(value: Route.asset(a.id)) { AssetRow(asset: a) }
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private func setCollapsed(_ c: Set<String>) { collapsedRaw = c.sorted().joined(separator: "\n") }
    private func toggle(_ g: String) {
        var c = collapsed
        if c.contains(g) { c.remove(g) } else { c.insert(g) }
        withAnimation { setCollapsed(c) }
    }

    /// 大类那一行：左边箭头收起/展开，点其余地方进大类详情
    private func groupHeader(_ g: String, _ members: [Asset]) -> some View {
        HStack(spacing: 8) {
            Button { toggle(g) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed.contains(g) ? 0 : 90))
                    .frame(width: 20, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            NavigationLink(value: Route.assetGroup(g)) { AssetGroupRow(name: g, members: members) }
        }
    }

    /// 按大类：每个大类一段（顺序可调），收起的大类挨在一起显示；没归类的放最后
    @ViewBuilder private var groupSections: some View {
        let _ = orderVersion
        let names = AssetGroups.ordered(assets)
        let shut = collapsed
        if names.isEmpty && !assets.isEmpty {
            Section {
                Button { newGroupName = ""; askGroupName = true } label: {
                    Label("新建一个大类，把同类物品归到一起", systemImage: "square.stack.3d.up")
                }
            }
        }
        // 所有大类在同一块里接着排，展开的大类把物品列在自己下面
        if !names.isEmpty {
            Section {
                ForEach(names, id: \.self) { g in
                    let members = AssetGroups.members(g, in: assets)
                    groupHeader(g, members)
                    if !shut.contains(g) {
                        ForEach(AssetGroups.sorted(members)) { link($0).padding(.leading, 28) }
                    }
                }
            }
        }
        let looseActive = active.filter { $0.groupName.isEmpty }
        let looseRetired = assets.filter { $0.isRetired && $0.groupName.isEmpty }
        if !looseActive.isEmpty {
            Section("未归类") { ForEach(sorted(looseActive)) { link($0) } }
        }
        if !looseRetired.isEmpty {
            Section("未归类 · 已处置") { ForEach(sorted(looseRetired)) { link($0) } }
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
        let nearest = assets.filter { $0.hasTarget && !$0.reachedTarget }.compactMap(\.daysLeft).min()
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
                Stat(title: "最近一件", value: nearest.map { "还差 \($0) 天" } ?? "—")
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
                    .opacity(asset.isRetired ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name).font(.body.weight(.medium)).lineLimit(1)
                    Text("¥\(asset.totalCost.formatted(.number.precision(.fractionLength(0)))) · \(asset.daysHeld().formatted())天")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Fmt.yuan(asset.dailyCost))/天").lineLimit(1).font(.body.monospacedDigit().weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(asset.reachedTarget ? .green : .secondary)
                }
            }
            // 「已处置」章斜盖在名字和日均之间
            .overlay { if asset.isRetired { RetiredStamp().offset(x: 18) } }
            if asset.hasTarget && !asset.isRetired {
                ProgressView(value: asset.targetProgress)
                    .tint(asset.reachedTarget ? Theme.expense : Theme.accent)
            }
        }
        .padding(.vertical, 2)
        // 已处置的文字压暗一点，主要靠图标上的「已处置」章区分
        .foregroundStyle(asset.isRetired ? .secondary : .primary)
    }

    private var statusText: String {
        if asset.isRetired { return "最终日均" }
        guard asset.hasTarget else { return "日均花费" }
        if asset.reachedTarget { return "已达标 ✓" }
        return "还差 \(asset.daysLeft ?? 0) 天"
    }
}

/// 已处置物品图标上斜着盖的小章
struct RetiredStamp: View {
    var body: some View {
        Text("已处置")
            .font(.system(size: 14, weight: .heavy))
            .tracking(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.stamp)
            .background(Theme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stamp, lineWidth: 1.8))
            .rotationEffect(.degrees(-12))
            .allowsHitTesting(false)
            .fixedSize()
    }
}
