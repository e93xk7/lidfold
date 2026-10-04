#!/usr/bin/env python3
"""M1：把 lidfold-cli 錄的 CSV 畫成 θ–t 圖，並讀出 M1 要的五個數字。

用法：
    .venv/bin/python scripts/plot_theta.py data/*.csv

輸出：data/plots/<名字>.png 與 .pdf（house style，見白皮書 8.2），
並在終端機印出每份紀錄的取樣率、雜訊振幅、θ_open、θ_off、平均角速度。
"""

import sys
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.pyplot as plt

DATA_COLOR = "#C00000"
MARK_COLOR = "#404040"


def apply_house_style():
    """白皮書 8.2：框線 3.0、刻度 3.0、資料線 2.0、粗體字、無格線、300 dpi。"""
    plt.rcParams.update({
        "figure.dpi": 300,
        "savefig.dpi": 300,
        "font.weight": "bold",
        "axes.labelweight": "bold",
        "axes.titleweight": "bold",
        "axes.linewidth": 3.0,
        "axes.grid": False,
        "xtick.major.width": 3.0,
        "ytick.major.width": 3.0,
        "xtick.major.size": 8.0,
        "ytick.major.size": 8.0,
        "xtick.labelsize": 12,
        "ytick.labelsize": 12,
        "axes.labelsize": 14,
        "lines.linewidth": 2.0,
        "savefig.bbox": "tight",
    })


def load(path):
    """讀 CSV。回傳 (t_mono, t_wall, theta, display_asleep)。"""
    rows = np.genfromtxt(path, delimiter=",", names=True)
    if rows.size == 0:
        raise ValueError(f"{path}：沒有資料")
    return (
        np.atleast_1d(rows["t_mono"]),
        np.atleast_1d(rows["t_wall"]),
        np.atleast_1d(rows["theta"]),
        np.atleast_1d(rows["display_asleep"]).astype(int),
    )


def analyse(t, t_wall, theta, asleep):
    """讀出 M1 要的數字。回傳 dict，讀不出來的欄位是 None。"""
    out = {}

    # 取樣率：用 t_mono 的中位間隔。機器睡著時 t_mono 不前進，
    # 所以極端值（睡眠前後的那一步）用中位數自然被擋掉。
    dt = np.diff(t)
    dt = dt[dt > 0]
    out["dt_median"] = float(np.median(dt)) if dt.size else None
    out["hz"] = 1.0 / out["dt_median"] if out["dt_median"] else None
    out["dt_p95"] = float(np.percentile(dt, 95)) if dt.size else None

    # 螢幕變黑那一刻：display_asleep 第一次從 0 翻成 1。
    off_idx = np.flatnonzero((asleep[1:] == 1) & (asleep[:-1] == 0))
    if off_idx.size:
        i = int(off_idx[0]) + 1
        out["t_off"] = float(t[i])
        out["theta_off"] = float(theta[i])
        out["off_index"] = i
    else:
        out["t_off"] = out["theta_off"] = out["off_index"] = None

    # 闔蓋開始：從頭找第一個「已經比起始角度低 2° 以上」的樣本。
    # 之前那段視為靜止，用來量 θ_open 與雜訊。
    theta0 = float(np.median(theta[: max(3, len(theta) // 20)]))
    moving = np.flatnonzero(theta < theta0 - 2.0)
    start = int(moving[0]) if moving.size else None
    out["start_index"] = start

    still = theta[:start] if start and start > 3 else theta[: max(3, len(theta) // 20)]
    out["theta_open"] = float(np.median(still))
    out["noise_pp"] = float(np.ptp(still))          # 峰對峰
    out["noise_sd"] = float(np.std(still))

    # 平均角速度：從開始動到螢幕變黑（沒抓到就用最低點）。
    end = out["off_index"] if out["off_index"] is not None else int(np.argmin(theta))
    if start is not None and end > start:
        dtheta = theta[end] - theta[start]
        dtime = t[end] - t[start]
        out["omega_mean"] = float(dtheta / dtime) if dtime > 0 else None
        out["close_duration"] = float(dtime)
    else:
        out["omega_mean"] = out["close_duration"] = None

    # 瞬時角速度峰值：先做 5 點移動平均壓掉 1° 量化雜訊。
    if len(theta) > 10:
        k = 5
        sm = np.convolve(theta, np.ones(k) / k, mode="valid")
        ts = t[k - 1:]
        d = np.diff(sm) / np.diff(ts)
        d = d[np.isfinite(d)]
        out["omega_peak"] = float(np.min(d)) if d.size else None
    else:
        out["omega_peak"] = None

    # 睡眠：t_wall 走了多久、t_mono 走了多久，差值就是凍住的時間。
    out["sleep_gap"] = float((t_wall[-1] - t_wall[0]) - (t[-1] - t[0]))

    # 量化階：相鄰不同值的最小差，確認是不是真的 1°。
    steps = np.abs(np.diff(theta))
    steps = steps[steps > 0]
    out["quantum"] = float(np.min(steps)) if steps.size else None

    return out


def plot(path, t, theta, asleep, m, outdir):
    fig, ax = plt.subplots(figsize=(7, 4.5))

    # 每段都從 t = 0 開始，方便互相比較。
    t0 = t[0]
    t = t - t0

    ax.plot(t, theta, color=DATA_COLOR, linewidth=2.0, solid_capstyle="round")

    if m["theta_off"] is not None:
        t_off = m["t_off"] - t0
        ax.axhline(m["theta_off"], color=MARK_COLOR, linestyle="--", linewidth=2.0)
        ax.axvline(t_off, color=MARK_COLOR, linestyle=":", linewidth=2.0)
        ax.annotate(
            f"$\\theta_{{off}}$ = {m['theta_off']:.0f}°",
            xy=(t_off, m["theta_off"]),
            xytext=(-96, 14), textcoords="offset points",
            fontweight="bold", fontsize=12, color=MARK_COLOR,
        )
        ax.annotate(
            "螢幕變黑", xy=(t_off, ax.get_ylim()[1]),
            xytext=(-78, -18), textcoords="offset points",
            fontweight="bold", fontsize=11, color=MARK_COLOR,
        )

    ax.set_xlabel("t  [s]")
    ax.set_ylabel("θ  [°]")
    title = Path(path).stem
    if m["close_duration"] and m["omega_mean"]:
        title += f"　{m['close_duration']:.2f} s，平均 {m['omega_mean']:.0f} °/s"
    ax.set_title(title, fontsize=13)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)

    outdir.mkdir(parents=True, exist_ok=True)
    stem = outdir / Path(path).stem
    fig.savefig(stem.with_suffix(".png"))
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)
    return stem


def fmt(v, unit="", nd=2):
    return "—" if v is None else f"{v:.{nd}f}{unit}"


def main(argv):
    paths = [Path(p) for p in argv[1:]]
    if not paths:
        print(__doc__)
        return 1
    apply_house_style()
    # 中文標題要字型，沒有就退回英文檔名標題（不影響數據）。
    for family in ("PingFang TC", "Heiti TC", "Arial Unicode MS"):
        if any(family == f.name for f in matplotlib.font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = family
            break

    outdir = paths[0].parent / "plots"
    rows = []
    for p in paths:
        t, t_wall, theta, asleep = load(p)
        m = analyse(t, t_wall, theta, asleep)
        stem = plot(p, t, theta, asleep, m, outdir)
        rows.append((p.stem, m))
        print(f"\n── {p.stem} ──  {len(t)} 筆 → {stem}.png / .pdf")
        print(f"   取樣率        {fmt(m['hz'], ' Hz', 1)}（中位 dt {fmt(m['dt_median'], ' s', 4)}，p95 {fmt(m['dt_p95'], ' s', 4)}）")
        print(f"   量化階        {fmt(m['quantum'], '°', 2)}")
        print(f"   雜訊（靜止）  峰對峰 {fmt(m['noise_pp'], '°')}，SD {fmt(m['noise_sd'], '°')}")
        print(f"   θ_open        {fmt(m['theta_open'], '°', 1)}")
        print(f"   θ_off         {fmt(m['theta_off'], '°', 1)}")
        print(f"   闔蓋歷時      {fmt(m['close_duration'], ' s')}")
        print(f"   平均角速度    {fmt(m['omega_mean'], ' °/s', 1)}")
        print(f"   峰值角速度    {fmt(m['omega_peak'], ' °/s', 1)}")
        print(f"   睡眠凍結      {fmt(m['sleep_gap'], ' s', 1)}")

    if len(rows) > 1:
        print("\n── 彙總 ──")
        print(f"{'紀錄':<22}{'Hz':>7}{'θ_open':>9}{'θ_off':>8}{'歷時[s]':>9}{'ω̄[°/s]':>10}")
        for name, m in rows:
            print(f"{name:<22}{fmt(m['hz'],'',0):>7}{fmt(m['theta_open'],'',0):>9}"
                  f"{fmt(m['theta_off'],'',0):>8}{fmt(m['close_duration'],'',2):>9}"
                  f"{fmt(m['omega_mean'],'',1):>10}")
        offs = [m["theta_off"] for _, m in rows if m["theta_off"] is not None]
        if offs:
            print(f"\nθ_off：{min(offs):.0f}–{max(offs):.0f}°，中位 {np.median(offs):.0f}°")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
