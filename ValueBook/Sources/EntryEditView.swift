import SwiftUI
import SwiftData

/// 记一笔 / 编辑：大号金额 + 计算器键盘
struct EntryEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let entry: LedgerEntry?
    /// 从物品详情进来：这笔默认作为该物品的附属账目
    var attachTo: Asset? = nil

    @Query private var allEntries: [LedgerEntry]
    @Query private var infos: [AccountInfo]
    @Query(filter: #Predicate<Asset> { !$0.isRetired }, sort: \Asset.purchaseDate, order: .reverse) private var activeAssets: [Asset]

    @State private var type: EntryType = .expense
    @State private var expr = ""
    @State private var date = Date.now
    @State private var category = ""
    @State private var subcategory = ""
    @State private var account = ""
    @State private var toAccount = ""
    @State private var toAmountText = ""
    @State private var note = ""

    @State private var assetMode: AssetMode = .none
    @State private var attachID: UUID?
    @State private var assetName = ""
    @State private var assetCategory = "数码"
    @State private var targetText = ""
    @State private var targetEdited = false
    @State private var useTarget = true
    @State private var linkedAsset: Asset?

    @State private var panel: Panel?
    @State private var extraCategories: [String: [String]] = [:]
    @State private var extraAccounts: [String: [String]] = [:]
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var showSort = false
    /// 余额、分类树都要遍历全部流水，打开页面时算一次缓存起来，滚轮滚动时不再重算
    @State private var balanceCache: [AccountBalance] = []
    @State private var categoryCache: [EntryType: CategoryData] = [:]
    @FocusState private var focus: Field?

    enum Field { case note, assetName, target, toAmount }
    /// 这笔支出和物品的关系：不计入 / 买了个新物品 / 归入已有物品（配件、续费）
    enum AssetMode: String, CaseIterable { case none = "不计入", new = "新物品", attach = "归入已有" }
    enum AccountSlot { case from, to }
    /// 底部滚轮面板：选分类 / 选账户（代替计算器键盘）
    enum Panel: Equatable { case category, account(AccountSlot) }

    private var result: Double? { Calc.evaluate(expr) }
    private var hasOperator: Bool { Calc.hasOperator(expr) }

    private var balances: [AccountBalance] { balanceCache }
    private func currency(of name: String) -> String { balances.first { $0.name == name }?.currency ?? "CNY" }

    private var color: Color {
        switch type {
        case .expense: return Theme.expense
        case .income: return Theme.income
        case .transfer: return .white
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                typeTabs
                amountDisplay
                ScrollView {
                    VStack(spacing: 0) {
                        if type != .transfer {
                            FieldRow(icon: "square.grid.2x2", title: "分类", active: panel == .category) {
                                Button { openPanel(.category) } label: {
                                    HStack(spacing: 6) {
                                        Text(category.isEmpty ? "选择分类" : category)
                                        if !subcategory.isEmpty {
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.tertiary)
                                            Text(subcategory)
                                        }
                                        Spacer()
                                    }
                                    .foregroundStyle(category.isEmpty ? Theme.tertiary : .white)
                                }
                            }
                        }
                        FieldRow(icon: "creditcard", title: type == .transfer ? "转出" : "账户", active: panel == .account(.from)) {
                            accountButton(account, slot: .from)
                        }
                        if type == .transfer {
                            FieldRow(icon: "arrow.down.to.line", title: "转入", active: panel == .account(.to)) {
                                accountButton(toAccount, slot: .to)
                            }
                            if !toAccount.isEmpty && currency(of: toAccount) != currency(of: account) {
                                FieldRow(icon: "dollarsign.arrow.circlepath", title: "到账") {
                                    TextField("到账金额（\(currency(of: toAccount))）", text: $toAmountText)
                                        .keyboardType(.decimalPad)
                                        .focused($focus, equals: .toAmount)
                                }
                            }
                        }
                        FieldRow(icon: "clock", title: "时间") {
                            DatePicker("", selection: $date).labelsHidden()
                            Spacer()
                        }
                        FieldRow(icon: "text.alignleft", title: "备注") {
                            TextField("写点什么…", text: $note).focused($focus, equals: .note)
                        }
                        if type == .expense { assetSection }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollDismissesKeyboard(.interactively)

                if focus == nil {
                    if let panel {
                        pickerPanel(panel)
                            .id(panel == .category ? "cat-\(type.rawValue)" : "acc-\(panel == .account(.to))")
                            .transition(.move(edge: .bottom))
                    } else {
                        Keypad(color: color, doneTitle: hasOperator ? "=" : "完成", onKey: press)
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .principal) { Text(entry == nil ? "记一笔" : "编辑").font(.headline) }
                if focus == nil && entry != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("删除这笔", role: .destructive) { confirmDelete = true }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if focus != nil {
                        // 正在输备注等文字：先收起键盘
                        Button("完成") { focus = nil }
                    } else {
                        // 和键盘上的「完成」一样：有算式先算出结果，再保存
                        Button("完成") {
                            if hasOperator, let r = result { expr = Calc.format(r) }
                            save()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: focus)
            .animation(.snappy(duration: 0.25), value: panel)
            .onChange(of: focus) { _, f in if f != nil { panel = nil } }
            .confirmationDialog("删除这笔账？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let entry {
                        let assetID = entry.isAddOn ? entry.assetID : nil
                        context.delete(entry)
                        try? context.save()
                        Asset.refreshAddOns(id: assetID, in: context)
                    }
                    dismiss()
                }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $showSort, onDismiss: { categoryCache = CategoryData.build(allEntries) }) {
                NavigationStack {
                    CategorySortView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSort = false } } }
                }
            }
            .onChange(of: type) { _, t in
                if t == .transfer && panel == .category { panel = nil }
                guard loaded, entry == nil else { return }
                applyDefaults(for: t)
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - 组件

    private var typeTabs: some View {
        HStack(spacing: 28) {
            ForEach(EntryType.allCases) { t in
                Button { withAnimation(.snappy) { type = t } } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue)
                            .font(.subheadline.weight(type == t ? .semibold : .regular))
                            .foregroundStyle(type == t ? .white : Theme.tertiary)
                        Capsule().fill(type == t ? Theme.accent : .clear).frame(width: 18, height: 3)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var amountDisplay: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                let cur = currency(of: account)
                if cur != "CNY" { Text(cur).font(.headline).foregroundStyle(Theme.secondary) }
                Spacer()
                Text(expr.isEmpty ? "0.00" : expr.replacingOccurrences(of: "-", with: "−"))
                    .font(Theme.bigNumber(52))
                    .foregroundStyle(expr.isEmpty ? color.opacity(0.4) : color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            if hasOperator, let r = result {
                Text("= \(Fmt.plain(r))").font(Theme.number(16)).foregroundStyle(Theme.secondary)
            }
            Rectangle().fill(color.opacity(0.6)).frame(height: 1).padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { focus = nil; panel = nil }
    }

    private func accountButton(_ name: String, slot: AccountSlot) -> some View {
        Button { openPanel(.account(slot)) } label: {
            HStack {
                Text(name.isEmpty ? "选择账户" : name).foregroundStyle(name.isEmpty ? Theme.tertiary : .white)
                if !name.isEmpty && currency(of: name) != "CNY" {
                    Text(currency(of: name)).font(.caption).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var assetSection: some View {
        if let linkedAsset {
            FieldRow(icon: "shippingbox", title: "物品") {
                Text(entry?.isAddOn == true
                     ? "附属于「\(linkedAsset.name)」"
                     : "\(linkedAsset.name) · 日均 \(Fmt.yuan(linkedAsset.dailyCost))")
                    .foregroundStyle(Theme.accent).lineLimit(1)
                Spacer()
            }
        } else {
            FieldRow(icon: "shippingbox", title: "物品") {
                Picker("", selection: $assetMode.animation()) {
                    ForEach(AssetMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: assetMode) { _, m in
                    switch m {
                    case .new:
                        assetCategory = AssetCategory.guess(from: LedgerEntry(category: category, subcategory: subcategory, note: note))
                        if assetName.isEmpty { assetName = note.isEmpty ? subcategory : note }
                        suggestTarget()
                    case .attach:
                        if attachID == nil { attachID = guessAttachTarget() }
                    case .none: break
                    }
                }
            }
            if assetMode == .new {
                FieldRow(icon: "tag", title: "名称") {
                    TextField("物品名称", text: $assetName).focused($focus, equals: .assetName)
                }
                FieldRow(icon: "square.stack", title: "类别") {
                    Picker("", selection: $assetCategory) {
                        ForEach(AssetCategory.all, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .tint(.white)
                    .onChange(of: assetCategory) { _, _ in suggestTarget() }
                    Spacer()
                }
                FieldRow(icon: "target", title: "目标") {
                    if useTarget {
                        TextField("想用几年", text: $targetText)
                            .keyboardType(.decimalPad)
                            .focused($focus, equals: .target)
                            .onChange(of: targetText) { _, _ in if focus == .target { targetEdited = true } }
                        Text("年").foregroundStyle(Theme.tertiary)
                        if let y = Double(targetText), y > 0 {
                            Text("\(Fmt.day.string(from: date.adding(days: max(Int((y * 365).rounded()), 1) - 1))) 可换")
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    } else {
                        Text("不设年限").foregroundStyle(Theme.tertiary)
                        Spacer()
                    }
                    Toggle("", isOn: $useTarget.animation()).labelsHidden().tint(Theme.accent)
                }
            } else if assetMode == .attach {
                FieldRow(icon: "link", title: "归入") {
                    if activeAssets.isEmpty {
                        Text("还没有在用的物品").foregroundStyle(Theme.tertiary)
                    } else {
                        Picker("", selection: $attachID) {
                            ForEach(activeAssets) { a in
                                Text("\(a.name)").tag(Optional(a.id))
                            }
                        }
                        .labelsHidden()
                        .tint(.white)
                    }
                    Spacer()
                    if let a = activeAssets.first(where: { $0.id == attachID }) {
                        Text("日均 \(Fmt.yuan(a.dailyCost))").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
    }

    /// 归入已有物品时，猜一个最可能的：备注 / 分类里带物品名的
    private func guessAttachTarget() -> UUID? {
        let text = note + category + subcategory
        return (activeAssets.first { !$0.name.isEmpty && text.localizedCaseInsensitiveContains($0.name) } ?? activeAssets.first)?.id
    }

    // MARK: - 滚轮面板

    private func openPanel(_ p: Panel) {
        focus = nil
        panel = panel == p ? nil : p
    }

    private static let recent = "最近使用"
    private static let sep: Character = "\u{1F}"

    @ViewBuilder
    private func pickerPanel(_ p: Panel) -> some View {
        switch p {
        case .category: categoryPanel
        case .account(let slot): accountPanel(slot)
        }
    }

    private var categoryPanel: some View {
        let tree = categoryTree()
        let recent = recentCategories()
        func key(_ c: String, _ s: String) -> String { c + String(Self.sep) + s }
        let groups = (recent.isEmpty ? [] : [Self.recent]) + tree.map(\.0)
        let current: (group: String, item: String)? = category.isEmpty ? nil : (category, key(category, subcategory))
        return TwoWheelPanel(
            groups: groups,
            items: { g in
                if g == Self.recent {
                    return recent.map { c, s in
                        WheelItem(id: key(c, s), title: s.isEmpty ? c : "\(c) › \(s)", icon: CategoryIcon.symbol(c + s))
                    }
                }
                let subs = tree.first { $0.0 == g }?.1 ?? []
                if subs.isEmpty { return [WheelItem(id: key(g, ""), title: g, icon: CategoryIcon.symbol(g))] }
                return subs.map { WheelItem(id: key(g, $0), title: $0, icon: CategoryIcon.symbol(g + $0)) }
            },
            current: current,
            addTitle: "新建小类",
            onSort: { showSort = true },
            onSelect: { item in
                let parts = item.id.split(separator: Self.sep, omittingEmptySubsequences: false)
                category = String(parts[0]); subcategory = parts.count > 1 ? String(parts[1]) : ""
            },
            onAdd: { g, name in
                let cat = (g == Self.recent || g.isEmpty) ? (category.isEmpty ? name : category) : g
                let sub = cat == name ? "" : name
                if !sub.isEmpty { extraCategories["\(type.rawValue)|\(cat)", default: []].append(sub) }
                else { extraCategories["\(type.rawValue)|", default: []].append(cat) }
                category = cat; subcategory = sub
                return key(cat, sub)
            },
            onClose: { panel = nil }
        )
    }

    private func accountPanel(_ slot: AccountSlot) -> some View {
        let byRecent = balances.sorted { $0.last > $1.last }
        var grouped: [String: [String]] = [:]
        for a in byRecent { grouped[a.group, default: []].append(a.name) }
        for (g, names) in extraAccounts { grouped[g, default: []].append(contentsOf: names) }
        let recent = Array(byRecent.prefix(6).map(\.name))
        let groups = (recent.isEmpty ? [] : [Self.recent]) + AccountGroup.ordered(including: grouped.keys).filter { grouped[$0] != nil }
        let selected = slot == .from ? account : toAccount
        let selGroup = balances.first { $0.name == selected }?.group
            ?? extraAccounts.first { $0.value.contains(selected) }?.key
        func item(_ name: String) -> WheelItem {
            if let b = balances.first(where: { $0.name == name }) {
                return WheelItem(id: name, title: "\(name) (\(b.currency))",
                                 subtitle: (b.currency == "CNY" ? "¥" : Rates.symbol(b.currency)) + Fmt.plain(b.balance),
                                 icon: AccountGroup.icon(b.group))
            }
            return WheelItem(id: name, title: name, subtitle: "新账户", icon: AccountGroup.icon(AccountGroup.guess(name)))
        }
        return TwoWheelPanel(
            groups: groups.isEmpty ? AccountGroup.all : groups,
            items: { g in (g == Self.recent ? recent : grouped[g] ?? []).map(item) },
            current: selected.isEmpty ? nil : (selGroup ?? Self.recent, selected),
            addTitle: "新建账户",
            onSelect: { it in if slot == .from { account = it.id } else { toAccount = it.id } },
            onAdd: { g, name in
                let group = (g == Self.recent || g.isEmpty) ? AccountGroup.guess(name) : g
                if balances.contains(where: { $0.name == name }) == false { extraAccounts[group, default: []].append(name) }
                if slot == .from { account = name } else { toAccount = name }
                return name
            },
            onClose: { panel = nil }
        )
    }

    /// 这个类型最近用过的分类组合
    private func recentCategories() -> [(String, String)] { categoryCache[type]?.recent ?? [] }

    // MARK: - 键盘

    private func press(_ key: Keypad.Key) {
        switch key {
        case .digit(let d):
            let current = Calc.lastNumber(expr)
            if let dot = current.firstIndex(of: "."), current[dot...].count > 2 { return }
            if current == "0" { expr.removeLast() }
            if current.count >= 12 { return }
            expr.append(d)
        case .dot:
            let current = Calc.lastNumber(expr)
            if current.contains(".") { return }
            expr += current.isEmpty ? "0." : "."
        case .plus, .minus:
            let op: Character = key == .plus ? "+" : "-"
            if expr.isEmpty { if op == "-" { expr = "-" }; return }
            if let last = expr.last, last == "+" || last == "-" { expr.removeLast() }
            if !expr.isEmpty { expr.append(op) }
        case .delete:
            if !expr.isEmpty { expr.removeLast() }
        case .clear:
            expr = ""
        case .done:
            if hasOperator, let r = result {
                expr = Calc.format(r)
            } else {
                save()
            }
        }
    }

    // MARK: - 数据

    private func categoryTree() -> [(String, [String])] {
        var tree = categoryCache[type]?.tree ?? []
        for c in extraCategories["\(type.rawValue)|"] ?? [] where !tree.contains(where: { $0.0 == c }) { tree.append((c, [])) }
        for i in tree.indices {
            for s in extraCategories["\(type.rawValue)|\(tree[i].0)"] ?? [] where !tree[i].1.contains(s) { tree[i].1.append(s) }
        }
        return tree
    }

    private func load() {
        guard !loaded else { return }
        balanceCache = Balances.compute(allEntries, infos: infos)
        categoryCache = CategoryData.build(allEntries)
        if let e = entry {
            type = e.type
            expr = Calc.format(e.amount)
            date = e.date
            category = e.category; subcategory = e.subcategory
            account = e.account; toAccount = e.toAccount
            if e.toAmount != 0 { toAmountText = Calc.format(e.toAmount) }
            note = e.note
            if let id = e.assetID {
                linkedAsset = try? context.fetch(FetchDescriptor<Asset>(predicate: #Predicate { $0.id == id })).first
            }
        } else if let a = attachTo {
            type = .expense
            assetMode = .attach
            attachID = a.id
            // 续费一般和上一次一样：沿用这件物品最近一笔账的分类、账户、备注
            let id = a.id
            var d = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.assetID == id },
                                                 sortBy: [SortDescriptor(\.date, order: .reverse)])
            d.fetchLimit = 1
            if let last = try? context.fetch(d).first {
                category = last.category; subcategory = last.subcategory
                account = last.account; note = last.note
            } else {
                applyDefaults(for: .expense)
                note = a.name
            }
        } else {
            applyDefaults(for: type)
        }
        #if DEBUG
        // 测试用：启动参数 -panel category/account 直接打开滚轮面板
        switch UserDefaults.standard.string(forKey: "panel") {
        case "category": panel = .category
        case "account": panel = .account(.from)
        default: break
        }
        #endif
        DispatchQueue.main.async { loaded = true }
    }

    /// 新记一笔：默认用这个类型最近一次的分类和账户
    private func applyDefaults(for t: EntryType) {
        let raw = t.rawValue
        var d = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.typeRaw == raw && $0.toAccount == "" },
                                             sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = 1
        if t == .transfer {
            d = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.typeRaw == raw && $0.toAccount != "" },
                                             sortBy: [SortDescriptor(\.date, order: .reverse)])
            d.fetchLimit = 1
        }
        guard let last = try? context.fetch(d).first else { return }
        category = t == .transfer ? "" : last.category
        subcategory = t == .transfer ? "" : last.subcategory
        account = last.account
        toAccount = t == .transfer ? last.toAccount : ""
    }

    private func suggestTarget() {
        guard !targetEdited else { return }
        targetText = String(format: "%g", AssetCategory.targetYears(assetCategory))
    }

    private func save() {
        guard let amount = result, amount != 0 else { return }
        let isAdjust = type == .transfer && entry?.isBalanceAdjust == true
        if type == .transfer && !isAdjust && (account.isEmpty || toAccount.isEmpty || account == toAccount) {
            openPanel(.account(account.isEmpty ? .from : .to))
            return
        }
        let e = entry ?? LedgerEntry()
        e.type = type
        e.amount = amount
        e.date = date
        e.category = type == .transfer ? (isAdjust ? "余额变更" : "") : category
        e.subcategory = type == .transfer ? "" : subcategory
        e.account = account
        e.currency = currency(of: account)
        e.toAccount = type == .transfer && !isAdjust ? toAccount : ""
        if type == .transfer && !isAdjust {
            e.toCurrency = currency(of: toAccount)
            e.toAmount = e.toCurrency != e.currency ? (Double(toAmountText) ?? 0) : 0
        } else {
            e.toCurrency = ""
            e.toAmount = 0
        }
        e.note = note
        if entry == nil { context.insert(e) }

        if let linkedAsset {
            if e.isAddOn {
                try? context.save()
                linkedAsset.refreshAddOns(in: context)
            } else {
                linkedAsset.price = e.cny
                linkedAsset.purchaseDate = date
            }
        } else if type == .expense && assetMode == .attach, let a = activeAssets.first(where: { $0.id == attachID }) {
            e.assetID = a.id
            e.isAddOn = true
            try? context.save()
            a.refreshAddOns(in: context)
        } else if type == .expense && assetMode == .new {
            let name = assetName.isEmpty ? (note.isEmpty ? (subcategory.isEmpty ? category : subcategory) : note) : assetName
            let d = AssetCategory.defaults(assetCategory)
            let a = Asset(name: name.isEmpty ? "未命名物品" : name, category: assetCategory, purchaseDate: date,
                          price: e.cny, method: d.0, lifeYears: d.1, residualRate: d.2, note: note)
            a.targetYears = useTarget ? (Double(targetText).flatMap { $0 > 0 ? $0 : nil } ?? AssetCategory.targetYears(assetCategory)) : 0
            context.insert(a)
            e.assetID = a.id
        }
        dismiss()
    }
}

/// 每种类型的分类树（按使用次数排序）和最近用过的分类
struct CategoryData {
    var tree: [(String, [String])] = []
    var recent: [(String, String)] = []

    static func build(_ entries: [LedgerEntry]) -> [EntryType: CategoryData] {
        var catCount: [EntryType: [String: Int]] = [:]
        var subCount: [EntryType: [String: [String: Int]]] = [:]
        for e in entries where !e.category.isEmpty {
            let t = e.type
            catCount[t, default: [:]][e.category, default: 0] += 1
            if !e.subcategory.isEmpty { subCount[t, default: [:]][e.category, default: [:]][e.subcategory, default: 0] += 1 }
        }
        var out: [EntryType: CategoryData] = [:]
        for t in EntryType.allCases {
            let subs = subCount[t] ?? [:]
            let byUsage = (catCount[t] ?? [:]).sorted { $0.value > $1.value }.map { cat, _ in
                (cat, (subs[cat] ?? [:]).sorted { $0.value > $1.value }.map(\.key))
            }
            out[t] = CategoryData(tree: CategoryOrder.order(byUsage, t))
        }
        var seen = Set<String>()
        for e in entries.sorted(by: { $0.date > $1.date }) where !e.category.isEmpty {
            guard (out[e.type]?.recent.count ?? 0) < 8 else { continue }
            if seen.insert(e.typeRaw + "|" + e.category + "|" + e.subcategory).inserted {
                out[e.type]?.recent.append((e.category, e.subcategory))
            }
        }
        return out
    }
}

/// 表单行：图标 + 标题 + 内容
struct FieldRow<Content: View>: View {
    let icon: String
    let title: String
    var active = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                Text(title).font(.subheadline).foregroundStyle(Theme.secondary).frame(width: 34, alignment: .leading)
                content
            }
            .frame(minHeight: 52)
            .background {
                if active { Theme.cardHigh.padding(.horizontal, -20) }
            }
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }
}

/// 计算器键盘
struct Keypad: View {
    enum Key: Equatable { case digit(Character), dot, plus, minus, delete, clear, done }
    let color: Color
    let doneTitle: String
    let onKey: (Key) -> Void

    var body: some View {
        let rows: [[Key]] = [
            [.digit("7"), .digit("8"), .digit("9"), .delete],
            [.digit("4"), .digit("5"), .digit("6"), .plus],
            [.digit("1"), .digit("2"), .digit("3"), .minus],
            [.clear, .digit("0"), .dot, .done],
        ]
        VStack(spacing: 8) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(0..<rows[r].count, id: \.self) { c in
                        keyView(rows[r][c])
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onKey(key)
        } label: {
            Group {
                switch key {
                case .digit(let d): Text(String(d)).font(Theme.number(26))
                case .dot: Text(".").font(Theme.number(26))
                case .plus: Image(systemName: "plus").font(.title3)
                case .minus: Image(systemName: "minus").font(.title3)
                case .delete: Image(systemName: "delete.left").font(.title3)
                case .clear: Text("C").font(Theme.number(22))
                case .done: Text(doneTitle).font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(key == .done ? .black : .white)
            .background {
                if key == .done {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentGradient)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill([.plus, .minus, .delete, .clear].contains(key) ? Theme.cardHigh.opacity(0.6) : Theme.cardHigh)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 只支持加减的简单计算
enum Calc {
    static func hasOperator(_ s: String) -> Bool {
        s.dropFirst().contains { $0 == "+" || $0 == "-" }
    }

    static func lastNumber(_ s: String) -> String {
        guard let i = s.lastIndex(where: { $0 == "+" || $0 == "-" }) else { return s }
        return String(s[s.index(after: i)...])
    }

    static func evaluate(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        var total = 0.0
        var sign = 1.0
        var num = ""
        var any = false
        for ch in s {
            if ch == "+" || ch == "-" {
                if let v = Double(num) { total += sign * v; any = true }
                num = ""
                sign = ch == "+" ? 1 : -1
            } else {
                num.append(ch)
            }
        }
        if let v = Double(num) { total += sign * v; any = true }
        return any ? (total * 100).rounded() / 100 : nil
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v).replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }
}

struct DepreciationFields: View {
    @Binding var method: DepreciationMethod
    @Binding var lifeYears: Double
    @Binding var residualPct: Double

    var body: some View {
        Picker("折旧方式", selection: $method) {
            ForEach(DepreciationMethod.allCases) { Text($0.rawValue).tag($0) }
        }
        Text(method.explain).font(.caption).foregroundStyle(.secondary)
        if method != .none {
            Stepper(value: $lifeYears, in: 0.5...50, step: 0.5) {
                HStack { Text("使用年限"); Spacer(); Text("\(lifeYears, specifier: "%g") 年").foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading) {
                HStack { Text("残值率"); Spacer(); Text("\(Int(residualPct))%").foregroundStyle(.secondary) }
                Slider(value: $residualPct, in: 0...100, step: 5)
            }
        }
    }
}
