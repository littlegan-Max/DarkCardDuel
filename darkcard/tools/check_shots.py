#!/usr/bin/env python3
# 截图黑屏判定：画面里颜色太少 = 黑屏/空白。
# 用法：python tools/check_shots.py <截图目录>
import os
import sys

try:
    from PIL import Image
except ImportError:
    Image = None

DESC = {
    "mumu_1_main": "启动后（应为主菜单）",
    "mumu_2_battle": "点「单机对战」之后（应为对战界面）",
    "mumu_3_exitconfirm": "对局中点「菜单」（应为退出确认弹窗）",
    "mumu_4_backhome": "点「返回主菜单」之后（应回到主菜单）",
    "mumu_4b_backhome_again": "再来一次 对局→菜单→返回主菜单",
    "mumu_5_restart": "强杀重启（应回到主菜单）",
    "mumu_6_relaunch": "回桌面再进（应回到主菜单）",
}


def colors_of(path: str) -> int:
    if Image is not None:
        img = Image.open(path).convert("RGB")
        img = img.resize((60, 100))
        return len(set(img.getdata()))
    # 没 PIL 时的兜底：数一下字节里有多少不同的 24bit 像素
    import zlib
    import struct
    with open(path, "rb") as f:
        data = f.read()
    return len(set(data[i:i + 3] for i in range(0, len(data), 997)))


def main() -> int:
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    files = sorted(f for f in os.listdir(d) if f.startswith("mumu_") and f.endswith(".png"))
    if not files:
        print("FAIL: 没有截图")
        return 1
    bad = 0
    for f in files:
        key = f[:-4]
        p = os.path.join(d, f)
        try:
            n = colors_of(p)
        except Exception as e:  # noqa: BLE001
            print("FAIL  %-22s 读取失败 %s" % (f, e))
            bad += 1
            continue
        size = os.path.getsize(p)
        desc = DESC.get(key, "")
        if n <= 3:
            print("FAIL  %-22s %-28s 黑屏（%d 种颜色，%.1f KB）" % (f, desc, n, size / 1024))
            bad += 1
        else:
            print("OK    %-22s %-28s %d 种颜色，%.1f KB" % (f, desc, n, size / 1024))
    print()
    print("%d 张截图，%d 张异常" % (len(files), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
