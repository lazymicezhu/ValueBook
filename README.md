# 价值账本 ValueBook

**中文** | [English](README.en.md)

一个 iOS 记账 App，除了记录收支，还会算出你买的每件东西**平均每天花了多少钱**，告诉你它什么时候「用回本」了。

## 功能

- **记账**：收入、支出、转账，多账户、多币种（港币、美元等按设置里的汇率折算成人民币）
- **首页**：今日支出，本月收入与支出，本月每日支出柱状图，本周 / 本月 / 本年汇总，今日记录
- **物品**：从流水里挑一笔买入记录生成物品，配件、续费可以挂成附属账目
  - **日均花费**：每一笔钱各自除以「付款日到今天的天数」，再加起来；设了使用年限的物品，刚付的钱至少按 7 / 30 / 60 天摊（设置里选）
  - **使用年限**：想用几年就填几年，从第一笔付款起用满就提示「可以换了」，之后再加配件、续费也不会推迟
  - **大类**：自建分组（如「摄影」「家具」）把物品归到一起看合计日均，已处置的按（花费 − 卖出价）摊到今天计入；大类和组内物品都能调整顺序，大类可以收起
  - **图表**：设了年限的物品画日均曲线，订阅这类不设年限的画每月花费柱状图
  - **折旧估值**：直线 / 加速折旧，也可以手动记二手估值
- **账户**：余额、净资产、账户分组，可从净资产里排除某个账户
- **统计**：按月 / 按年看分类构成和趋势
- **导入**：随手记导出的 CSV，可以从「文件」选，也可以从微信「用其他应用打开」
- **数据包**（`.vbbackup`）：整库导出备份
- **云同步**：自建的 Cloudflare Worker + D1，多台设备按记录同步

## 技术

- SwiftUI + SwiftData + Swift Charts，iOS 17+
- 工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成，仓库里不放 `.xcodeproj`
- 同步服务端在 `cloud/`（Cloudflare Workers + D1）

## 目录

```
ValueBook/Sources/   App 源码
cloud/               同步服务端
tools/               打包脚本
CHANGELOG.md         版本记录
```

## 编译

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # 填入同步服务域名
xcodegen generate
open ValueBook.xcodeproj
```

不配 `Secrets.xcconfig` 也能编译，只是没有默认同步地址，可以在 App 里手动填。

## 私密配置

这些文件只在本地，不进仓库（见 `.gitignore`），仓库里只放带占位符的样例：

| 本地文件 | 内容 | 样例 |
|---|---|---|
| `Config/Secrets.xcconfig` | 同步服务域名 | `Config/Secrets.example.xcconfig` |
| `cloud/wrangler.jsonc` | D1 数据库 id | `cloud/wrangler.example.jsonc` |
| `cloud/.sync-token` | 同步密钥 | — |

## 打包发布

```bash
tools/release.sh 1.2.0   # 新版本；不带参数则只把 build 号加 1
```

脚本会依次：更新 `project.yml` 里的版本号 → Release 编译（不签名）→ 输出到 `dist/价值账本-ValueBook-v<版本>(<build>).ipa`。签名用自己的证书完成。ipa 里不带数据，装好后在设置 → 云同步里填密钥，数据从云端拉下来。

发布后：

```bash
git commit -am "Release v1.2.0" && git tag v1.2.0 && git push --follow-tags
```

> 导出的数据包里含有个人账单数据，不要上传到公开的地方。

## 云同步部署

```bash
cd cloud
cp wrangler.example.jsonc wrangler.jsonc   # 填入 D1 数据库 id
wrangler d1 execute valuebook-sync --remote --file schema.sql
wrangler secret put SYNC_TOKEN
wrangler deploy
```

然后在 App 的设置 → 云同步里填入同一个 token。
