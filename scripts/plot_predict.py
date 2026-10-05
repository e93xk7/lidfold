#!/usr/bin/env python3
"""M2：比較 10 Hz 感測器階梯與插值後的 60 fps 曲線。

用法：
    .build/debug/lidfold-replay --predict data/predict data/takes/fast.csv
    .venv/bin/python scripts/plot_predict.py data/predict/*.csv
"""

import sys
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from plot_theta import apply_house_style  # noqa: E402

SENSOR_COLOR = "#808080"
PRED_COLOR = "#C00000"
TRUTH_COLOR = "#1F4E79"


def main(argv):
    paths = [Path(p) for p in argv[1:]]
    if not paths:
        print(__doc__)
        return 1
    apply_house_style()
    for family in ("PingFang TC", "Heiti TC", "Arial Unicode MS"):
        if any(family == f.name for f in matplotlib.font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = family
            break

    for p in paths:
        r = np.genfromtxt(p, delimiter=",", names=True)
        t, sensor, pred = r["t"], r["theta_sensor"], r["theta_pred"]

        # 真值的最佳估計：感測器「值變了」那些時刻是已知的真實角度，
        # 中間用線性內插補。這是非因果的（看得到未來），即時時做不到，
        # 但拿來當尺很合適 —— 比用延遲的階梯當尺公平。
        changes = np.flatnonzero(np.diff(sensor) != 0) + 1
        knots_t = np.concatenate(([t[0]], t[changes], [t[-1]]))
        knots_y = np.concatenate(([sensor[0]], sensor[changes], [sensor[-1]]))
        truth = np.interp(t, knots_t, knots_y)

        fig, ax = plt.subplots(figsize=(7, 4.5))
        ax.plot(t, sensor, color=SENSOR_COLOR, linewidth=2.0, label="感測器 10 Hz")
        ax.plot(t, truth, color=TRUTH_COLOR, linewidth=2.0, linestyle="--", label="真值估計")
        ax.plot(t, pred, color=PRED_COLOR, linewidth=2.0, label="插值後 60 fps")
        ax.set_xlabel("t  [s]")
        ax.set_ylabel("θ  [°]")

        # 只看動作中的誤差：插值輸出與真值估計差幾度。
        moving = np.abs(np.gradient(truth, t)) > 3
        err = np.abs(pred - truth)[moving]
        title = p.stem
        if err.size:
            title += f"　誤差 中位 {np.median(err):.1f}°／最大 {err.max():.1f}°"
        ax.set_title(title, fontsize=13)
        ax.legend(frameon=False, prop={"weight": "bold", "size": 11})
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)

        outdir = p.parent / "plots"
        outdir.mkdir(parents=True, exist_ok=True)
        stem = outdir / p.stem
        fig.savefig(stem.with_suffix(".png"))
        fig.savefig(stem.with_suffix(".pdf"))
        plt.close(fig)

        # 階梯度：相鄰兩幀之間角度變化的最大值，越小代表越平順。
        step_sensor = np.max(np.abs(np.diff(sensor))) if len(sensor) > 1 else 0
        step_pred = np.max(np.abs(np.diff(pred))) if len(pred) > 1 else 0
        print(f"── {p.stem} → {stem}.png")
        print(f"   單幀最大跳動：感測器 {step_sensor:.1f}°　→　插值後 {step_pred:.2f}°")
        if err.size:
            print(f"   動作中誤差：中位 {np.median(err):.2f}°，最大 {err.max():.2f}°")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
