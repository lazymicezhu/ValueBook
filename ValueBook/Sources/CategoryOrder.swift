import SwiftUI
import SwiftData

/// 分类顺序：在「分类排序」里拖过的按用户的来；
/// 没拖过的按使用次数排，并把相关的小类（早餐 / 中餐 / 晚餐…）挨在一起
enum CategoryOrder {
    /// 应该挨在一起的小类，组内按这里的先后排；整组出现在组里最常用那项的位置
    static let clusters: [[String]] = [
        ["早餐", "早饭", "中餐", "午餐", "午饭", "晚餐", "晚饭", "夜宵", "宵夜", "三餐", "加餐", "下午茶"],
        ["零食", "水果零食", "水果", "冰淇淋", "甜品"],
        ["奶茶咖啡", "咖啡", "奶茶", "饮料", "烟酒饮品", "酒水"],
        ["买菜", "粮油", "调味"],
        ["药品", "治疗", "保健", "核酸"],
        ["请客", "送礼", "发红包", "亲密付"],
        ["借出", "还钱", "借钱"],
    ]

    private static func key(_ type: EntryType, _ category: String?) -> String {
        category.map { "catOrder.\(type.rawValue).\($0)" } ?? "catOrder.\(type.rawValue)"
    }

    /// 保存的顺序；category 为 nil 表示大类的顺序
    static func saved(_ type: EntryType, _ category: String? = nil) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key(type, category))
    }

    static func save(_ list: [String], _ type: EntryType, _ category: String? = nil) {
        UserDefaults.standard.set(list, forKey: key(type, category))
    }

    /// 清掉这个类型保存的全部顺序
    static func reset(_ type: EntryType) {
        let prefix = key(type, nil)
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k == prefix || k.hasPrefix(prefix + ".") {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    /// 按保存的顺序排，保存里没有的（新出现的分类）接在后面
    static func apply(_ items: [String], saved: [String]) -> [String] {
        let set = Set(items)
        let head = saved.filter(set.contains)
        let headSet = Set(head)
        return head + items.filter { !headSet.contains($0) }
    }

    /// 把相关的小类排到一起
    static func clustered(_ items: [String]) -> [String] {
        let present = Set(items)
        var out: [String] = []
        var used = Set<String>()
        for it in items where !used.contains(it) {
            if let c = clusters.first(where: { $0.contains(it) }) {
                for m in c where present.contains(m) && used.insert(m).inserted { out.append(m) }
            } else {
                out.append(it)
                used.insert(it)
            }
        }
        return out
    }

    /// tree 是按使用次数排好的，返回最终显示顺序
    static func order(_ tree: [(String, [String])], _ type: EntryType) -> [(String, [String])] {
        let subs = Dictionary(tree.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let cats = saved(type).map { apply(tree.map(\.0), saved: $0) } ?? tree.map(\.0)
        return cats.map { c in
            let s = subs[c] ?? []
            return (c, saved(type, c).map { apply(s, saved: $0) } ?? clustered(s))
        }
    }
}

/// 分类排序：拖动调整大类、小类的先后（记一笔的分类滚轮按这个顺序）
struct CategorySortView: View {
    @Query private var entries: [LedgerEntry]
    @State private var type: EntryType = .expense
    @State private var nodes: [Node] = []
    @State private var confirmReset = false

    struct Node: Identifiable, Hashable {
        var name: String
        var subs: [String]
        var id: String { name }
    }

    var body: some View {
        List {
            Section {
                Picker("", selection: $type) {
                    Text("支出").tag(EntryType.expense)
                    Text("收入").tag(EntryType.income)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(nodes) { n in
                    NavigationLink {
                        SubcategorySortView(type: type, category: n.name, subs: n.subs)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: CategoryIcon.symbol(n.name)).foregroundStyle(Theme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.name)
                                if !n.subs.isEmpty {
                                    Text(n.subs.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .onMove { from, to in
                    nodes.move(fromOffsets: from, toOffset: to)
                    CategoryOrder.save(nodes.map(\.name), type)
                }
            } header: {
                Text("大类")
            } footer: {
                Text("长按拖动调整顺序，点进大类可以调整里面小类的顺序。没调整过的小类会按使用次数排，相关的（比如早餐、中餐、晚餐）自动排在一起。")
            }
            Section {
                Button("恢复默认顺序", role: .destructive) { confirmReset = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("分类排序")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: type) { _, _ in reload() }
        .confirmationDialog("恢复「\(type.rawValue)」分类的默认顺序？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { CategoryOrder.reset(type); reload() }
        }
    }

    private func reload() {
        nodes = (CategoryData.build(entries)[type]?.tree ?? []).map { Node(name: $0.0, subs: $0.1) }
    }
}

private struct SubcategorySortView: View {
    let type: EntryType
    let category: String
    @State var subs: [String]

    var body: some View {
        List {
            Section {
                ForEach(subs, id: \.self) { s in
                    HStack(spacing: 12) {
                        Image(systemName: CategoryIcon.symbol(category + s)).foregroundStyle(Theme.accent).frame(width: 24)
                        Text(s)
                    }
                }
                .onMove { from, to in
                    subs.move(fromOffsets: from, toOffset: to)
                    CategoryOrder.save(subs, type, category)
                }
            } footer: {
                Text(subs.isEmpty ? "这个大类下没有小类" : "长按拖动调整顺序")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}
