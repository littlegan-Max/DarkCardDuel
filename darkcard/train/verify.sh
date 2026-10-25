#!/usr/bin/env bash
# 一条命令跑完所有验证：卡表 → GDScript 单测 → Python 单测 → 双引擎对拍
# 用法：bash train/verify.sh [对拍局数]

set -u
GODOT="${GODOT:-D:/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64.exe}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
CASES="${1:-400}"
fail=0

run() {
  local name="$1"; shift
  echo "── $name"
  if "$@"; then
    echo "   OK"
  else
    echo "   FAILED"
    fail=1
  fi
}

echo "project: $PROJ"
echo

run "卡表校验" "$GODOT" --headless --path "$PROJ" --script res://tools/validate_cards.gd
run "GDScript 单测" "$GODOT" --headless --path "$PROJ" --script res://tests/test_runner.gd
run "Python 引擎对齐" python "$PROJ/train/test_align.py"
run "策略网络前向" "$GODOT" --headless --path "$PROJ" --script res://tools/test_policy_net.gd
run "特征跨语言比对" python "$PROJ/train/export_features_ref.py"
run "特征跨语言比对" "$GODOT" --headless --path "$PROJ" --script res://tools/test_policy_features.gd
run "对手习惯模型" "$GODOT" --headless --path "$PROJ" --script res://tests/test_opponent_model.gd
run "生成对拍用例" python "$PROJ/train/export_parity.py" "$CASES"
run "双引擎对拍" "$GODOT" --headless --path "$PROJ" --script res://tools/parity_check.gd
run "不变量扫描" python "$PROJ/train/invariants.py" 800
run "联机服务器自测" python "$PROJ/server/test_server.py"
run "自动更新专项（4 类更新形式）" python "$PROJ/server/test_update.py"
run "升级过渡实测（v0.3.0 → v0.3.1）" python "$PROJ/server/test_transition.py"
run "新模式自动更新实测" python "$PROJ/server/test_new_mode.py"
run "联机端到端（双客户端）" python "$PROJ/tools/run_online_test.py"
run "打包服务器（发给对方的 zip）" python "$PROJ/tools/pack_server.py"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "SOME CHECKS FAILED"
fi
exit "$fail"
