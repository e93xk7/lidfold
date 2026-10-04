#!/usr/bin/env python3
"""把一份錄了多次闔蓋的 CSV 切成一次一個檔。

用法：
    .venv/bin/python scripts/split_takes.py data/close_normal_2.csv

每個「螢幕變黑」事件（display_asleep 0→1）算一次闔蓋。切出來的範圍是
「開始動之前 1 秒」到「螢幕變黑後 0.3 秒」，寫到 data/takes/<名字>_takeN.csv。
原始檔不動。
"""

import sys
from pathlib import Path

import numpy as np

LEAD_IN = 1.0      # 動作前保留多久（秒），用來量靜止雜訊
TRAIL = 0.3        # 螢幕變黑後再留多久（秒）
LOOKBACK = 10.0    # 往回找「開始動」最多找多久（秒）
MOVE_THRESHOLD = 2.0   # 比該次最高角度低這麼多，就算開始動了（度）


def split(path):
    raw = np.genfromtxt(path, delimiter=",", names=True)
    t = np.atleast_1d(raw["t_mono"])
    theta = np.atleast_1d(raw["theta"])
    asleep = np.atleast_1d(raw["display_asleep"]).astype(int)
    lines = Path(path).read_text().splitlines()
    header, body = lines[0], lines[1:]

    events = np.flatnonzero((asleep[1:] == 1) & (asleep[:-1] == 0)) + 1
    if events.size == 0:
        return []

    outdir = Path(path).parent / "takes"
    outdir.mkdir(parents=True, exist_ok=True)
    stem = Path(path).stem
    written, prev_end = [], 0

    for n, i in enumerate(events, 1):
        i = int(i)
        # 這次闔蓋的起始角度：往回 LOOKBACK 秒內的最高角度。
        back = np.flatnonzero(t >= t[i] - LOOKBACK)
        w0 = max(int(back[0]) if back.size else 0, prev_end)
        th_max = float(theta[w0:i].max()) if i > w0 else float(theta[i])

        # 開始動 = 最後一個還停在起始角度附近的樣本。
        near = np.flatnonzero(theta[w0:i] >= th_max - MOVE_THRESHOLD)
        j = w0 + int(near[-1]) if near.size else w0

        start = int(np.searchsorted(t, t[j] - LEAD_IN))
        start = max(start, prev_end)
        end = int(np.searchsorted(t, t[i] + TRAIL))
        end = min(end, len(t))
        prev_end = end

        out = outdir / f"{stem}_take{n}.csv"
        out.write_text("\n".join([header] + body[start:end]) + "\n")
        dur = t[i] - t[j]
        omega = (theta[i] - theta[j]) / dur if dur > 0 else float("nan")
        written.append((out, th_max, float(theta[i]), dur, omega, end - start))
        print(f"  take{n}: θ {th_max:.0f}° → {theta[i]:.0f}°，"
              f"歷時 {dur:.2f} s，平均 {omega:.0f} °/s，{end - start} 筆 → {out}")
    return written


def main(argv):
    paths = argv[1:]
    if not paths:
        print(__doc__)
        return 1
    for p in paths:
        print(f"── {p}")
        if not split(p):
            print("  沒有闔蓋事件（整段螢幕都沒關過），跳過")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
