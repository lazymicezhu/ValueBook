import SwiftUI
import SwiftData

@main
struct ValueBookApp: App {
    init() { Rates.migrate() }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(DataPackage.container)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    private var importer = Importer.shared
    private var cloud = CloudSync.shared

    @State private var path: [Route] = {
        // 测试用：启动参数 -open assets/flow/accounts/settings/stats
        switch UserDefaults.standard.string(forKey: "open") {
        case "assets": return [.assets]
        case "flow": return [.flow]
        case "accounts": return [.accounts]
        case "settings": return [.settings]
        case "stats": return [.stats]
        case "categories": return [.categories]
        default: return []
        }
    }()

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .appDestinations()
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .tint(Theme.accent)
        // 从微信「用其他应用打开」、文件 App 分享过来的 CSV
        .onOpenURL { url in
            guard url.isFileURL else { return }
            path = []
            Task { await importer.importFile(at: url, into: context) }
        }
        .overlay {
            if importer.running {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: importer.progress)
                            .frame(width: 200)
                        Text(importer.stage).font(.subheadline)
                        Text("\(Int(importer.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("导入结果", isPresented: Binding(get: { importer.message != nil && !importer.running },
                                             set: { if !$0 { importer.message = nil } })) {
            Button("好") { importer.message = nil }
        } message: { Text(importer.message ?? "") }
        // 云同步：改了数据过几秒推送，回到前台拉取，进后台推送，前台时每分钟拉一次
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in cloud.schedule(context) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await cloud.sync(context) } }
            if phase == .background { cloud.syncInBackground(context) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { await cloud.sync(context) }
            }
        }
        .task {
            Asset.refreshAllAddOns(in: context)
            await cloud.sync(context)
            #if DEBUG
            // 测试用：启动参数 -importPath /path/to.csv 直接导入，-demoAssets YES 从大额数码支出生成物品
            if let path = UserDefaults.standard.string(forKey: "importPath") {
                let start = Date()
                await importer.importFile(at: URL(fileURLWithPath: path), into: context)
                let line = "IMPORT \(String(format: "%.1f", Date().timeIntervalSince(start)))s \(importer.message ?? "")"
                print(line)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? line.write(to: docs.appendingPathComponent("import-log.txt"), atomically: true, encoding: .utf8)
            }
            if UserDefaults.standard.bool(forKey: "demoAssets") {
                let expense = EntryType.expense.rawValue
                let all = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.typeRaw == expense }))) ?? [])
                    .filter { $0.amount >= 3000 && $0.assetID == nil && $0.subcategory == "数码" }
                for e in all.prefix(8) {
                    let a = Asset(name: e.note.isEmpty ? "数码 \(Fmt.day.string(from: e.date))" : e.note, category: "数码",
                                  purchaseDate: e.date, price: e.cny, method: .accelerated, lifeYears: 4, residualRate: 0.1)
                    a.targetYears = AssetCategory.targetYears("数码")
                    context.insert(a)
                    e.assetID = a.id
                }
                try? context.save()
            }
            #endif
        }
    }
}
