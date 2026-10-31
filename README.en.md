# ValueBook 价值账本

[中文](README.md) | **English**

An iOS bookkeeping app. Besides tracking income and spending, it works out **how much each thing you bought costs you per day**, and tells you when it has "paid for itself".

The app UI is in Chinese.

## Features

- **Bookkeeping**: income, expenses and transfers across multiple accounts and currencies (HKD, USD, etc. are converted to CNY at the rates you set)
- **Home**: today's spending, this month's income and spending, a daily spending chart for the month, and week / month / year totals
- **Items**: turn a purchase from your ledger into an item, and attach accessories or renewals to it as add-on entries
  - **Daily cost**: each payment is divided by the days since it was paid, and the results are added up
  - **Target daily cost**: once the daily cost drops to your target, the item is marked "ready to replace", and the app predicts the date it gets there
  - **Depreciation**: straight-line or accelerated, plus manual resale valuations
- **Accounts**: balances, net worth, account groups, and excluding an account from net worth
- **Stats**: category breakdowns and trends by month or year
- **Import**: CSV exports from Suishouji (随手记), picked from Files or opened from WeChat via "Open in…"
- **Data packages** (`.vbbackup`): export the whole database as a backup
- **Cloud sync**: a self-hosted Cloudflare Worker + D1 backend that syncs record by record across devices

## Tech

- SwiftUI + SwiftData + Swift Charts, iOS 17+
- The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); `.xcodeproj` is not checked in
- The sync server lives in `cloud/` (Cloudflare Workers + D1)

## Layout

```
ValueBook/Sources/   app source
cloud/               sync server
tools/               packaging script
CHANGELOG.md         release notes
```

## Build

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill in the sync server host
xcodegen generate
open ValueBook.xcodeproj
```

It also builds without `Secrets.xcconfig`; there's just no default sync server, and you can enter one in the app.

## Private config

These files stay local and are git-ignored; the repo only has examples with placeholders:

| Local file | Contents | Example |
|---|---|---|
| `Config/Secrets.xcconfig` | sync server host | `Config/Secrets.example.xcconfig` |
| `cloud/wrangler.jsonc` | D1 database id | `cloud/wrangler.example.jsonc` |
| `cloud/.sync-token` | sync token | — |

## Release

```bash
tools/release.sh 1.2.0   # new version; with no argument it only bumps the build number
```

The script updates the version in `project.yml`, does an unsigned Release build, and writes `dist/价值账本-ValueBook-v<version>(<build>).ipa`. Sign it with your own certificate. The ipa carries no data: after installing, enter the token under Settings → Cloud Sync and the data comes down from the server.

Then:

```bash
git commit -am "Release v1.2.0" && git tag v1.2.0 && git push --follow-tags
```

> Exported data packages contain personal ledger data. Don't upload them anywhere public.

## Deploying cloud sync

```bash
cd cloud
cp wrangler.example.jsonc wrangler.jsonc   # fill in the D1 database id
wrangler d1 execute valuebook-sync --remote --file schema.sql
wrangler secret put SYNC_TOKEN
wrangler deploy
```

Then enter the same token under Settings → Cloud Sync in the app.
