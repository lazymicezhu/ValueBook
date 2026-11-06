# ValueBook 价值账本

[中文](README.md) | **English**

An iOS bookkeeping app. Besides tracking income and spending, it works out **how much each thing you bought costs you per day**, and tells you when it has "paid for itself".

The app UI is in Chinese.

## Features

- **Bookkeeping**: income, expenses and transfers across multiple accounts and currencies (HKD, USD, etc. are converted to CNY at the rates you set)
- **Home**: today's spending, this month's income and spending, a daily spending chart for the month, week / month / year totals, and today's entries
- **Items**: turn a purchase from your ledger into an item, and attach accessories or renewals to it as add-on entries
  - **Daily cost**: each payment is divided by the days since it was paid, and the results are added up; for items with a planned lifespan, a new payment is spread over at least 7 / 30 / 60 days (set in Settings)
  - **Planned lifespan**: set how many years you want to use an item; once that many years have passed since the first payment it is marked "ready to replace", and later accessories or renewals don't push the date back
  - **Groups**: your own groups (e.g. "Photography", "Furniture") show a combined daily cost; retired items count as (cost − sale price) spread up to today; groups and the items inside them can be reordered, and groups can be collapsed
  - **Charts**: items with a lifespan show a daily-cost curve; items without one, like subscriptions, show monthly spending bars
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
| `Config/Secrets.xcconfig` | sync server host and sync token (built into the app) | `Config/Secrets.example.xcconfig` |
| `cloud/wrangler.jsonc` | D1 database id | `cloud/wrangler.example.jsonc` |
| `cloud/.sync-token` | sync token | — |

## Release

```bash
tools/release.sh 1.2.0   # new version; with no argument it only bumps the build number
```

The script updates the version in `project.yml`, does an unsigned Release build, and writes `dist/价值账本-ValueBook-v<version>(<build>).ipa`. Sign it with your own certificate. The ipa carries no data but does contain the sync token (`SYNC_TOKEN` from `Config/Secrets.xcconfig`), so after installing it pulls the data straight from the server. **Install the ipa only on your own devices; never share it or upload it to a Release**, since anyone holding it can read and write your cloud data.

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

Then put the same token in `SYNC_TOKEN` in `Config/Secrets.xcconfig` so it gets built into the app; you can also enter it under Settings → Cloud Sync, which takes priority.
