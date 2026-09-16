# LidFold

把 iPhone Duo 的開合動畫搬到 MacBook：闔上上蓋時，螢幕內容看起來固定在空間裡不動，是機器繞著內容轉。

完整規格見 [docs/白皮書_v1.md](docs/白皮書_v1.md)。自用軟體，不簽章、不上架。

## 進度

| 里程碑 | 狀態 |
|---|---|
| M0 確認感測器 | ✅ 2026-09-16 |
| M1 角度串流 CSV + θ–t 圖 | — |
| M2 狀態機 | — |
| M3 覆蓋窗 + 快照 + 3D 投影 | — |
| M4 模糊、變暗、映射曲線 | — |
| M5 選單列 app | — |
| M6 公開 | — |

## 建置

```sh
swift build
.build/debug/lidfold-cli            # 每 50 ms 印一次角度
.build/debug/lidfold-cli --raw      # 額外印出 feature report hex
```

需求：macOS 14+、Swift 5.9+、有上蓋角度感測器的 MacBook（已驗證：MacBook Air M4，Mac16,12）。不需要 sudo。

## 感測器（M0 實測）

- HID 裝置：VID `0x05AC`、PID `0x8104`、UsagePage `0x0020`、Usage `0x008A`，`hidutil list` 可見
- 讀法：`IOHIDDeviceGetReport` feature report ID 1，8 bytes；bytes[1..2] little-endian UInt16 = 角度
- 單位：**1 raw = 1°**（整數度，解析度 1°）。白皮書 3.1 寫的 0.01° 不對
- 參考實作：`samhenrigold/LidAngleSensor`、`wangfu91/lid-angle-rs`、`tcsenpai/pybooklid`

## 結構

```
Sources/LidFoldCore/     Sensor + Signal + Mapping（純邏輯，不 import AppKit）
Sources/lidfold-cli/     M0–M2 的命令列工具
Sources/LidFoldApp/      M3 起的 app
Tests/LidFoldCoreTests/  狀態機 CSV 回放測試
data/                    M1 的 CSV 與圖
scripts/                 畫圖腳本
docs/                    白皮書、模擬器
```
