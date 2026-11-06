import SwiftUI
import SwiftData

extension Asset {
    /// 算进大类合计的日均。
    /// 在用：就是自己的日均。已处置：（花费 − 卖出价）摊到今天，处置后也一直往下降；
    /// 物品自己显示的「最终日均」仍停在处置那天，不受影响
    var groupDailyCost: Double {
        guard isRetired else { return dailyCost }
        return Self.dailyCost(of: payments(sold: true), at: .now, floor: usesMinAmortize)
    }
}

/// 大类：用户自己建的分组，比如「摄影」里放相机、镜头。
/// 不单独存表，名字记在每件物品的 groupName 上，所有物品都移出后大类自然消失。
/// 大类顺序、组内手动顺序只存在本机
enum AssetGroups {
    /// 当前用到的所有大类名
    static func names(_ assets: [Asset]) -> [String] {
        Array(Set(assets.map(\.groupName).filter { !$0.isEmpty })).sorted()
    }

    static func members(_ name: String, in assets: [Asset]) -> [Asset] {
        assets.filter { $0.groupName == name }
    }

    static func daily(_ members: [Asset]) -> Double {
        members.reduce(0) { $0 + $1.groupDailyCost }
    }

    /// 大类里离换新最近的天数（已达标算 0）；里面没有设年限的在用物品就返回 nil
    static func nearest(_ members: [Asset]) -> Int? {
        members.filter { !$0.isRetired && $0.hasTarget }.compactMap(\.daysLeft).min()
    }

    // MARK: 顺序（存在物品的 groupRank / groupManual / groupItemRank 上，跟着云同步和数据包走）

    /// 大类排位：取成员里的最大值（正常情况下成员都一样）
    static func rank(_ members: [Asset]) -> Int { members.map(\.groupRank).max() ?? 0 }

    static func isManual(_ members: [Asset]) -> Bool { members.contains(where: \.groupManual) }

    /// 大类排列：手动调过的按排位；没调过的（新建的）接在后面，
    /// 按离换新最近排，不设年限的大类放最后
    static func ordered(_ assets: [Asset]) -> [String] {
        let all = names(assets)
        let ranks = Dictionary(uniqueKeysWithValues: all.map { ($0, rank(members($0, in: assets))) })
        let saved = all.filter { ranks[$0]! > 0 }.sorted { ranks[$0]! != ranks[$1]! ? ranks[$0]! < ranks[$1]! : $0 < $1 }
        let rest = all.filter { ranks[$0]! == 0 }.sorted { a, b in
            let x = nearest(members(a, in: assets)), y = nearest(members(b, in: assets))
            switch (x, y) {
            case let (x?, y?): return x != y ? x < y : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return saved + rest
    }

    /// 保存大类顺序；传空数组就是恢复默认
    static func setOrder(_ order: [String], in assets: [Asset]) {
        for a in assets where !a.groupName.isEmpty {
            a.groupRank = (order.firstIndex(of: a.groupName)).map { $0 + 1 } ?? 0
        }
    }

    static func setManual(_ members: [Asset], _ on: Bool) {
        if on && !members.contains(where: { $0.groupItemRank > 0 }) {
            // 从当前「最接近达标」的顺序开始手动调
            setItemOrder(sorted(members))
        }
        for a in members { a.groupManual = on }
    }

    static func setItemOrder(_ list: [Asset]) {
        for (i, a) in list.enumerated() { a.groupItemRank = i + 1 }
    }

    /// 组内物品排列
    static func sorted(_ members: [Asset]) -> [Asset] {
        let byTarget = members.sorted { a, b in
            if a.isRetired != b.isRetired { return !a.isRetired }
            let x = a.hasTarget ? a.daysLeft : nil, y = b.hasTarget ? b.daysLeft : nil
            switch (x, y) {
            case let (x?, y?): return x != y ? x < y : a.purchaseDate > b.purchaseDate
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.purchaseDate > b.purchaseDate
            }
        }
        guard isManual(members) else { return byTarget }
        // 手动排过的在前，没排过的（新加的）按离换新最近接在后面
        return byTarget.enumerated().sorted { l, r in
            let i = l.element.groupItemRank > 0 ? l.element.groupItemRank : Int.max
            let j = r.element.groupItemRank > 0 ? r.element.groupItemRank : Int.max
            return i != j ? i < j : l.offset < r.offset
        }.map(\.element)
    }

    /// 把物品放进某个大类（空字符串＝移出），排位跟着新大类走
    static func assign(_ a: Asset, to name: String, in assets: [Asset]) {
        guard a.groupName != name else { return }
        let others = name.isEmpty ? [] : members(name, in: assets).filter { $0.id != a.id }
        a.groupName = name
        a.groupRank = rank(others)
        a.groupManual = isManual(others)
        a.groupItemRank = 0
    }

    /// 旧版把顺序存在本机 UserDefaults，搬到物品字段上
    static func migrateDefaults(_ assets: [Asset]) {
        let d = UserDefaults.standard
        let old = d.dictionaryRepresentation().keys.filter {
            $0 == "assetGroupOrder" || $0.hasPrefix("assetGroupManual.") || $0.hasPrefix("assetGroupItems.")
        }
        guard !old.isEmpty else { return }
        if let order = d.stringArray(forKey: "assetGroupOrder"), !order.isEmpty { setOrder(order, in: assets) }
        for g in names(assets) {
            let m = members(g, in: assets)
            if d.bool(forKey: "assetGroupManual.\(g)") { for a in m { a.groupManual = true } }
            if let ids = d.stringArray(forKey: "assetGroupItems.\(g)") {
                for a in m { a.groupItemRank = (ids.firstIndex(of: a.id.uuidString)).map { $0 + 1 } ?? 0 }
            }
        }
        for k in old { d.removeObject(forKey: k) }
    }
}

/// 物品列表里的一行大类：名字 + 合计日均
struct AssetGroupRow: View {
    let name: String
    let members: [Asset]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            Text(name).font(.body.weight(.medium)).lineLimit(1)
            Spacer(minLength: 8)
            // 日均完整显示，不截断
            Text("\(Fmt.yuan(AssetGroups.daily(members)))/天")
                .font(.body.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// 大类详情：合计 + 成员列表
struct AssetGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Asset.purchaseDate, order: .reverse) private var assets: [Asset]
    @State var name: String
    @State private var showPicker = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDissolve = false
    @State private var editMode: EditMode = .inactive

    private var members: [Asset] { AssetGroups.members(name, in: assets) }

    var body: some View {
        let list = AssetGroups.sorted(members)
        let manual = AssetGroups.isManual(members)
        let active = members.filter { !$0.isRetired }
        let retired = members.filter(\.isRetired)
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("这一类每天花我").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.yuan(AssetGroups.daily(members))).font(Theme.bigNumber(36))
                        Text("/ 天").font(.headline)
                    }
                    .foregroundStyle(.white)
                    HStack {
                        TotalCard.Stat(title: "总花费", value: Fmt.yuan(members.reduce(0) { $0 + $1.totalCost }))
                        Spacer()
                        TotalCard.Stat(title: "在用", value: "\(active.count) 件")
                        Spacer()
                        TotalCard.Stat(title: "已处置", value: "\(retired.count) 件")
                    }
                    if !retired.isEmpty {
                        Text("已处置的按（花费 − 卖出价）÷ 用到今天的天数计入")
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding()
                .background(LinearGradient(colors: [Theme.cardHigh, Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if members.isEmpty {
                ContentUnavailableView("这个大类还没有物品", systemImage: "square.stack.3d.up",
                                       description: Text("点右上角，把物品加进来"))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(list) { a in
                        NavigationLink(value: Route.asset(a.id)) { AssetRow(asset: a) }
                            .swipeActions {
                                Button("移出") { AssetGroups.assign(a, to: "", in: assets) }.tint(.orange)
                            }
                    }
                    .onMove(perform: manual ? move : nil)
                } header: {
                    HStack {
                        Text("物品")
                        Spacer()
                        Menu {
                            Picker("排序", selection: Binding(get: { manual }, set: { setManual($0) })) {
                                Text("最接近达标").tag(false)
                                Text("手动").tag(true)
                            }
                        } label: {
                            Label(manual ? "手动" : "最接近达标", systemImage: "arrow.up.arrow.down").font(.caption)
                        }
                        if manual {
                            Button(editMode.isEditing ? "完成" : "调整顺序") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }
                            .font(.caption)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showPicker = true } label: { Label("添加 / 移出物品", systemImage: "checklist") }
                    Button { newName = name; renaming = true } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDissolve = true } label: { Label("解散大类", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showPicker) { GroupMemberPicker(name: name) }
        .alert("重命名大类", isPresented: $renaming) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, n != name else { return }
                // 改成已有大类的名字就并进去，排位跟着那个大类
                let target = AssetGroups.members(n, in: assets)
                for a in members {
                    a.groupName = n
                    if !target.isEmpty { a.groupRank = AssetGroups.rank(target); a.groupManual = AssetGroups.isManual(target); a.groupItemRank = 0 }
                }
                name = n
            }
        }
        .confirmationDialog("解散「\(name)」？", isPresented: $confirmDissolve, titleVisibility: .visible) {
            Button("解散", role: .destructive) {
                for a in members { AssetGroups.assign(a, to: "", in: assets) }
                dismiss()
            }
        } message: {
            Text("里面的物品不会删除，只是不再归到这个大类")
        }
    }

    private func setManual(_ on: Bool) {
        AssetGroups.setManual(members, on)
        if !on { editMode = .inactive }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var list = AssetGroups.sorted(members)
        list.move(fromOffsets: from, toOffset: to)
        AssetGroups.setItemOrder(list)
    }
}

/// 拖动调整大类顺序
struct GroupOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var assets: [Asset]
    @State private var names: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(names, id: \.self) { n in
                        AssetGroupRow(name: n, members: AssetGroups.members(n, in: assets))
                    }
                    .onMove { names.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("按住右边的把手拖动。新建的大类会按离换新最近排在后面，不设年限的放最后。")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("大类顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { AssetGroups.setOrder(names, in: assets); dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("恢复默认（最接近达标）") {
                        AssetGroups.setOrder([], in: assets)
                        names = AssetGroups.ordered(assets)
                    }
                    .font(.footnote)
                }
            }
            .onAppear { if names.isEmpty { names = AssetGroups.ordered(assets) } }
        }
    }
}

/// 勾选哪些物品属于这个大类；已经在别的大类里的物品灰掉不能选
struct GroupMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Asset.purchaseDate, order: .reverse) private var assets: [Asset]
    let name: String
    @State private var selected: Set<UUID> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                let active = assets.filter { !$0.isRetired }
                let retired = assets.filter(\.isRetired)
                if !active.isEmpty { Section("在用") { rows(active) } }
                if !retired.isEmpty { Section("已处置") { rows(retired) } }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        for a in assets where a.groupName.isEmpty || a.groupName == name {
                            AssetGroups.assign(a, to: selected.contains(a.id) ? name : "", in: assets)
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                selected = Set(assets.filter { $0.groupName == name }.map(\.id))
                loaded = true
            }
        }
    }

    private func rows(_ list: [Asset]) -> some View {
        ForEach(list) { a in
            let taken = !a.groupName.isEmpty && a.groupName != name
            Button {
                if selected.contains(a.id) { selected.remove(a.id) } else { selected.insert(a.id) }
            } label: {
                HStack {
                    Image(systemName: AssetCategory.icon(a.category)).foregroundStyle(Theme.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).foregroundStyle(.primary)
                        if taken {
                            Text("已在「\(a.groupName)」").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: selected.contains(a.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(a.id) ? Theme.accent : .secondary)
                        .font(.title3)
                }
                .opacity(taken ? 0.35 : 1)
            }
            .disabled(taken)
        }
    }
}
