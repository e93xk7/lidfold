# M1 資料（2026-09-28 錄）

## 原始檔（錄什麼就是什麼，不修）

| 檔案 | 內容 |
|---|---|
| `close_normal_1.csv` | 1 次闔蓋 |
| `close_normal_2.csv` | **4 次闔蓋黏在同一個檔**（錄的時候忘了分段） |
| `close_normal_3.csv` `close_slow.csv` `close_fast.csv` | 誤錄，只有靜止資料，沒有闔蓋。可拿來量靜止雜訊 |

欄位：`t_mono,t_wall,raw,theta,theta_coarse,display_asleep`
（2026-09-28 這批是舊格式，沒有 `theta_coarse`，`theta` 是 1° 解析度的 report 1。）

## 切出來的單次闔蓋（`takes/`）

`scripts/split_takes.py` 依「螢幕變黑」事件切的，名字依實測速度重取：

| 檔案 | 歷時 | 平均角速度 | θ_open → θ_off |
|---|---|---|---|
| `normal_1.csv` | 1.63 s | −69 °/s | 118° → 2° |
| `normal_2.csv` | 2.67 s | −42 °/s | 117° → 1° |
| `normal_3.csv` | 1.73 s | −63 °/s | 115° → 3° |
| `slow.csv` | 8.57 s | −13 °/s | 117° → 6° |
| `fast.csv` | 0.76 s | −146 °/s | 117° → 0° |

`pause_resume.csv`（2026-10-06 錄，M2 驗證用）是獨立錄的一次，不是切出來的，
而且是**第一份 0.01° 解析度**的資料（靜止雜訊峰對峰 0.06°、SD 0.02°，與 M1 的
report 7 量測一致）。內容：闔到 45° 停住約 2.3 秒，再繼續闔到底。

圖在 `takes/plots/`，用 `scripts/plot_theta.py` 產生（house style，白皮書 8.2）。

## 重錄的話

這批是 1° 解析度。M1 之後 Sensor 層改讀 report 7（0.01°），重錄會得到細 100 倍的資料。
一次錄一個檔，別再黏在一起：

```sh
scripts/record.sh normal_1    # 每次：停兩秒 → 闔蓋 → 打開 → Ctrl-C
```
