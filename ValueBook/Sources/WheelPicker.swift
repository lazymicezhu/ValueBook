import SwiftUI

struct WheelItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var icon: String?
}

/// 一列滚轮：停在中间那行即选中，点某行也会滚过去
struct WheelColumn: View {
    let items: [WheelItem]
    @Binding var selection: String?
    var alignment: HorizontalAlignment = .center
    static let rowHeight: CGFloat = 54
    static let visibleRows: CGFloat = 5
    @State private var space = UUID()

    var body: some View {
        let h = Self.rowHeight * Self.visibleRows
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                        .frame(height: Self.rowHeight)
                        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { selection = item.id } }
                        .visualEffect { content, proxy in
                            let d = min(abs(proxy.frame(in: .named(space)).midY - h / 2) / Self.rowHeight, 3)
                            return content
                                .opacity(1 - d * 0.28)
                                .scaleEffect(1 - d * 0.07, anchor: alignment == .leading ? .leading : .center)
                        }
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $selection, anchor: .center)
        .contentMargins(.vertical, (h - Self.rowHeight) / 2, for: .scrollContent)
        .frame(height: h)
        .coordinateSpace(name: space)
        .sensoryFeedback(.selection, trigger: selection)
        // scrollPosition 的初始值在首次布局时不生效，手动滚到选中项
        .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
        }
    }

    private func row(_ item: WheelItem) -> some View {
        HStack(spacing: 12) {
            if let icon = item.icon {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Theme.accent).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body).lineLimit(1).minimumScaleFactor(0.7)
                if let s = item.subtitle {
                    Text(s).font(Theme.number(13)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }
}

/// 两栏滚轮面板（代替计算器键盘出现在底部）：左边分组，右边具体项
struct TwoWheelPanel: View {
    let groups: [String]
    let items: (String) -> [WheelItem]
    /// 当前值所在的分组和项
    let current: (group: String, item: String)?
    let addTitle: String
    /// 有值时显示「排序」按钮
    var onSort: (() -> Void)? = nil
    let onSelect: (WheelItem) -> Void
    let onAdd: (String, String) -> String?   // (分组, 新名称) → 新项的 id
    let onClose: () -> Void

    @State private var group: String?
    @State private var item: String?
    /// 最后一次回写给外面的值：滚动过程中不回写，停稳后才回写，避免外层页面跟着每一格重算
    @State private var committed: String?
    @State private var showAdd = false
    @State private var newName = ""

    init(groups: [String], items: @escaping (String) -> [WheelItem], current: (group: String, item: String)?,
         addTitle: String, onSort: (() -> Void)? = nil, onSelect: @escaping (WheelItem) -> Void,
         onAdd: @escaping (String, String) -> String?, onClose: @escaping () -> Void) {
        self.groups = groups; self.items = items; self.current = current; self.addTitle = addTitle; self.onSort = onSort
        self.onSelect = onSelect; self.onAdd = onAdd; self.onClose = onClose
        // 首次渲染就定位到当前值
        let g = current.map(\.group).flatMap { groups.contains($0) ? $0 : nil } ?? groups.first
        let list = items(g ?? "")
        let i = current.map(\.item).flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list.first?.id
        _group = State(initialValue: g)
        _item = State(initialValue: i)
        _committed = State(initialValue: i)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { newName = ""; showAdd = true } label: {
                    Image(systemName: "square.and.pencil").frame(width: 52, height: 44)
                }
                if let onSort {
                    Button(action: onSort) {
                        Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.headline).frame(width: 64, height: 44)
                        .background(Theme.cardHigh)
                }
            }
            .foregroundStyle(Theme.secondary)
            .background(Theme.card)
            Rectangle().fill(Theme.separator).frame(height: 0.5)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardHigh)
                    .frame(height: WheelColumn.rowHeight)
                    .padding(.horizontal, 10)
                HStack(spacing: 0) {
                    WheelColumn(items: groups.map { WheelItem(id: $0, title: $0) }, selection: $group)
                        .frame(width: 140)
                    WheelColumn(items: items(group ?? ""), selection: $item, alignment: .leading)
                        .id(group)   // 换分组时重建，回到合适的位置
                }
            }
            .padding(.vertical, 10)
        }
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
        .onChange(of: group) { _, g in
            let list = items(g ?? "")
            if !list.contains(where: { $0.id == item }) { item = list.first?.id }
        }
        .task(id: item) {
            guard item != committed else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            committed = item
            if let it = items(group ?? "").first(where: { $0.id == item }) { onSelect(it) }
        }
        .alert(addTitle, isPresented: $showAdd) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                if let id = onAdd(group ?? "", n) { item = id }
            }
        } message: {
            if let group { Text("添加到「\(group)」") }
        }
    }
}
