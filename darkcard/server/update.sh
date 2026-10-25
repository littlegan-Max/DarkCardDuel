#!/usr/bin/env bash
# 暗牌技能对战 · 服务器自动更新
#
# 从 GitHub Releases 下载最新服务器包并重启。
# 公开仓库不需要任何凭据，服务器能自己拉。
#
# 用法：
#   bash update.sh              # 更新到最新版并重启
#   bash update.sh --check      # 只检查有没有新版，不下载
#   bash update.sh --url <地址>  # 从指定地址下载（服务器连不上 GitHub 时用）
#
# 放在 server.py 同目录下。

set -uo pipefail

REPO="littlegan-Max/DarkCardDuel"
ASSET="darkcard-server.zip"
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${DC_PORT:-8737}"
API="https://api.github.com/repos/${REPO}/releases/latest"
DL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

MODE="update"
URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --url)   MODE="update"; URL="$2"; shift ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

cd "$DIR"

# ---------- 当前版本 ----------
cur_rules() {
    python3 - <<'PY' 2>/dev/null || echo "?"
import json
with open("cards.json", "r", encoding="utf-8") as f:
    print(json.load(f).get("rules_version", "?"))
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
CUR_GAME="$(cur_game)"
CUR_RULES="$(cur_rules)"

echo "当前版本：游戏 $CUR_GAME / 规则 $CUR_RULES"

# ---------- 远端版本 ----------
if [ -n "$URL" ]; then
    echo "使用指定下载地址：$URL"
    NEW_TAG="(指定地址)"
else
    NEW_TAG="$(curl -fsSL --max-time 20 "$API" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
    if [ -z "$NEW_TAG" ]; then
        echo "拿不到 GitHub 上的最新版本信息。" >&2
        echo "如果服务器连不上 GitHub，用 --url <直链> 指定下载地址。" >&2
        exit 1
    fi
    echo "远端最新：$NEW_TAG"
    if [ "$NEW_TAG" = "v${CUR_GAME}" ]; then
        echo "已经是最新，不需要更新。"
        exit 0
    fi
fi

if [ "$MODE" = "check" ]; then
    echo "有新版可用：$NEW_TAG（当前 $CUR_GAME）"
    exit 0
fi

# ---------- 下载 ----------
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

# ---------- 备份并覆盖 ----------
# store.json 是玩家和好友数据，解压前先备份，解压后还原
BACKUP="$TMP/store.json"
HAD_STORE=0
if [ -f store.json ]; then
    cp store.json "$BACKUP"
    HAD_STORE=1
fi

echo "解压覆盖…"
unzip -o "$ZIP" -d "$DIR" || {
    echo "解压失败（服务器上可能没装 unzip，用 apt install unzip 或 yum install unzip 装一下）" >&2
    exit 1
}

if [ "$HAD_STORE" = "1" ]; then
    # 解压包里没有 store.json，但为了保险还是还原回去
    if [ ! -f store.json ]; then
        cp "$BACKUP" store.json
    fi
    echo "已保留玩家与好友数据（store.json）"
fi

NEW_GAME="$(cur_game)"
NEW_RULES="$(cur_rules)"
echo "更新完成：游戏 $CUR_GAME → $NEW_GAME / 规则 $CUR_RULES → $NEW_RULES"

# ---------- 依赖 ----------
# 服务器本来只用标准库，requirements.txt 通常是空的。
# 以后真引了第三方库，这里会先装上，避免「代码更新了但 import 失败」。
if [ -f requirements.txt ] && grep -qvE '^\s*(#|$)' requirements.txt 2>/dev/null; then
    echo "安装依赖…"
    python3 -m pip install -r requirements.txt || \
        echo "依赖安装失败，可能服务器没有 pip 或没有外网（不影响已装好的旧版本继续跑）"
fi

# ---------- 热重载（不重启） ----------
# 服务器支持热重载：新规则对正在进行的对局不生效（那局按旧规则打完），
# 新开的局才用新规则。所以不需要重启，不会打断任何对局。
echo "热重载（不重启）…"
if curl -fsSL --max-time 15 -X POST "http://127.0.0.1:${PORT}/api/reload" >/dev/null 2>&1; then
    echo "热重载完成，服务器已应用新规则（没重启，正在打的局不受影响）。"
else
    echo "热重载没成功，退回重启方式…" >&2
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q darkcard.service; then
        systemctl restart darkcard
        echo "已 systemctl restart darkcard"
    elif pgrep -f "server.py" >/dev/null 2>&1; then
        pkill -f "server.py"
        sleep 1
        nohup python3 server.py --port "$PORT" > server.log 2>&1 &
        echo "已重启（nohup 方式），日志在 server.log"
    else
        nohup python3 server.py --port "$PORT" > server.log 2>&1 &
        echo "已启动（nohup 方式），日志在 server.log"
    fi
fi

sleep 2
if curl -fsSL --max-time 10 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo "健康检查通过，服务器已就绪。"
else
    echo "健康检查没通过，请看日志：tail -20 server.log" >&2
fi
