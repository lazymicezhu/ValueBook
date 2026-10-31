#!/bin/zsh
# 打一个新版本的 ipa：导出模拟器数据 → 版本号加一 → 编译 → 打包到 dist/
# 用法：
#   tools/release.sh          只把 build 号加 1（同一版本重新打包）
#   tools/release.sh 1.2.0    设成新版本，build 号也加 1
# 打完后提交并打 tag：git commit -am "Release vX.Y.Z" && git tag vX.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)}
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml) + 1 ))
sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/; s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$BUILD\"/" project.yml
echo "▶ 版本 $VERSION ($BUILD)"

tools/export-sim-data.sh
xcodegen generate --quiet

DD=/tmp/valuebook-release
rm -rf "$DD"
xcodebuild -project ValueBook.xcodeproj -scheme ValueBook -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build -quiet

mkdir -p "$DD/pkg/Payload" dist
cp -R "$DD/Build/Products/Release-iphoneos/ValueBook.app" "$DD/pkg/Payload/"
NAME="价值账本-ValueBook-v$VERSION($BUILD)"
(cd "$DD/pkg" && zip -qry out.ipa Payload)
cp "$DD/pkg/out.ipa" "dist/$NAME.ipa"
cp ValueBook/Seed/Seed.store "dist/$NAME-数据包.vbbackup"
# 根目录放一份最新的，方便直接拿去签名
cp "dist/$NAME.ipa" "价值账本-ValueBook.ipa"
cp ValueBook/Seed/Seed.store "价值账本-数据包.vbbackup"
echo "✅ dist/$NAME.ipa"
