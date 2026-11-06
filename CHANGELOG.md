# 更新日志 / Changelog

版本号格式 `主版本.次版本.修订 (build)`，每打一次 ipa，build 加 1。
Format: `MAJOR.MINOR.PATCH (build)`. The build number goes up by one with every ipa.

## v1.3.0 (4) — 2026-11-07

- 「什么时候可以换」改为**使用年限**：从第一笔付款起用满设定的年数就可以换，之后加配件、续费不再推迟；老数据按原来的达标日自动换算成年数
  "When to replace" is now a **planned lifespan**: an item is ready once that many years have passed since its first payment, and later accessories or renewals no longer push the date back; existing targets are converted to years from their old target dates
- 日均花费：设了年限的物品，刚付的钱至少按 30 天摊（设置里可改 7 / 60 天），新买东西、新加配件后日均不再一下子冲很高；订阅这类不设年限的仍按实际天数
  Daily cost: for items with a lifespan, a new payment is spread over at least 30 days (7 or 60 in Settings), so the daily cost no longer shoots up right after a purchase or add-on; items without a lifespan, like subscriptions, still use the actual days
- 新增**大类**：把物品归到一起看合计日均；已处置的物品按（花费 − 卖出价）摊到今天计入；大类和组内物品可手动排序，大类可收起；物品页改为按大类显示
  New **groups**: put items together to see a combined daily cost; retired items count as (cost − sale price) spread up to today; groups and the items in them can be reordered, and groups can be collapsed; the Items page is now organized by group
- 年限、大类和排序都随云同步和数据包保存
  Lifespans, groups and their order are saved in cloud sync and data packages
- 不设年限的物品详情改为每月花费柱状图加月均线
  Items without a lifespan now show monthly spending bars with a monthly average line
- 花费明细每页 5 笔，可翻页
  The spending list on an item shows 5 entries per page, with paging
- 已处置的物品盖一个「已处置」章；物品行显示总花费和已用天数
  Retired items get a "已处置" (retired) stamp; item rows show total cost and days used
- 首页「最近记录」改为**今日记录**；记一笔右上角加「完成」
  Home's "recent entries" is now **today's entries**; the entry screen has a "Done" button in the top right
- 修复从大类进入物品后返回不回到大类的问题
  Fixed going back from an item opened inside a group not returning to the group

## v1.2.0 (3) — 2026-10-31

- 设备间数据只靠云同步：移除 ipa 内置数据（打开新版自动覆盖本机）和「从数据包恢复」，删掉 `tools/export-sim-data.sh`；数据包只保留导出
  Data moves between devices only through cloud sync: removed the bundled seed data (which overwrote the device on first launch) and "Restore from data package", and dropped `tools/export-sim-data.sh`; data packages are export-only now

## v1.1.0 (2) — 2026-10-31

- 首页大数字改为**今日支出**，下方显示本月收入、本月支出；下方三格改为本周 / 本月 / 本年
  Home now shows **today's spending** as the headline, with this month's income and spending below; the summary row is now week / month / year
- 设置页显示 App 版本号
  Settings shows the app version
- 移除误打进 App 的空文件 `new.vbbackup`
  Removed a stray empty `new.vbbackup` from the app bundle

## v1.0 (1) — 2026-10-31

- 首个版本：记账、账户、物品日均成本、统计、随手记 CSV 导入、数据包、Cloudflare 云同步
  First version: bookkeeping, accounts, per-day cost of items, stats, CSV import, data packages, Cloudflare sync
