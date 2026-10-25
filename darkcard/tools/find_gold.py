#!/usr/bin/env python3
# 在截图里找「金色主按钮」的中心坐标（Godot 的 GOLD 色）。
#
# 用途：MuMu 自测脚本点「返回主菜单」之前，先算出这个按钮到底在哪，
# 免得手算坐标（不同分辨率/缩放下会偏）。
#
# 用法：python tools/find_gold.py <png> [ymin] [ymax]
# 输出： "<x> <y>"  （找不到则输出空）
import sys

from PIL import Image

GOLD = (0.91, 0.75, 0.48)  # UiPalette.GOLD 的近似值


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: python tools/find_gold.py <png> [ymin] [ymax]")
        return 2
    path = sys.argv[1]
    ymin = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    ymax = int(sys.argv[3]) if len(sys.argv) > 3 else 10 ** 9

    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()

    xs, ys = [], []
    for y in range(max(0, ymin), min(h, ymax)):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            if r > 200 and 150 < g < 215 and b < 140:
                xs.append(x)
                ys.append(y)

    if len(xs) < 200:
        print("")
        return 1

    # 取像素最密集的那一块（按钮），避免抓到别处的金色小字
    xs.sort()
    ys.sort()
    cx = int(xs[len(xs) // 2])
    # 只统计 cx 附近 ±120px 的点，得到按钮中心
    near = [(x, y) for x, y in zip(xs, ys) if abs(x - cx) <= 120]
    if len(near) < 50:
        print("")
        return 1
    ax = sum(p[0] for p in near) // len(near)
    ay = sum(p[1] for p in near) // len(near)
    print("%d %d" % (ax, ay))
    return 0


if __name__ == "__main__":
    sys.exit(main())
