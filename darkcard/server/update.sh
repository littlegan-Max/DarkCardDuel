#!/usr/bin/env bash
# 暗牌技能对战 · 服务器更新脚本
#
# 从 GitHub Releases 下载最新服务器包并应用。
# 公开仓库不需要任何凭据，服务器能自己拉。
#
# 用法：
#   bash update.sh              # 更新到最新版并重启（完整生效，新代码真的在跑）
#   bash update.sh --reload     # 更新但不重启：只热重载规则，正在打的局不受影响
#   bash update.sh --check      # 只检查状态，不下载不重启
#   bash update.sh --url <地址>  # 从指定地址下载（服务器连不上 GitHub 时用）
#
# 放在 server.py 同目录下。

set -uo pipefail

REPO="littlegan-Max/DarkCardDuel"
ASSET="darkcard-server.zip"
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${DC_PORT:-8737}"
API="${DARKCARD_UPDATE_API:-https://api.github.com/repos/${REPO}/releases/latest}"
DL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

MODE="update"
URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE="check" ;;
        --reload) MODE="reload" ;;
        --url)    MODE="update"; URL="$2"; shift ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

cd "$DIR"

# ---------- 版本 ----------
cur_rules() {
    python3 - <<'PY' 2>/dev/null || echo "?"
import json
try:
    with open("cards.json", "r", encoding="utf-8") as f:
        print(json.load(f).get("rules_version", "?"))
except Exception:
    print("?")
PY
}
cur_game() {
    python3 - <<'PY' 2>/dev/null || echo "?"
import re
try:
    with open("版本.txt", "r", encoding="utf-8") as f:
        m = re.search(r"游戏版本 (\S+)", f.read())
        print(m.group(1) if m else "?")
except OSError:
    print("?")
PY
}
# 正在跑的进程是哪个版本（v0.3.1 的服务器会报，老版本报不出来）
running_game() {
    curl -fsSL --max-time 5 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("game_version",""))
except Exception:
    print("")' 2>/dev/null
}

CUR_GAME="$(cur_game)"
CUR_RULES="$(cur_rules)"
RUN_GAME="$(running_game)"

echo "磁盘上的版本：游戏 $CUR_GAME / 规则 $CUR_RULES"
if [ -n "$RUN_GAME" ]; then
    echo "正在运行的版本：$RUN_GAME"
    if [ "$RUN_GAME" != "$CUR_GAME" ]; then
        echo "→ 磁盘上的代码比正在跑的进程新，需要重启才能让新代码生效。"
    fi
else
    echo "正在运行的版本：（查不到，可能是旧版服务器或没在跑）"
fi

# ---------- 远端版本 ----------
SAME=0
if [ -n "$URL" ]; then
    echo "使用指定下载地址：$URL"
    NEW_TAG="(指定地址)"
else
    NEW_TAG="$(curl -fsSL --max-time 20 "$API" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tag_name",""))
except Exception:
    print("")' 2>/dev/null)"
    if [ -z "$NEW_TAG" ]; then
        echo "拿不到 GitHub 上的最新版本信息。" >&2
        echo "如果服务器连不上 GitHub，用 --url <直链> 指定下载地址。" >&2
        exit 1
    fi
    echo "远端最新：$NEW_TAG"
    if [ "$NEW_TAG" = "v${CUR_GAME}" ]; then
        SAME=1
        echo "文件已是最新。"
    fi
fi

if [ "$MODE" = "check" ]; then
    if [ "$SAME" = "1" ]; then
        echo "文件已是最新。"
        if [ -n "$RUN_GAME" ] && [ "$RUN_GAME" != "$CUR_GAME" ]; then
            echo "但进程还跑着旧版本 → 跑一次 bash update.sh 就能让新代码生效。"
        fi
    else
        echo "有新版可用：$NEW_TAG（当前 $CUR_GAME）"
    fi
    exit 0
fi

# ---------- 下载并覆盖（只在有新版时） ----------
if [ "$SAME" != "1" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    ZIP="$TMP/server.zip"
    if [ -n "$URL" ]; then
        SRC="$URL"
    else
        SRC="$DL"
    fi
    echo "下载：$SRC"
    if ! curl -fsSL --max-time 120 "$SRC" -o "$ZIP"; then
        echo "下载失败。" >&2
        exit 1
    fi

    # store.json 是玩家和好友数据，解压前备份、解压后还原
    BACKUP="$TMP/store.json"
    HAD_STORE=0
    if [ -f store.json ]; then
        cp store.json "$BACKUP"
        HAD_STORE=1
    fi

    echo "解压覆盖…"
    if ! unzip -o "$ZIP" -d "$DIR"; then
        echo "解压失败（服务器上可能没装 unzip，用 apt install unzip 或 yum install unzip 装一下）" >&2
        exit 1
    fi
    if [ "$HAD_STORE" = "1" ] && [ ! -f store.json ]; then
        cp "$BACKUP" store.json
    fi
    if [ "$HAD_STORE" = "1" ]; then
        echo "已保留玩家与好友数据（store.json）"
    fi

    # ---------- 依赖 ----------
    # 服务器本来只用标准库，requirements.txt 通常是空的。
    # 以后真引了第三方库，这里会先装上，避免「代码更新了但 import 失败」。
    if [ -f requirements.txt ] && grep -qvE '^\s*(#|$)' requirements.txt 2>/dev/null; then
        echo "安装依赖…"
        python3 -m pip install -r requirements.txt || \
            echo "依赖安装失败，可能服务器没有 pip 或没有外网（不影响已装好的旧版本继续跑）"
    fi

    NEW_GAME="$(cur_game)"
    NEW_RULES="$(cur_rules)"
    echo "更新完成：游戏 $CUR_GAME → $NEW_GAME / 规则 $CUR_RULES → $NEW_RULES"
else
    echo "文件已是最新，但进程可能还跑着旧代码 → 继续执行重启。"
fi

# ---------- 应用 ----------
# 停掉旧进程。按可靠度依次尝试：
#   1) server.pid（v0.3.1 起的服务器会写，最精确）
#   2) fuser / lsof 按端口找（老版本没有 pid 文件时的办法）
#   3) pgrep 按进程名找
stop_old() {
    if [ -f server.pid ]; then
        OLD_PID="$(cat server.pid 2>/dev/null || true)"
        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            kill "$OLD_PID" 2>/dev/null
            sleep 1
            kill -9 "$OLD_PID" 2>/dev/null || true
            echo "已停掉旧进程（PID $OLD_PID）"
            return 0
        fi
    fi
    # 老版本服务器没有 server.pid，按端口找
    if command -v fuser >/dev/null 2>&1; then
        if fuser -k "${PORT}/tcp" >/dev/null 2>&1; then
            sleep 1
            echo "已按端口停掉旧进程"
            return 0
        fi
    fi
    if command -v lsof >/dev/null 2>&1; then
        PIDS="$(lsof -ti:"${PORT}" 2>/dev/null || true)"
        if [ -n "$PIDS" ]; then
            echo "$PIDS" | xargs kill 2>/dev/null
            sleep 1
            echo "已按端口停掉旧进程"
            return 0
        fi
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -f "server.py" >/dev/null 2>&1; then
        pkill -f "server.py"
        sleep 1
        echo "已停掉旧进程"
        return 0
    fi
    return 1
}

restart_server() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q darkcard.service; then
        systemctl restart darkcard
        echo "已 systemctl restart darkcard"
        return
    fi
    stop_old || echo "没找到旧的进程（可能本来就没在跑）"
    nohup python3 server.py --port "$PORT" > server.log 2>&1 &
    echo "已启动新进程，日志在 server.log"
}

if [ "$MODE" = "reload" ]; then
    echo "热重载（不重启）…"
    if curl -fsSL --max-time 15 -X POST "http://127.0.0.1:${PORT}/api/reload" >/dev/null 2>&1; then
        echo "热重载完成，服务器已应用新规则（没重启，正在打的局不受影响）。"
        echo "提示：服务器自身的代码（server.py）要等下次重启才换成新的。"
    else
        echo "热重载没成功，退回重启方式…" >&2
        restart_server
    fi
else
    echo "重启服务器（新代码才会真的跑起来）…"
    restart_server
fi

sleep 2
if curl -fsSL --max-time 10 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo "健康检查通过，服务器已就绪。"
    NOW_GAME="$(running_game)"
    [ -n "$NOW_GAME" ] && echo "现在运行的版本：$NOW_GAME"
else
    echo "健康检查没通过，请看日志：tail -20 server.log" >&2
fi
