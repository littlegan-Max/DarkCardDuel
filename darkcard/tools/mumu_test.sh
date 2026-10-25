#!/usr/bin/env bash
# MuMu 模拟器真机自测：一条命令跑完
#   启动模拟器 -> 等 adb -> 装 APK -> 拉起 App -> 按序点击 -> 逐屏截图 -> 自动判黑屏
#
# 用法：bash tools/mumu_test.sh
# 注意：模拟器进程随 shell 一起活着，所以整条流程必须在同一个 shell 里跑完。

set -u
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
MUMU="/d/MuMu/nx_main"
ADB_BIN="/c/Users/ghy/AppData/Local/Android/Sdk/platform-tools/adb.exe"
OUT="C:/Users/ghy/WorkBuddy/2026-10-25-10-37-36/shots"
APK="$PROJ/build/DarkCardDuel.apk"
PKG="com.darkcard.duel"
SER="127.0.0.1:16384"

mkdir -p "$OUT"

# 所有 adb 调用都锁定到这台模拟器（adb 里常留着 emulator-5554 之类的僵尸设备）
adb() { "$ADB_BIN" -s "$SER" "$@"; }

step() { echo; echo "-- $*"; }

step "启动 MuMu 实例 0"
"$MUMU/MuMuManager.exe" control --vmindex 0 launch 2>&1 | head -3

step "等 adb 端口"
"$ADB_BIN" kill-server >/dev/null 2>&1
"$ADB_BIN" start-server >/dev/null 2>&1
READY=0
for i in $(seq 1 30); do
  sleep 5
  if "$ADB_BIN" connect "$SER" 2>&1 | grep -q "connected to"; then
    echo "adb 就绪（$((i*5))s）"; READY=1; break
  fi
done
if [ "$READY" -ne 1 ]; then
  echo "FAIL: adb 连不上"
  "$MUMU/MuMuManager.exe" control --vmindex 0 shutdown >/dev/null 2>&1
  exit 1
fi

step "设备信息"
adb shell getprop ro.build.version.release
adb shell wm size

step "安装 APK"
adb install -r -d "$APK" 2>&1 | tail -3

step "拉起 App"
adb shell am force-stop "$PKG"
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 9
adb shell dumpsys activity activities 2>/dev/null | grep -m1 -E "mResumedActivity|topResumedActivity"

shot() {
  "$ADB_BIN" -s "$SER" exec-out screencap -p > "$OUT/$1.png" 2>/dev/null
  echo "  截图 -> $1.png  ($(stat -c%s "$OUT/$1.png" 2>/dev/null) 字节)"
}

step "1) 启动后（应为主菜单）"
shot mumu_1_main

step "2) 点「单机对战」"
adb shell input tap 540 960
sleep 3
shot mumu_2_battle

step "3) 对局中点右上「菜单」"
adb shell input tap 997 52
sleep 2
shot mumu_3_exitconfirm

step "4) 点「返回主菜单」（先自动找金色主按钮的位置）"
GOLD=$(python "$PROJ/tools/find_gold.py" "$OUT/mumu_3_exitconfirm.png" 700 1500 | tr -d '\r')
if [ -z "$GOLD" ]; then
  echo "FAIL: 退出确认层里没找到金色主按钮"
else
  echo "  金色按钮位置：$GOLD"
  adb shell input tap $GOLD
fi
sleep 3
shot mumu_4_backhome

step "4b) 再验证一次：对局 -> 菜单 -> 返回主菜单"
adb shell input tap 540 960
sleep 3
adb shell input tap 997 52
sleep 2
GOLD=$(python "$PROJ/tools/find_gold.py" "$OUT/mumu_3_exitconfirm.png" 700 1500 | tr -d '\r')
adb shell input tap $GOLD
sleep 3
shot mumu_4b_backhome_again

step "5) 强制停止后重启（必须回到主菜单）"
adb shell am force-stop "$PKG"
sleep 2
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 9
shot mumu_5_restart

step "6) 回桌面再进一次（检查没有残留对局）"
adb shell input keyevent KEYCODE_HOME
sleep 2
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 9
shot mumu_6_relaunch

step "关模拟器"
"$MUMU/MuMuManager.exe" control --vmindex 0 shutdown >/dev/null 2>&1

step "黑屏判定"
python "$PROJ/tools/check_shots.py" "$OUT"
