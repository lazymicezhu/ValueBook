# 更新日志 / Changelog

版本号格式 `主版本.次版本.修订 (build)`，每打一次 ipa，build 加 1。
Format: `MAJOR.MINOR.PATCH (build)`. The build number goes up by one with every ipa.

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
