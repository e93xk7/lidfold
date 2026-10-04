#!/bin/sh
# M1：錄一次闔蓋。用法：scripts/record.sh close_normal_1
#
# 流程：跑起來 → 等兩秒別碰（量靜止雜訊）→ 闔蓋 → 螢幕黑了、機器睡了
#       → 打開上蓋、解鎖 → 回到這個終端機按 Ctrl-C。
set -e
cd "$(dirname "$0")/.."
[ -n "$1" ] || { echo "用法：scripts/record.sh <名字>  例：close_normal_1"; exit 2; }
swift build >/dev/null
mkdir -p data
echo "→ data/$1.csv"
echo "  先別碰上蓋，等兩秒，再闔蓋。打開後回來按 Ctrl-C。"
exec .build/debug/lidfold-cli --csv "data/$1.csv"
