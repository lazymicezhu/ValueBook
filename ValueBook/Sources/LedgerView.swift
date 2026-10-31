import SwiftUI
import SwiftData

/// 流水：按年看，月份可折叠，按天分组
struct FlowView: View {
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var showAdd = false

    var body: some View {
        YearFlow(year: year)
            .id(year)
            .background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 16) {
                        Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                        Text("\(String(year))年").font(.headline).fixedSize()
                        Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink(value: Route.search) { Image(systemName: "magnifyingglass") }
                    Menu {
                        NavigationLink(value: Route.stats) { Label("收支统计", systemImage: "chart.bar") }
                        NavigationLink(value: Route.categories) { Label("分类汇总", systemImage: "square.grid.2x2") }
                        Button { showAdd = true } label: { Label("记一笔", systemImage: "plus") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .sheet(isPresented: $showAdd) { EntryEditView(entry: nil) }
    }
}

private struct YearFlow: View {
    @Query private var entries: [LedgerEntry]
    @State private var expanded: Set<Date> = []
    @State private var editing: LedgerEntry?
    @State private var didInit = false

    init(year: Int) {
        let start = Calendar.current.date(from: DateComponents(year: year))!
        let end = start.adding(years: 1)
        _entries = Query(filter: Filters.range(start, end), sort: \LedgerEntry.date, order: .reverse)
    }

    var body: some View {
        let months = Dictionary(grouping: entries) { $0.date.startOfMonth }.sorted { $0.key > $1.key }
        let income = entries.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }
        let expense = entries.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }
        List {
            VStack(alignment: .leading, spacing: 8) {
                Caption("年度结余")
                Text(Fmt.plain(income - expense)).font(Theme.bigNumber(44)).lineLimit(1).minimumScaleFactor(0.5)
                IncomeExpenseLine(income: income, expense: expense)
            }
            .padding(.vertical, 10)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if entries.isEmpty {
                Text("这一年没有记录").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(40)
                    .listRowBackground(Color.clear)
            }

            ForEach(months, id: \.key) { month, items in
                let open = expanded.contains(month)
                let mi = items.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }
                let me = items.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }
                Button {
                    withAnimation(.snappy) { if open { expanded.remove(month) } else { expanded.insert(month) } }
                } label: {
                    HStack(alignment: .center) {
                        Text("\(Calendar.current.component(.month, from: month))月").font(.title3.weight(.semibold))
                        Text("结余 \(Fmt.plain(mi - me))").font(Theme.number(13)).foregroundStyle(Theme.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.plain(mi)).foregroundStyle(Theme.income)
                            Text(Fmt.plain(me)).foregroundStyle(Theme.expense)
                        }
                        .font(Theme.number(13))
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.card)

                if open {
                    DayGroups(items: items, editing: $editing)
                }
            }
            Color.clear.frame(height: 30).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { EntryEditView(entry: $0) }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            if let first = months.first?.key { expanded = [first] }
        }
    }
}

/// 一组流水按天展开（在 List 里用）
struct DayGroups: View {
    let items: [LedgerEntry]
    var showYear = false
    @Binding var editing: LedgerEntry?
    @Environment(\.modelContext) private var context

    var body: some View {
        let days = Dictionary(grouping: items) { $0.date.startOfDay }.sorted { $0.key > $1.key }
        ForEach(days, id: \.key) { day, list in
            DayHeader(day: day, items: list, showYear: showYear)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            ForEach(list) { e in
                Button { editing = e } label: { EntryRow(entry: e) }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.card)
                    .listRowSeparatorTint(Theme.separator)
                    .swipeActions {
                        Button(role: .destructive) {
                            let assetID = e.isAddOn ? e.assetID : nil
                            context.delete(e)
                            try? context.save()
                            Asset.refreshAddOns(id: assetID, in: context)
                        } label: { Label("删除", systemImage: "trash") }
                    }
            }
        }
    }
}

struct DayHeader: View {
    let day: Date
    let items: [LedgerEntry]
    var showYear = false

    var body: some View {
        let inc = items.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }
        let exp = items.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }
        HStack(alignment: .center, spacing: 12) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(Theme.number(26, .light))
                .frame(minWidth: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.weekday.string(from: day)).font(.caption)
                Text(showYear ? Fmt.yearMonth.string(from: day) : Fmt.monthDot.string(from: day)).font(.caption2).foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(Theme.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.plain(inc - exp)).font(Theme.number(15, .medium))
                HStack(spacing: 6) {
                    if inc != 0 { Text("收 \(Fmt.plain(inc))").foregroundStyle(Theme.income) }
                    if exp != 0 { Text("支 \(Fmt.plain(exp))").foregroundStyle(Theme.expense) }
                }
                .font(Theme.number(11))
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

struct IncomeExpenseLine: View {
    let income: Double
    let expense: Double
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(Theme.income).frame(width: 6, height: 6)
                Text("收入").foregroundStyle(Theme.secondary)
                Text(Fmt.plain(income)).font(Theme.number(15))
            }
            HStack(spacing: 6) {
                Circle().fill(Theme.expense).frame(width: 6, height: 6)
                Text("支出").foregroundStyle(Theme.secondary)
                Text(Fmt.plain(expense)).font(Theme.number(15))
            }
        }
        .font(.subheadline)
    }
}

/// 某个时间段 / 账户 / 分类的流水
struct FilteredFlowView: View {
    let title: String
    let filter: Predicate<LedgerEntry>
    var showYear = true

    var body: some View {
        EntryList(filter: filter, showYear: showYear)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct EntryList: View {
    @Query private var entries: [LedgerEntry]
    private let showYear: Bool
    private let showSummary: Bool
    @State private var editing: LedgerEntry?

    init(filter: Predicate<LedgerEntry>, limit: Int? = nil, showYear: Bool = false, showSummary: Bool = true) {
        self.showYear = showYear
        self.showSummary = showSummary
        var d = FetchDescriptor<LedgerEntry>(predicate: filter, sortBy: [SortDescriptor(\LedgerEntry.date, order: .reverse)])
        d.fetchLimit = limit
        _entries = Query(d)
    }

    var body: some View {
        let income = entries.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }
        let expense = entries.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }
        List {
            if showSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Caption("结余")
                    Text(Fmt.plain(income - expense)).font(Theme.bigNumber(40)).lineLimit(1).minimumScaleFactor(0.5)
                    IncomeExpenseLine(income: income, expense: expense)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if entries.isEmpty {
                Text("没有记录").foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity).padding(40)
                    .listRowBackground(Color.clear)
            }
            DayGroups(items: entries, showYear: showYear, editing: $editing)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .sheet(item: $editing) { EntryEditView(entry: $0) }
    }
}

struct SummaryCell: View {
    var title: String
    var value: Double
    var color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.plain(value)).font(.subheadline.monospacedDigit().bold()).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct EntryRow: View {
    let entry: LedgerEntry
    var showDate = false

    private var title: String {
        if entry.type == .transfer {
            return entry.isBalanceAdjust ? "余额调整" : "转账"
        }
        return entry.subcategory.isEmpty ? (entry.category.isEmpty ? entry.type.rawValue : entry.category) : entry.subcategory
    }

    private var tint: Color {
        switch entry.type {
        case .expense: return entry.assetID != nil ? Theme.accent : Theme.expense
        case .income: return Theme.income
        case .transfer: return .white
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(entry.assetID != nil ? Theme.accent : .white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(Theme.cardHigh, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(Theme.number(16))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var icon: String {
        if entry.assetID != nil { return "shippingbox" }
        switch entry.type {
        case .income: return "arrow.down.left"
        case .transfer: return entry.isBalanceAdjust ? "slider.horizontal.3" : "arrow.left.arrow.right"
        case .expense: return CategoryIcon.symbol(entry.category + entry.subcategory)
        }
    }

    private var detail: String {
        var parts: [String] = []
        parts.append(showDate ? Fmt.shortDateTime.string(from: entry.date) : Fmt.time.string(from: entry.date))
        if entry.type == .transfer && !entry.toAccount.isEmpty {
            parts.append("\(entry.account) → \(entry.toAccount)")
        } else if !entry.account.isEmpty {
            parts.append(entry.account)
        }
        if !entry.note.isEmpty { parts.append(entry.note) }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        let symbol = entry.currency == "CNY" ? "" : Rates.symbol(entry.currency)
        var s = symbol + Fmt.plain(entry.amount)
        if entry.type == .transfer && entry.toAmount != 0 && entry.toCurrency != entry.currency {
            s += " → \(Rates.symbol(entry.toCurrency))\(Fmt.plain(entry.toAmount))"
        }
        return s
    }
}

/// 常见分类的图标
enum CategoryIcon {
    static func symbol(_ category: String) -> String {
        let map: [(String, String)] = [
            ("咖啡", "cup.and.saucer"), ("奶茶", "cup.and.saucer"), ("零食", "popcorn"), ("水果", "carrot"),
            ("餐", "fork.knife"), ("食", "fork.knife"), ("酒", "wineglass"), ("打车", "car"), ("地铁", "tram"),
            ("公交", "bus"), ("飞机", "airplane"), ("火车", "tram"), ("单车", "bicycle"), ("交通", "car"),
            ("数码", "laptopcomputer"), ("衣", "tshirt"), ("日用", "basket"), ("购物", "bag"),
            ("游戏", "gamecontroller"), ("订阅", "repeat"), ("健身", "figure.run"), ("电影", "film"), ("娱乐", "sparkles"),
            ("书", "book"), ("学", "graduationcap"), ("医", "cross.case"), ("药", "pills"),
            ("话费", "phone"), ("房", "house"), ("居家", "house"), ("人情", "gift"), ("送礼", "gift"),
            ("旅", "airplane"), ("胶片", "camera"), ("摄", "camera"), ("快递", "shippingbox"),
        ]
        return map.first { category.contains($0.0) }?.1 ?? "circle.grid.2x2"
    }
}
