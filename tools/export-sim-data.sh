#!/bin/zsh
# 把模拟器里「价值账本」的全部数据导出到 ValueBook/Seed，打包 ipa 前运行。
# 用法：tools/export-sim-data.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.lazymice.valuebook
# 优先用已启动的模拟器；都没启动就找装了这个 App 的模拟器并启动它
DATA=$(xcrun simctl get_app_container booted "$BUNDLE" data 2>/dev/null || true)
if [[ -z "$DATA" ]]; then
  for U in $(xcrun simctl list devices available -j | python3 -c 'import json,sys; [print(d["udid"]) for r in json.load(sys.stdin)["devices"].values() for d in r]'); do
    if [[ -d ~/Library/Developer/CoreSimulator/Devices/$U/data/Containers/Bundle/Application ]] && \
       grep -rqs "$BUNDLE" ~/Library/Developer/CoreSimulator/Devices/$U/data/Containers/Bundle/Application/*/*.app/Info.plist; then
      xcrun simctl boot "$U" 2>/dev/null || true
      xcrun simctl bootstatus "$U" >/dev/null
      DATA=$(xcrun simctl get_app_container "$U" "$BUNDLE" data)
      break
    fi
  done
fi
if [[ -z "$DATA" ]]; then
  echo "❌ 找不到装了价值账本的模拟器，没有导出（ValueBook/Seed 保持原样）" >&2
  exit 1
fi
SRC="$DATA/Library/Application Support/default.store"
PREFS="$DATA/Library/Preferences/$BUNDLE.plist"
OUT=ValueBook/Seed
mkdir -p "$OUT"

# VACUUM INTO 会把 WAL 里未合并的修改一起写进单个干净文件
rm -f "$OUT/Seed.store"
sqlite3 "$SRC" "VACUUM INTO '$PWD/$OUT/Seed.store'"

# 偏好设置（去掉测试用启动参数）
if [[ -f "$PREFS" ]]; then
  cp "$PREFS" "$OUT/SeedDefaults.plist"
  plutil -convert xml1 "$OUT/SeedDefaults.plist"
  for k in open openAdd importPath demoAssets; do
    plutil -remove "$k" "$OUT/SeedDefaults.plist" 2>/dev/null || true
  done
fi

S="$OUT/Seed.store"
# 版本号只看记录内容（不看 SwiftData 内部历史），数据没变版本就不变，手机不会被重复覆盖
for t in ZLEDGERENTRY ZASSET ZACCOUNTINFO; do sqlite3 "$S" "select * from $t order by Z_PK"; done \
  | shasum -a 256 | cut -c1-12 > "$OUT/SeedVersion.txt"
echo "已导出到 ${OUT}："
echo "  流水 $(sqlite3 "$S" 'select count(*) from ZLEDGERENTRY') 条"
echo "  物品 $(sqlite3 "$S" 'select count(*) from ZASSET') 件"
echo "  账户 $(sqlite3 "$S" 'select count(*) from ZACCOUNTINFO') 个"
