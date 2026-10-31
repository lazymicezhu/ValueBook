import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var importing = false
    @State private var importingPackage = false
    @State private var confirmRestore: URL?
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var confirmClear = false
    @State private var entryCount = 0
    @State private var assetCount = 0
    @State private var currencies: [String] = []
    @State private var localFiles: [URL] = []
    private var importer = Importer.shared
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "-") (\(info?["CFBundleVersion"] as? String ?? "-"))"
    }

    var body: some View {
        Group {
            Form {
                Section {
                    InfoRow("账单", "\(entryCount) 笔")
                    InfoRow("物品", "\(assetCount) 件")
                    InfoRow("版本", appVersion)
                }

                CloudSyncSection(onSynced: refreshCounts)

                Section {
                    Button {
                        importingPackage = false
                        importing = true
                    } label: {
                        Label("从「文件」选择 CSV", systemImage: "folder")
                    }
                    .disabled(importer.running)
                    ForEach(localFiles, id: \.self) { url in
                        Button {
                            Task { await importer.importFile(at: url, into: context); refreshCounts() }
                        } label: {
                            Label("导入 App 文件夹里的「\(url.lastPathComponent)」", systemImage: "doc.text")
                        }
                        .disabled(importer.running)
                    }
                    NavigationLink("从微信导入的方法") { ImportHelpView() }
                } header: {
                    Text("导入随手记 CSV")
                } footer: {
                    Text("最简单：在微信里打开 CSV 文件 → 右上角「…」→「用其他应用打开」→ 选「价值账本」，会自动导入。重复导入同一个文件不会产生重复记录。")
                }

                if !currencies.isEmpty {
                    Section {
                        ForEach(currencies, id: \.self) { RateRow(code: $0) }
                    } header: {
                        Text("外币汇率")
                    } footer: {
                        Text("外币账单按原币种显示，汇总统计时按这里的汇率折算成人民币。")
                    }
                }

                Section("分类与账户") {
                    NavigationLink { CategorySortView() } label: { Label("分类排序", systemImage: "arrow.up.arrow.down") }
                    NavigationLink { AccountGroupsView() } label: { Label("账户分类与归属", systemImage: "folder") }
                }

                Section {
                    Button { importingPackage = true; importing = true } label: {
                        Label("从数据包恢复", systemImage: "arrow.down.doc")
                    }
                    Button { export { try DataPackage.export(from: context) } } label: {
                        Label("导出数据包", systemImage: "shippingbox")
                    }
                    InfoRow("内置数据", Seed.fingerprint.map { fp in
                        UserDefaults.standard.string(forKey: Seed.appliedKey) == fp ? "\(fp) · 已导入" : "\(fp) · 未导入"
                    } ?? "无")
                } header: {
                    Text("数据包（全部数据）")
                } footer: {
                    Text("数据包（.vbbackup）包含全部流水、物品和账户。恢复会替换当前全部数据，替换前自动备份到「文件」App → 价值账本。也可以在微信 / 文件里用「用其他应用打开」选「价值账本」直接恢复。")
                }

                Section("导出") {
                    Button { export { try DataTransfer.exportEntries(try context.fetch(FetchDescriptor<LedgerEntry>())) } } label: {
                        Label("导出全部账单 CSV", systemImage: "square.and.arrow.up")
                    }
                    Button { export { try DataTransfer.exportAssets(try context.fetch(FetchDescriptor<Asset>())) } } label: {
                        Label("导出物品 CSV", systemImage: "square.and.arrow.up")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享 \(exportURL.lastPathComponent)", systemImage: "paperplane") }
                    }
                }

                Section {
                    Button("清空所有账单", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("物品不会被删除。")
                }

                Section("说明") {
                    Text("""
                    • 日均花费 = 每一笔钱 ÷ 它付款到今天的天数，再相加（卖掉的话扣除卖出价）
                    • 日均降到目标日均，就算用回本了，可以换
                    • 配件、续费可以挂在物品下，一起算进日均
                    """).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: refreshCounts)
            .onChange(of: importer.running) { _, running in if !running { refreshCounts() } }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text, .data]) { result in
                switch result {
                case .success(let url):
                    if importingPackage || url.pathExtension.lowercased() == DataPackage.ext {
                        confirmRestore = url
                    } else {
                        Task { await importer.importFile(at: url, into: context); refreshCounts() }
                    }
                case .failure(let err):
                    message = "选择文件失败：\(err.localizedDescription)"
                }
            }
            .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
            .confirmationDialog("用数据包替换当前全部数据？", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                                titleVisibility: .visible) {
                Button("替换（会先自动备份）", role: .destructive) {
                    if let url = confirmRestore { message = DataPackage.restore(from: url, into: context) }
                    refreshCounts()
                }
            } message: { Text(confirmRestore?.lastPathComponent ?? "") }
            .confirmationDialog("确定清空所有账单？不可恢复。", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    try? context.delete(model: LedgerEntry.self)
                    try? context.save()
                    refreshCounts()
                }
            }
        }
    }

    private func refreshCounts() {
        entryCount = (try? context.fetchCount(FetchDescriptor<LedgerEntry>())) ?? 0
        assetCount = (try? context.fetchCount(FetchDescriptor<Asset>())) ?? 0
        let foreign = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.currency != "CNY" })
        currencies = Array(Set(((try? context.fetch(foreign)) ?? []).map(\.currency))).filter { !$0.isEmpty }.sorted()
        localFiles = Importer.documentCSVs()
    }

    private func export(_ make: () throws -> URL) {
        do { exportURL = try make() } catch { message = "导出失败：\(error.localizedDescription)" }
    }
}

struct ImportHelpView: View {
    var body: some View {
        List {
            Section("方法一：微信直接打开（推荐）") {
                Text("1. 在微信聊天里点开 CSV 文件")
                Text("2. 点右上角「…」")
                Text("3. 选「用其他应用打开」")
                Text("4. 在列表里选「价值账本」（没看到就往右滑，点「更多」）")
                Text("5. App 打开后会自动导入并提示结果")
            }
            Section("方法二：先存到「文件」") {
                Text("1. 微信里打开文件 →「…」→「保存到文件」/「用其他应用打开」→「存储到文件」")
                Text("2. 回到这里点「从『文件』选择 CSV」，找到刚才保存的文件")
            }
            Section("方法三：电脑传") {
                Text("用数据线连接 Mac，在访达里选中 iPhone →「文件」→「价值账本」，把 CSV 拖进去；然后回到「我的」页面，会出现「导入 App 文件夹里的…」按钮。")
            }
            Section("随手记怎么导出") {
                Text("在随手记里导出 CSV（一般在「设置/更多」→「数据导出」），导出后发到微信「文件传输助手」，再用方法一。")
            }
        }
        .navigationTitle("导入方法")
    }
}

struct RateRow: View {
    let code: String
    @State private var text = ""

    var body: some View {
        HStack {
            Text("1 \(code) =")
            TextField("汇率", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, t in
                    if let v = Double(t), v > 0, abs(v - Rates.rate(code)) > 1e-9 { Rates.set(code, v) }
                }
            Text("人民币")
        }
        .onAppear { text = String(format: "%g", Rates.rate(code)) }
    }
}

/// 云同步设置：服务器地址、密钥、状态
struct CloudSyncSection: View {
    @Environment(\.modelContext) private var context
    var onSynced: () -> Void
    private var cloud = CloudSync.shared
    @State private var url = CloudSync.shared.serverURL
    @State private var token = CloudSync.shared.token

    init(onSynced: @escaping () -> Void) { self.onSynced = onSynced }

    var body: some View {
        Section {
            TextField("服务器地址", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: url) { _, v in cloud.serverURL = v }
            SecureField("密钥", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: token) { _, v in cloud.token = v }
            Button {
                Task { await cloud.sync(context); onSynced() }
            } label: {
                HStack {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if cloud.running { ProgressView() }
                }
            }
            .disabled(!cloud.enabled || cloud.running)
            if !cloud.status.isEmpty || cloud.lastSync != nil {
                InfoRow("状态", [cloud.status, cloud.lastSync.map { "上次 \($0.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        } header: {
            Text("云同步")
        } footer: {
            Text("填好密钥后自动同步：改了数据几秒后上传，打开 App 时拉取别的设备的修改。两台设备改了同一条时，后同步的为准。第一次同步以云端为准（先自动备份到「文件」App），本机独有的记录会传上去。开了云同步后，新版 App 里的内置数据不再覆盖本机。")
        }
    }
}
