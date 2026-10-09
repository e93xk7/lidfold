# LidFold

闔上 MacBook 上蓋時，畫面會從兩側漸漸糊掉、往中線收；打開時反過來解開。
模糊的進度**直接綁在上蓋的實際角度上**——你停手它就停，你往回開它就倒回去。

<!-- 影片：把錄好的檔案拖進 GitHub 的 README 編輯器，GitHub 會上傳並產生一行 URL，
     用那一行取代下面這段。細節見本檔最後的「換掉這段影片」。 -->

> **▶︎ 影片待補**

Closing a MacBook lid, with the screen content blurring outward from both sides —
driven in real time by the actual hinge angle, not a canned animation.
macOS only, and only on MacBooks that have the lid-angle sensor (2019 16" MBP and later).

---

## 這能跑在哪

- **macOS 14 以上**
- **有上蓋角度感測器的 MacBook**。2019 年 16 吋 MacBook Pro 之後的機型才有。
  確認方法：`hidutil list | grep -i 8104`，有東西就有。
  （已驗證：MacBook Air M4 / Mac16,12 / macOS 27.0.1）
- 不能跑在 Windows 或 Linux 筆電上：一般筆電只有磁簧開關（開／關兩種狀態），讀不到角度。

這是自用軟體，**不簽章發行、不上架**。要用就自己 build。

## 裝起來

```sh
git clone <this repo>
cd lidfold

scripts/make_cert.sh      # 建一張本機自簽憑證（只要跑一次，會問登入密碼）
scripts/build_app.sh      # 打包 build/LidFold.app
open build/LidFold.app
```

第一次開會要**螢幕錄製**權限（動畫需要拍下當前畫面）。給完權限要重開一次 app。
之後它會待在選單列，闔蓋時自動作動。

`make_cert.sh` 不是多餘的：macOS 的 TCC 權限綁在程式簽章上，ad-hoc 簽章每次 build 都會變，
權限就會掉。用一張固定的自簽憑證就能一直留著。

## 怎麼運作

```
HID 感測器 10 Hz  →  平滑 + 角速度  →  狀態機  →  θ → p ∈ [0,1]  →  覆蓋窗
                                      闔上中/打開中/已關              快照 + 漸層遮罩
```

- **Sensor**：`IOHIDDeviceRegisterInputReportCallback` 收感測器主動推送，不輪詢。
- **Signal**：一階低通 + 兩點差分算角速度，外加假跳值防護。
- **Mapping**：`p = (θ_open − θ) / (θ_open − θ_off)`，θ_open 是這次闔蓋開始前的靜止角度。
- **Render**：一個蓋滿螢幕的無邊框窗，裡面疊三層同一張快照（清晰、模糊 10px、模糊 28px），
  每層一個 `CAGradientLayer` 遮罩，前緣錯開。p 推著遮罩走，就得到連續的清晰→半糊→全糊。

## 做這個東西學到的事

都是實測出來的，寫在這裡給下一個想碰這顆感測器的人。

**感測器只有 10 Hz。** 每 100 ms 更新一次。輪詢 130 Hz 也一樣，
註冊 input report callback 的推送速率也一樣 —— 是硬體的限制。
正常闔蓋只有 1.6 秒，所以整段動畫的輸入只有 16 個取樣點，
快闔（0.76 秒）更只有 8 個，每次跳 16–19°。要畫 60 fps 一定得自己插值。

**插值要用外推，不能用阻尼追蹤。** 一開始寫成「輸出追著目標跑」，平順但動作中落後 8.5°——
臨界阻尼追蹤器對斜坡輸入本來就有 2τ 的穩態誤差。改成
「等速外推 + 只對誤差做指數衰減」後，誤差中位降到 0.24–2.5°。

**角度有兩個 report。** 參考實作都讀 report 1（9-bit，1° 解析度）。
但 HID report descriptor 裡還有一個 **report 7**：32-bit、logical max 36000、
unit exponent 10⁻²，也就是同一個角度但 **0.01° 解析度**（靜止雜訊峰對峰只有 0.05°）。
兩者由同一顆感測器驅動，更新率相同。

**螢幕關得比想像中晚。** 磁簧開關的觸發角度實測是 **0–6°**（中位 2°），
不是常見說法的 10–20°。所以動畫窗口有 110° 以上，比預期大很多。

**開蓋時螢幕是亮的。** 原本以為開蓋時螢幕還在睡、沒人看得到，所以不值得做。
實測：偵測到開蓋後 **45 ms** 螢幕就亮了，當時上蓋才 9.4° —— 整段開蓋動畫都看得到。
但**開蓋當下不能重拍快照**，那一刻拍回來是全黑的；要沿用闔蓋時拍的那張。

**把內容「釘在空間裡」在單片平面螢幕上行不通。** 最初的做法是把畫面做透視投影，
讓內容看起來固定在空中、機器繞著它轉。幾何完全正確（自檢偏移 0.00000 cm），
但螢幕越闔，它能看到那塊虛擬平面的角度範圍就越小，畫面必然越放越大 ——
闔 70° 時放大近 3 倍，看起來不像「內容沒動」，像「螢幕被拉長」。
那條路還留在 `--mode projection` 裡可以對照。

**閒置耗電全看有沒有在輪詢。** 用 120 Hz 輪詢去追一個 10 Hz 的感測器，
閒置就吃掉 1.0% CPU。改成推送、而且只在粗值真的變了才去讀細值（靜止時零 IPC），
降到 **0.2%**。

## 選項

```sh
build/LidFold.app/Contents/MacOS/LidFold --demo        # 不碰上蓋，自己掃一遍（開發用）
                                         --debug       # 覆蓋窗上顯示 θ / p
                                         --from sides|hinge|top   # 模糊從哪裡開始掃
                                         --mode gradient|projection
```

可調參數全部集中在 [`Sources/LidFoldCore/Tuning.swift`](Sources/LidFoldCore/Tuning.swift)，
每個值都註明了是哪個實測數據定的。

## 開發

```sh
swift build
.build/debug/lidfold-cli                      # 即時印 θ / ω / 狀態 / p
scripts/record.sh my_take                     # 錄一次闔蓋成 CSV
.build/debug/lidfold-replay data/takes/*.csv  # 把錄下的闔蓋回放進狀態機檢查
.build/debug/lidfold-replay --sweep           # 遮罩數學自檢
.build/debug/lidfold-replay --geometry        # 透視投影幾何自檢
```

`data/takes/` 裡是實際錄下的闔蓋（慢、快、正常、闔到一半停住再繼續），
`lidfold-replay` 拿它們當回歸測試 —— 改完狀態機跑一次就知道有沒有弄壞。

畫圖的腳本需要 `python3 -m venv .venv && .venv/bin/pip install matplotlib numpy`。

**改完要重新打包時，先把跑著的 app 殺掉**（`build_app.sh` 會自動做）。
在行程跑著的時候覆蓋 `.app` 的內容，macOS 會判定「程式碼身分已變」，
當場撤銷螢幕錄製權限（`SCStreamError -3801`）。

## 已知的限制

- 覆蓋窗在一般桌面成立；全螢幕 app 或其他 Space 的情況沒有完整測過。
- 闔到一半停住超過 2.5 秒，動畫會收掉；再闔會重新拍一張快照。
- 動作開始的前 100 ms 偵測不到，這是 10 Hz 感測器的硬限制。快闔時約是 13% 的動畫。

## 參考

這顆感測器怎麼讀，是從這幾個專案學的：

- [`samhenrigold/LidAngleSensor`](https://github.com/samhenrigold/LidAngleSensor)（Swift/ObjC）
- [`wangfu91/lid-angle-rs`](https://github.com/wangfu91/lid-angle-rs)（Rust，VID/PID/Usage 寫得最清楚）
- [`tcsenpai/pybooklid`](https://github.com/tcsenpai/pybooklid)（Python，最短的實作）

動畫的靈感來自 iPhone Duo 的開合動畫。

---

<details>
<summary>換掉上面那段影片</summary>

GitHub 的 README 不能用 markdown 語法嵌入 repo 裡的 mp4。做法是：

1. 用手機拍一段闔蓋／開蓋（橫幅、看得到螢幕內容的角度）。
2. 到 GitHub 上這個 repo 的 README 按編輯，把影片檔**直接拖進編輯區**。
   GitHub 會上傳並自動插入一行 `https://github.com/user-attachments/assets/...`。
3. 用那一行取代「▶︎ 影片待補」那段。

或者轉成 GIF 放進 `docs/`，再用 `![](docs/demo.gif)` 引用。
</details>
