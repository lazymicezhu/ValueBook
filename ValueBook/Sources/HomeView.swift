import SwiftUI
import SwiftData
import Charts

enum Route: Hashable {
    case accounts, flow, assets, settings, stats, categories, search
    case period(title: String, start: Date, end: Date)
    case account(String)
    case category(type: String, name: String)
}

extension View {
    func appDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .accounts: AccountsView()
            case .flow: FlowView()
            case .assets: AssetsView()
            case .settings: SettingsView()
            case .stats: StatsView()
            case .categories: CategorySummaryView()
            case .search: SearchFlowView()
            case let .period(title, start, end):
                FilteredFlowView(title: title, filter: Filters.range(start, end), showYear: start.days(to: end) > 40)
            case let .account(name): AccountDetailView(name: name)
            case let .category(type, name): FilteredFlowView(title: name, filter: Filters.category(type, name))
            }
        }
    }
}

struct HomeSum {
    var income = 0.0
    var expense = 0.0
}

struct HomeView: View {
    @Query private var entries: [LedgerEntry]
    @Query private var infos: [AccountInfo]
    @Query private var assets: [Asset]
    @Query(sort: \LedgerEntry.date, order: .reverse) private var recentAll: [LedgerEntry]
    @AppStorage("hideAmounts") private var hide = false
    @State private var showAdd = false
    @State private var editing: LedgerEntry?

    init() {
        var d = FetchDescriptor<LedgerEntry>(sortBy: [SortDescriptor(\LedgerEntry.date, order: .reverse)])
        d.fetchLimit = 6
        _recentAll = Query(d)
    }

    private struct Period {
        var title: String
        var start: Date
        var end: Date
    }

    var body: some View {
        let now = Date.now
        var cal = Calendar.current
        cal.firstWeekday = 2
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now.startOfDay
        let month = now.startOfMonth
        let periods = [
            Period(title: "今天", start: now.startOfDay, end: now.startOfDay.adding(days: 1)),
            Period(title: "本周", start: weekStart, end: weekStart.adding(days: 7)),
            Period(title: "本月", start: month, end: month.adding(months: 1)),
            Period(title: "本年", start: now.startOfYear, end: now.startOfYear.adding(years: 1)),
        ]
        var sums = Array(repeating: HomeSum(), count: periods.count)
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        var daily = Array(repeating: 0.0, count: daysInMonth)
        for e in entries where e.type != .transfer && e.date >= periods[3].start {
            let v = e.cny
            for (i, p) in periods.enumerated() where e.date >= p.start && e.date < p.end {
                if e.type == .income { sums[i].income += v } else { sums[i].expense += v }
            }
            if e.type == .expense && e.date >= month && e.date < month.adding(months: 1) {
                let d = cal.component(.day, from: e.date) - 1
                if d >= 0 && d < daysInMonth { daily[d] += v }
            }
        }
        let balances = Balances.compute(entries, infos: infos).filter { !$0.excluded }
        let netWorth = balances.reduce(0) { $0 + $1.cny }
        let activeAssets = assets.filter { !$0.isRetired }
        let assetDaily = activeAssets.reduce(0) { $0 + $1.dailyCost }
        let canReplace = activeAssets.filter(\.reachedTarget).count

        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topBar
                    hero(today: sums[0], month: sums[2], daily: daily)
                    HStack(spacing: 12) {
                        NavigationLink(value: Route.accounts) {
                            MiniCard(title: "净资产", value: money(netWorth), footnote: "\(balances.filter { $0.balance != 0 }.count) 个账户",
                                     icon: "building.columns")
                        }
                        NavigationLink(value: Route.assets) {
                            MiniCard(title: "物品每天花费", value: hide ? "****" : "\(Fmt.plain(assetDaily))",
                                     footnote: activeAssets.isEmpty ? "还没有物品" : (canReplace > 0 ? "\(canReplace) 件可以换了" : "\(activeAssets.count) 件在用"),
                                     icon: "shippingbox", highlight: canReplace > 0)
                        }
                    }
                    .buttonStyle(.plain)

                    Card(padding: 0) {
                        HStack(spacing: 0) {
                            ForEach([1, 2, 3], id: \.self) { i in
                                NavigationLink(value: Route.period(title: periods[i].title, start: periods[i].start, end: periods[i].end)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Caption(periods[i].title + "支出")
                                        Text(money(sums[i].expense)).font(Theme.number(17, .medium)).lineLimit(1).minimumScaleFactor(0.6)
                                        Text("收入 \(money(sums[i].income))").font(.caption2).foregroundStyle(Theme.tertiary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if i != 3 { Rectangle().fill(Theme.separator).frame(width: 0.5).padding(.vertical, 14) }
                            }
                        }
                    }

                    HStack {
                        Text("最近记录").font(.headline)
                        Spacer()
                        NavigationLink(value: Route.flow) {
                            HStack(spacing: 2) { Text("全部流水"); Image(systemName: "chevron.right").font(.caption2) }
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.top, 4)

                    Card(padding: 0) {
                        if recentAll.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray").font(.title2).foregroundStyle(Theme.tertiary)
                                Text("还没有记录，点下方 + 记一笔，或在设置里导入随手记").font(.footnote).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(28)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(recentAll.enumerated()), id: \.element.id) { i, e in
                                Button { editing = e } label: {
                                    EntryRow(entry: e, showDate: true).padding(.horizontal, 16).padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                if i < recentAll.count - 1 { Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 64) }
                            }
                        }
                    }
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)

            BottomBar(showAdd: $showAdd)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAdd) { EntryEditView(entry: nil) }
        .sheet(item: $editing) { EntryEditView(entry: $0) }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "openAdd") {
                try? await Task.sleep(for: .seconds(1))
                showAdd = true
            }
            #endif
        }
    }

    private func money(_ v: Double) -> String { hide ? "****" : Fmt.plain(v) }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.todayTitle.string(from: .now)).font(.footnote).foregroundStyle(Theme.secondary)
                Text("价值账本").font(.title2.weight(.semibold))
            }
            Spacer()
            Button { hide.toggle() } label: {
                Image(systemName: hide ? "eye.slash" : "eye")
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle())
            }
            NavigationLink(value: Route.search) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: Circle())
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.top, 8)
    }

    private func hero(today: HomeSum, month: HomeSum, daily: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption("今日支出")
            Text(money(today.expense)).font(Theme.bigNumber(50)).lineLimit(1).minimumScaleFactor(0.5)
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.income).frame(width: 6, height: 6)
                    Text("本月收入").foregroundStyle(Theme.secondary)
                    Text(money(month.income)).font(Theme.number(15))
                }
                HStack(spacing: 6) {
                    Circle().fill(Theme.expense).frame(width: 6, height: 6)
                    Text("本月支出").foregroundStyle(Theme.secondary)
                    Text(money(month.expense)).font(Theme.number(15))
                }
            }
            .font(.subheadline)
            if !hide {
                let today = Calendar.current.component(.day, from: .now)
                Chart(Array(daily.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("日", String(i + 1)), y: .value("支出", v), width: .ratio(0.55))
                        .foregroundStyle(i + 1 == today ? Theme.accent : Color.white.opacity(0.22))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 56)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MiniCard: View {
    let title: String
    let value: String
    let footnote: String
    let icon: String
    var highlight = false

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.subheadline).foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.tertiary)
                }
                Caption(title)
                Text(value).font(Theme.number(22)).lineLimit(1).minimumScaleFactor(0.5)
                Text(footnote).font(.caption).foregroundStyle(highlight ? Theme.accent : Theme.tertiary)
            }
        }
    }
}

private struct BottomBar: View {
    @Binding var showAdd: Bool

    var body: some View {
        HStack(spacing: 0) {
            BarItem(route: .accounts, symbol: "creditcard", title: "账户")
            BarItem(route: .flow, symbol: "list.bullet", title: "流水")
            Button { showAdd = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 54, height: 54)
                    .background(Theme.accentGradient, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
            }
            .frame(maxWidth: .infinity)
            BarItem(route: .assets, symbol: "shippingbox", title: "物品")
            BarItem(route: .settings, symbol: "gearshape", title: "设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.separator))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private struct BarItem: View {
        let route: Route
        let symbol: String
        let title: String
        var body: some View {
            NavigationLink(value: route) {
                VStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 19))
                    Text(title).font(.system(size: 10))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
    }
}
