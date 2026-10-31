import SwiftUI
import SwiftData
import Charts

struct StatsView: View {
    @State private var yearMode = false
    @State private var anchor = Date.now

    var body: some View {
        Group {
            let start = yearMode ? anchor.startOfYear : anchor.startOfMonth
            let end = yearMode ? start.adding(years: 1) : start.adding(months: 1)
            StatsContent(start: start, end: end, yearMode: yearMode)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 14) {
                            Button { anchor = yearMode ? anchor.adding(years: -1) : anchor.adding(months: -1) } label: { Image(systemName: "chevron.left") }
                            Text(yearMode ? "\(Calendar.current.component(.year, from: start))年" : Fmt.month.string(from: start))
                                .font(.headline).fixedSize()
                            Button { anchor = yearMode ? anchor.adding(years: 1) : anchor.adding(months: 1) } label: { Image(systemName: "chevron.right") }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("", selection: $yearMode) {
                            Text("月").tag(false)
                            Text("年").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                }
        }
    }
}

struct CategorySum: Identifiable {
    var name: String
    var amount: Double
    var count: Int
    var id: String { name }
}

struct PeriodSum: Identifiable {
    var date: Date
    var kind: String
    var amount: Double
    var id: String { "\(date.timeIntervalSince1970)\(kind)" }
}

struct StatsContent: View {
    @Query private var entries: [LedgerEntry]
    let yearMode: Bool
    let start: Date
    @State private var kind: EntryType = .expense
    @State private var drill: String?

    init(start: Date, end: Date, yearMode: Bool) {
        self.yearMode = yearMode
        self.start = start
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.date >= start && $0.date < end })
    }

    private var filtered: [LedgerEntry] { entries.filter { $0.type == kind } }

    private var byCategory: [CategorySum] {
        let source = drill == nil ? filtered : filtered.filter { $0.category == drill }
        let groups = Dictionary(grouping: source) { e -> String in
            let key = drill == nil ? e.category : e.subcategory
            return key.isEmpty ? "未分类" : key
        }
        return groups.map { CategorySum(name: $0.key, amount: $0.value.reduce(0) { $0 + $1.cny }, count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
    }

    private var trend: [PeriodSum] {
        let cal = Calendar.current
        var out: [PeriodSum] = []
        let unitCount = yearMode ? 12 : cal.range(of: .day, in: .month, for: start)!.count
        for i in 0..<unitCount {
            let s = yearMode ? start.adding(months: i) : start.adding(days: i)
            let e = yearMode ? s.adding(months: 1) : s.adding(days: 1)
            let inRange = entries.filter { $0.date >= s && $0.date < e }
            out.append(PeriodSum(date: s, kind: "支出", amount: inRange.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }))
            if yearMode {
                out.append(PeriodSum(date: s, kind: "收入", amount: inRange.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }))
            }
        }
        return out
    }

    var body: some View {
        let income = entries.filter { $0.type == .income }.reduce(0) { $0 + $1.cny }
        let expense = entries.filter { $0.type == .expense }.reduce(0) { $0 + $1.cny }
        let cats = byCategory
        let total = cats.reduce(0) { $0 + $1.amount }
        List {
            Section {
                HStack {
                    SummaryCell(title: "收入", value: income, color: Theme.income)
                    Divider()
                    SummaryCell(title: "支出", value: expense, color: Theme.expense)
                    Divider()
                    SummaryCell(title: "结余", value: income - expense, color: .primary)
                }
            }

            Section(yearMode ? "每月收支" : "每日支出") {
                Chart(trend) {
                    BarMark(x: .value("时间", $0.date, unit: yearMode ? .month : .day),
                            y: .value("金额", $0.amount))
                        .foregroundStyle(by: .value("类型", $0.kind))
                        .position(by: .value("类型", $0.kind))
                }
                .chartForegroundStyleScale(["支出": Theme.expense, "收入": Theme.income])
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(Fmt.short(v.as(Double.self) ?? 0)) } } }
                .frame(height: 180)
                .padding(.vertical, 6)
            }

            Section {
                Picker("", selection: $kind) {
                    Text("支出").tag(EntryType.expense)
                    Text("收入").tag(EntryType.income)
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, _ in drill = nil }

                if let drill {
                    Button { self.drill = nil } label: { Label("返回全部分类（当前：\(drill)）", systemImage: "chevron.left") }
                }

                if cats.isEmpty {
                    Text("没有数据").foregroundStyle(.secondary)
                } else {
                    Chart(cats.prefix(10)) {
                        SectorMark(angle: .value("金额", $0.amount), innerRadius: .ratio(0.6), angularInset: 1)
                            .foregroundStyle(by: .value("分类", $0.name))
                    }
                    .chartLegend(.hidden)
                    .overlay {
                        VStack {
                            Text(kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            Text(Fmt.yuan(total)).font(.headline.monospacedDigit())
                        }
                    }
                    .frame(height: 200)
                    .padding(.vertical, 6)

                    ForEach(cats) { c in
                        Button {
                            if drill == nil { drill = c.name == "未分类" ? "" : c.name }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(c.name)
                                    Text("\(c.count)笔").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Fmt.yuan(c.amount)).monospacedDigit()
                                    Text(String(format: "%.1f%%", total > 0 ? c.amount / total * 100 : 0))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                                }
                                ProgressView(value: total > 0 ? c.amount / total : 0)
                                    .tint(kind == .expense ? Theme.expense : Theme.income)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
