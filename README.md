# LidFold

把 iPhone Duo 的開合動畫搬到 MacBook：闔上上蓋時，螢幕內容看起來固定在空間裡不動，是機器繞著內容轉。

完整規格見 [docs/白皮書_v1.md](docs/白皮書_v1.md)。自用軟體，不簽章、不上架。

## 進度

| 里程碑 | 狀態 |
|---|---|
| M0 確認感測器 | ✅ 2026-09-16 |
| M1 角度串流 CSV + θ–t 圖 | ✅ 2026-10-04 |
| M2 狀態機 | — |
| M3 覆蓋窗 + 快照 + 3D 投影 | — |
| M4 模糊、變暗、映射曲線 | — |
| M5 選單列 app | — |
| M6 公開 | — |

## 建置

```sh
swift build
.build/debug/lidfold-cli                       # 每 50 ms 印一次角度
.build/debug/lidfold-cli --raw                 # 額外印出兩個 report 的 hex
scripts/record.sh normal_1                     # 錄一次闔蓋 → data/normal_1.csv
.venv/bin/python scripts/split_takes.py data/x.csv   # 一檔多次闔蓋時切開
.venv/bin/python scripts/plot_theta.py data/takes/*.csv
```

需求：macOS 14+、Swift 5.9+、有上蓋角度感測器的 MacBook（已驗證：MacBook Air M4，Mac16,12）。不需要 sudo。
畫圖用 `.venv`（`python3 -m venv .venv && .venv/bin/pip install matplotlib numpy`）。

## 感測器（M0–M1 實測）

- HID 裝置：VID `0x05AC`、PID `0x8104`、UsagePage `0x0020`、Usage `0x008A`，`hidutil list` 可見
- 讀法：`IOHIDDeviceGetReport`，報告類型 feature
  - **report 7**（主要）：32-bit，單位 0.01°，靜止雜訊峰對峰 0.05°
  - **report 1**（備援）：9-bit，單位 1°，參考實作都讀這個
- **更新率只有 10 Hz**（每 100 ms 一跳）。註冊 input report callback 推送速率一樣是 10 Hz，
  所以換讀法救不了；動畫要自己做預測／插值
- **θ_off ≈ 0–6°**：螢幕幾乎到全闔才關，動畫窗口有 110° 以上，比白皮書估的 10–20° 大很多
- 參考實作：`samhenrigold/LidAngleSensor`、`wangfu91/lid-angle-rs`、`tcsenpai/pybooklid`

## 結構

```
Sources/LidFoldCore/     Sensor + Signal + Mapping（純邏輯，不 import AppKit）
Sources/lidfold-cli/     M0–M2 的命令列工具
Sources/LidFoldApp/      M3 起的 app
scripts/                 錄製、切割、畫圖
data/                    M1 的 CSV 與圖（見 data/README.md）
docs/                    白皮書、模擬器
```
