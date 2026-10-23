#!/usr/bin/env bash
#
# create-dmg.sh —— 把构建好的 IceShot.app 打成压缩 DMG，并输出 SHA-256。
#
# 用法（在仓库根目录执行）：
#   Scripts/create-dmg.sh <IceShot.app 路径> <输出 .dmg 路径>
#
# 说明：
# - DMG 本身不签名、不公证；签名状态由传入的 .app 决定。
# - 只做打包，不改动 .app；调用前请自行确认 codesign 结果符合预期。
# - `.sha256` 只记录文件名（不写绝对路径），方便随包分发。

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "用法: $0 <IceShot.app> <输出.dmg>" >&2
  exit 64
fi

app_path=$1
output_path=$2

if [ ! -d "$app_path" ]; then
  echo "找不到应用包: $app_path" >&2
  exit 66
fi

staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT

cp -R "$app_path" "$staging_dir/IceShot.app"
ln -s /Applications "$staging_dir/Applications"

mkdir -p "$(dirname "$output_path")"
rm -f "$output_path" "${output_path}.sha256"

# macOS 27 起 `hdiutil create` 标记为弃用，改用 `diskutil image create from`。
diskutil image create from \
  --format UDZO \
  --volumeName "IceShot" \
  "$staging_dir" \
  "$output_path"

# 校验和按文件名生成（cd 到产物目录，避免把本机绝对路径写进 .sha256）。
output_dir=$(cd "$(dirname "$output_path")" && pwd)
dmg_name=$(basename "$output_path")
(cd "$output_dir" && shasum -a 256 "$dmg_name" | tee "${dmg_name}.sha256")
