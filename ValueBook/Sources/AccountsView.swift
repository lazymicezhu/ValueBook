import SwiftUI
import SwiftData

/// 账户：净资产 + 分组列出每个账户余额
struct AccountsView: View {
    @Query private var entries: [LedgerEntry]
    @Query private var infos: [AccountInfo]
    @AppStorage("hideAmounts") private var hide = false
    @State private var showZero = false
    @State private var showGroups = false

    var body: some View {
        let all = Balances.compute(entries, infos: infos)
        let counted = all.filter { !$0.excluded }
        let assets = counted.filter { $0.cny > 0 }.reduce(0) { $0 + $1.cny }
        let debts = counted.filter { $0.cny < 0 }.reduce(0) { $0 + $1.cny }
        let nonZero = all.filter { $0.balance != 0 }
        let zero = all.filter { $0.balance == 0 }.sorted { $0.last > $1.last }

        List {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Caption("净资产")
                    Button { hide.toggle() } label: {
                        Image(systemName: hide ? "eye.slash" : "eye").font(.footnote).foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text(money(assets + debts)).font(Theme.bigNumber(46)).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 18) {
                    HStack(spacing: 6) { Text("资产").foregroundStyle(Theme.secondary); Text(money(assets)).font(Theme.number(15)) }
                    HStack(spacing: 6) { Text("负债").foregroundStyle(Theme.secondary); Text(money(-debts)).font(Theme.number(15)) }
                }
                .font(.subheadline)
            }
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(AccountGroup.ordered(including: all.map(\.group)), id: \.self) { group in
                let list = nonZero.filter { $0.group == group }.sorted { abs($0.cny) > abs($1.cny) }
                if !list.isEmpty {
                    Section {
                        ForEach(list) { a in
                            NavigationLink(value: Route.account(a.name)) { AccountRow(account: a, hide: hide) }
                                .listRowBackground(Theme.card)
                        }
                    } header: {
                        HStack {
                            Text(group)
                            Spacer()
                            Text(money(list.filter { !$0.excluded }.reduce(0) { $0 + $1.cny })).font(Theme.number(13))
                        }
                        .foregroundStyle(Theme.secondary)
                    }
                }
            }

            if !zero.isEmpty {
                Section {
                    Button { withAnimation { showZero.toggle() } } label: {
                        HStack {
                            Text("余额为 0 的账户（\(zero.count)）").foregroundStyle(Theme.secondary)
                            Spacer()
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showZero ? 0 : -90))
                                .font(.caption).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .listRowBackground(Theme.card)
                    if showZero {
                        ForEach(zero) { a in
                            NavigationLink(value: Route.account(a.name)) { AccountRow(account: a, hide: hide) }
                                .listRowBackground(Theme.card)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGroups = true } label: { Image(systemName: "folder.badge.gearshape") }
            }
        }
        .sheet(isPresented: $showGroups) {
            NavigationStack {
                AccountGroupsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showGroups = false } } }
            }
        }
    }

    private func money(_ v: Double) -> String { hide ? "****" : Fmt.plain(v) }
}

struct AccountRow: View {
    let account: AccountBalance
    var hide = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: AccountGroup.icon(account.group))
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.cardHigh, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).lineLimit(1)
                if account.excluded {
                    Text("不计入净资产").font(.caption2).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.cardHigh, in: Capsule())
                }
            }
            Spacer()
            Text(hide ? "****" : (account.currency == "CNY" ? "" : Rates.symbol(account.currency)) + Fmt.plain(account.balance))
                .font(Theme.number(16))
                .foregroundStyle(account.balance < 0 ? Theme.expense : .white)
        }
        .padding(.vertical, 2)
    }
}

/// 单个账户：余额、设置、流水
struct AccountDetailView: View {
    let name: String
    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query private var infos: [AccountInfo]
    @State private var showSettings = false
    @State private var showAdjust = false

    init(name: String) {
        self.name = name
        _entries = Query(filter: Filters.account(name))
    }

    var body: some View {
        let balance = Balances.compute(entries, infos: infos).first { $0.name == name }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Caption("余额")
                Text(((balance?.currency ?? "CNY") == "CNY" ? "" : Rates.symbol(balance!.currency)) + Fmt.plain(balance?.balance ?? 0))
                    .font(Theme.bigNumber(42)).lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle((balance?.balance ?? 0) < 0 ? Theme.expense : .white)
                HStack(spacing: 10) {
                    Text(balance?.group ?? AccountGroup.guess(name))
                    if balance?.excluded == true { Text("· 不计入净资产") }
                    Text("· \(entries.count) 笔")
                }
                .font(.footnote).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Button { showAdjust = true } label: { Label("调整余额", systemImage: "slider.horizontal.3") }
                    Button { showSettings = true } label: { Label("账户设置", systemImage: "gearshape") }
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            EntryList(filter: Filters.account(name), showYear: true, showSummary: false)
        }
        .background(Theme.bg)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) { AccountSettingsSheet(name: name, current: balance) }
        .sheet(isPresented: $showAdjust) { AdjustBalanceSheet(name: name, current: balance) }
    }
}

struct AccountSettingsSheet: View {
    let name: String
    let current: AccountBalance?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var infos: [AccountInfo]
    @State private var group = ""
    @State private var excluded = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("分组", selection: $group) {
                    ForEach(AccountGroup.ordered(including: [group]), id: \.self) { Text($0).tag($0) }
                }
                Toggle("不计入净资产", isOn: $excluded)
                Section {} footer: {
                    Text("比如专款专用的存款、学费账户，可以不算进净资产。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let info = infos.first(where: { $0.name == name }) {
                            info.group = group
                            info.excluded = excluded
                        } else {
                            context.insert(AccountInfo(name: name, group: group, excluded: excluded,
                                                       currency: current?.currency ?? "CNY"))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                group = current?.group ?? AccountGroup.guess(name)
                excluded = current?.excluded ?? false
            }
        }
        .presentationDetents([.medium])
    }
}

struct AdjustBalanceSheet: View {
    let name: String
    let current: AccountBalance?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                InfoRow("当前余额", Fmt.plain(current?.balance ?? 0))
                TextField("实际余额", text: $text).keyboardType(.numbersAndPunctuation)
                if let v = Double(text) {
                    InfoRow("将记录一笔余额调整", Fmt.plain(v - (current?.balance ?? 0)))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("调整余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let v = Double(text) else { return }
                        let delta = v - (current?.balance ?? 0)
                        if abs(delta) >= 0.005 {
                            let e = LedgerEntry(type: .transfer, amount: delta, category: "余额变更", account: name)
                            e.currency = current?.currency ?? "CNY"
                            context.insert(e)
                        }
                        dismiss()
                    }
                    .disabled(Double(text) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 账户分类管理：新建 / 改名 / 删除 / 排序分类，调整每个账户属于哪个分类
struct AccountGroupsView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query private var infos: [AccountInfo]
    @State private var groups: [String] = []
    /// 账户名和币种（只在打开时算一次）
    @State private var accounts: [AccountBalance] = []
    @State private var showAdd = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var deleting: String?

    /// 账户现在属于哪个分类：设置过的按设置，没设置过的按名称猜
    private func group(of name: String) -> String {
        infos.first { $0.name == name }?.group ?? AccountGroup.guess(name)
    }

    var body: some View {
        List {
            Section {
                ForEach(groups, id: \.self) { g in
                    Button { renameText = g; renaming = g } label: {
                        HStack(spacing: 12) {
                            Image(systemName: AccountGroup.icon(g)).foregroundStyle(Theme.accent).frame(width: 24)
                            Text(g).foregroundStyle(.white)
                            Spacer()
                            Text("\(accounts.filter { group(of: $0.name) == g }.count) 个").foregroundStyle(Theme.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = g }
                    }
                }
                .onMove { from, to in
                    groups.move(fromOffsets: from, toOffset: to)
                    AccountGroup.all = groups
                }
                Button { newName = ""; showAdd = true } label: { Label("新建分类", systemImage: "plus") }
            } header: {
                Text("账户分类")
            } footer: {
                Text("长按拖动调整顺序，点一下改名，左滑删除（里面的账户会移到其他分类）。")
            }

            Section {
                ForEach(accounts.sorted { (groups.firstIndex(of: group(of: $0.name)) ?? .max, $0.name) < (groups.firstIndex(of: group(of: $1.name)) ?? .max, $1.name) }) { a in
                    Picker(selection: Binding(get: { group(of: a.name) }, set: { setGroup(a, $0) })) {
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(a.name).lineLimit(1)
                            if a.currency != "CNY" { Text(a.currency).font(.caption).foregroundStyle(Theme.tertiary) }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.secondary)
                }
            } header: {
                Text("账户归属")
            } footer: {
                Text("点右边的分类名，把账户移到别的分类。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("账户分类")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            accounts = Balances.compute(entries, infos: infos)
            groups = AccountGroup.ordered(including: accounts.map { group(of: $0.name) })
        }
        .alert("新建分类", isPresented: $showAdd) {
            TextField("分类名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, !groups.contains(n) else { return }
                groups.append(n)
                AccountGroup.all = groups
            }
        }
        .alert("修改分类名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分类名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { if let old = renaming { rename(old, to: renameText) } }
        }
        .confirmationDialog("删除分类「\(deleting ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let g = deleting { delete(g) } }
        } message: {
            Text("里面的账户会移到「\(fallback(excluding: deleting ?? ""))」。")
        }
    }

    private func setGroup(_ a: AccountBalance, _ g: String) {
        if let info = infos.first(where: { $0.name == a.name }) {
            info.group = g
        } else {
            context.insert(AccountInfo(name: a.name, group: g, currency: a.currency))
        }
    }

    private func rename(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != old, !groups.contains(n), let i = groups.firstIndex(of: old) else { return }
        for a in accounts where group(of: a.name) == old { setGroup(a, n) }
        groups[i] = n
        AccountGroup.all = groups
    }

    private func fallback(excluding g: String) -> String {
        groups.contains("其他") && g != "其他" ? "其他" : (groups.first { $0 != g } ?? "其他")
    }

    private func delete(_ g: String) {
        let target = fallback(excluding: g)
        for a in accounts where group(of: a.name) == g { setGroup(a, target) }
        groups.removeAll { $0 == g }
        if !groups.contains(target) { groups.append(target) }
        AccountGroup.all = groups
    }
}
