#!/usr/bin/env python3
"""Animated chart GIF built ONLY from results/live/runs.csv (median of ok runs)."""
import csv
import io
import statistics as st
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / "results" / "live" / "runs.csv"
OUT = ROOT / "docs" / "img" / "bench-scaleup.gif"
FPS, SECONDS_TOTAL, GROW_SECONDS = 10, 20, 14
COLORS = {"automode": ("#e8833a", "#f6c9a4"), "karpenter": ("#2f6fb5", "#a9c6e8")}
LABELS = {"automode": "EKS Auto Mode", "karpenter": "Karpenter (tự quản lý)"}
CAPTION = "Dữ liệu đo thật: 1 cluster · us-west-2 · On-Demand · n=3 (trung vị)"


def load():
    med = {}
    with open(RUNS, newline="") as f:
        rows = [r for r in csv.DictReader(f) if r["status"] == "ok"]
    for s in COLORS:
        for n in (5, 15, 30):
            g = [r for r in rows if r["scaler"] == s and int(r["replicas"]) == n]
            med[(s, n)] = (st.median(float(r["t_first_node_ready_s"]) for r in g),
                           st.median(float(r["t_all_pods_ready_s"]) for r in g), len(g))
    return med


def frame(med, t, tmax, final):
    fig, axes = plt.subplots(3, 1, figsize=(10, 5.8), dpi=90, sharex=True)
    for ax, n in zip(axes, (5, 15, 30)):
        for i, s in enumerate(("automode", "karpenter")):
            node, pods, _ = med[(s, n)]
            dark, light = COLORS[s]
            w1 = min(t, node)
            ax.barh(i, w1, color=dark, height=0.6)
            if t > node:
                ax.barh(i, min(t, pods) - node, left=node, color=light, height=0.6)
            if t >= pods:
                ax.text(pods + tmax * 0.01, i, f"{pods:.0f} s", va="center", fontsize=11, fontweight="bold")
        ax.set_yticks([0, 1])
        ax.set_yticklabels([LABELS["automode"], LABELS["karpenter"]], fontsize=9)
        ax.set_ylabel(f"{n} replicas", fontsize=11, fontweight="bold", rotation=90)
        ax.set_xlim(0, tmax)
        ax.invert_yaxis()
        ax.grid(axis="x", alpha=0.3)
    axes[-1].set_xlabel("Giây kể từ lúc scale Deployment (đo từ API server)", fontsize=10)
    handles = [plt.Rectangle((0, 0), 1, 1, color=COLORS[s][k]) for s in COLORS for k in (0, 1)]
    names = [f"{LABELS[s]}: chờ node Ready" if k == 0 else f"{LABELS[s]}: node Ready → Pod Ready"
             for s in COLORS for k in (0, 1)]
    fig.legend(handles, names, loc="upper center", bbox_to_anchor=(0.5, 0.95), ncol=2, fontsize=9, frameon=False)
    fig.suptitle(f"Scale-up đến Pod Ready · t = {t:4.0f} s" if not final else "Scale-up đến Pod Ready · kết quả",
                 y=0.985, fontsize=12, fontweight="bold")
    fig.text(0.5, 0.01, CAPTION, ha="center", fontsize=10, style="italic")
    fig.tight_layout(rect=(0, 0.04, 1, 0.87))
    buf = io.BytesIO()
    fig.savefig(buf, format="png")
    plt.close(fig)
    buf.seek(0)
    return Image.open(buf).convert("RGB")


def main():
    med = load()
    tmax = max(v[1] for v in med.values()) * 1.12
    total, grow = FPS * SECONDS_TOTAL, FPS * GROW_SECONDS
    frames = []
    for i in range(total):
        t = tmax / 1.12 * min(i, grow) / grow
        frames.append(frame(med, t, tmax, i >= grow))
    ref = frames[-1].quantize(colors=64, method=Image.MEDIANCUT)  # one shared palette -> no flicker
    pal = [f.quantize(palette=ref, dither=Image.NONE) for f in frames]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    pal[0].save(OUT, save_all=True, append_images=pal[1:], duration=int(1000 / FPS), loop=0, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size / 1e6:.2f} MB, {len(frames)} frames)")


if __name__ == "__main__":
    main()
