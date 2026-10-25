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

import os
import sys
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
]

README = """暗牌技能对战 · 联机服务器
=========================

这个包里只有 3 个文件，不需要装任何依赖，只要机器上有 Python 3.8+ 就能跑。

运行
----
    python3 server.py --port 8737

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

数据
----
store.json 存玩家昵称和好友关系（不含对局）。
删掉就重置所有玩家和好友。对局只在内存，服务器重启即失效。
"""


def main() -> int:
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    missing = [src for src, _ in FILES if not os.path.exists(src)]
    if missing:
        print("缺少文件：")
        for m in missing:
            print("  " + m)
        return 1

    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for src, name in FILES:
            z.write(src, name)
        z.writestr("使用说明.txt", README)

    size = os.path.getsize(OUT)
    print("已打包：%s  (%.1f KB)" % (OUT, size / 1024))
    print("包含：")
    for src, name in FILES:
        print("  %-14s <- %s" % (name, os.path.relpath(src, ROOT)))
    print("  %-14s <- 内嵌说明" % "使用说明.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
