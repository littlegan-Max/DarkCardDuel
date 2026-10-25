#!/usr/bin/env python3
"""打包联机服务器：生成一个可以直接发给对方的 zip。

对方只需要：
  1. 解压
  2. cd 进去
  3. python3 server.py --port 8737

zip 里只有 3 个文件（~90 KB），不依赖仓库结构、不需要 pip install。

用法：python tools/pack_server.py
输出：build/darkcard-server.zip
"""

from __future__ import annotations

import json
import os
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)          # .../darkcard
ROOT = os.path.dirname(PROJ)          # .../（仓库根）
OUT = os.path.join(PROJ, "build", "darkcard-server.zip")

# (源文件, zip 内路径)
FILES = [
    (os.path.join(PROJ, "server", "server.py"), "server.py"),
    (os.path.join(PROJ, "train", "engine.py"), "engine.py"),
    (os.path.join(PROJ, "data", "cards.json"), "cards.json"),
    (os.path.join(PROJ, "server", "update.sh"), "update.sh"),
    (os.path.join(PROJ, "server", "requirements.txt"), "requirements.txt"),
]

README = """暗牌技能对战 · 联机服务器
=========================
版本：游戏 {{GAME_VERSION}} / 规则 {{RULES_VERSION}}

这个包里只有 3 个文件，不需要装任何依赖，只要机器上有 Python 3.8+ 就能跑。

运行
----
    python3 server.py --port 8737

（会自动开启自动更新，每 10 分钟查一次新版并热重载。
 不想自动更新就加 --no-auto-update。）

（Windows 上是 python server.py --port 8737）

看到这两行就是起来了：
    [darkcard] 服务器启动 http://0.0.0.0:8737  （卡表 50 张）
    [darkcard] 内网穿透请把公网端口映射到 8737/tcp

验证
----
    curl -s http://127.0.0.1:8737/api/health
    期望输出：{"ok": true, "service": "darkcard-duel"}

外网访问
--------
1. 在这台机器上把 8737/tcp 放行（ufw allow 8737/tcp，或 firewalld，
   云服务器还要在控制台的安全组里放行）
2. 在你已有的内网穿透 / 映射里，把公网端口指向 8737/tcp
3. 游戏里「联机对战」→ 地址填公网地址、端口填公网端口

后台常驻
--------
    nohup python3 server.py --port 8737 > server.log 2>&1 &

以后更新了怎么办
----------------
不用再找我们发文件。服务器默认开着自动更新：
每 10 分钟查一次 GitHub Releases，有新版就自动下载并生效。

服务器按改动内容分三层处理：
  规则层（engine.py / cards.json）→ 热重载，不重启进程，不打断任何对局。
                                    正在打的那一局按旧规则打完，新开的局用新规则。
  进程层（server.py / 新增模块）   → 等没人打牌时重启进程（PID 不变，systemd 无感）。
  依赖层（requirements.txt）       → 自动 pip install。

想手动触发：

    bash update.sh          # 更新到最新版
    bash update.sh --check  # 只看有没有新版

服务器连不上 GitHub 时，用 --url <直链> 指定下载地址，
或设环境变量 DARKCARD_UPDATE_URL 指向自己的镜像。

注意：游戏客户端（APK/EXE）不在自动更新范围内，需要我们重新发一份。

数据
----
store.json 存玩家昵称和好友关系（不含对局）。
删掉就重置所有玩家和好友。对局只在内存，服务器重启即失效。
update.sh 更新时会自动保留它。
"""


def _versions() -> tuple[str, str]:
    """读出打包内容的版本：游戏版本（project.godot）与规则版本（cards.json）。"""
    game_ver = "?"
    rules_ver = "?"
    proj = os.path.join(PROJ, "project.godot")
    if os.path.exists(proj):
        with open(proj, "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("config/version="):
                    game_ver = line.split("=", 1)[1].strip().strip('"')
                    break
    cards = os.path.join(PROJ, "data", "cards.json")
    if os.path.exists(cards):
        with open(cards, "r", encoding="utf-8") as f:
            try:
                rules_ver = str(json.load(f).get("rules_version", "?"))
            except ValueError:
                pass
    return game_ver, rules_ver


def main() -> int:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    missing = [src for src, _ in FILES if not os.path.exists(src)]
    if missing:
        print("缺少文件：")
        for m in missing:
            print("  " + m)
        return 1

    game_ver, rules_ver = _versions()

    # 两个文件名：
    #   darkcard-server-v0.3.0.zip —— 带版本号，给人看的
    #   darkcard-server.zip        —— 固定名，给 update.sh 用
    #                                 （配合 releases/latest/download/ 永远指向最新版）
    readme = README.replace("{{GAME_VERSION}}", game_ver).replace("{{RULES_VERSION}}", rules_ver)
    ver_txt = "游戏版本 %s\n规则版本 %s\n打包时间 %s\n" % (
        game_ver, rules_ver, time.strftime("%Y-%m-%d %H:%M:%S"))

    def build(path: str) -> None:
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            for src, name in FILES:
                z.write(src, name)
            z.writestr("使用说明.txt", readme)
            z.writestr("版本.txt", ver_txt)

    out_path = os.path.join(os.path.dirname(OUT), "darkcard-server-v%s.zip" % game_ver)
    fixed_path = os.path.join(os.path.dirname(OUT), "darkcard-server.zip")
    build(out_path)
    build(fixed_path)

    size = os.path.getsize(out_path)
    print("已打包：%s  (%.1f KB)" % (out_path, size / 1024))
    print("固定名：%s  （给 update.sh 用）" % fixed_path)
    print("版本：游戏 %s / 规则 %s" % (game_ver, rules_ver))
    print("包含：")
    for src, name in FILES:
        print("  %-14s <- %s" % (name, os.path.relpath(src, ROOT)))
    print("  %-14s <- 内嵌说明" % "使用说明.txt")
    print("  %-14s <- 版本信息" % "版本.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
