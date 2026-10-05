#!/usr/bin/env bash
# 受控交错回归（黑盒 HTTP）：
# 同一设备两次合法声明，长度分别为 3、6；让第二次在第一次“已提交且停在
# 返回之前”的窗口内完整落库。修复前两份响应都显示 declared_length=6，
# 修复后必须分别为 3、6，且最终数据库状态为 6（等价某种串行执行）。
#
# 依赖服务以 FIRMWARE_TEST_PAUSE_DIR=<目录> 启动（见 README“并发交错复现”）。
# 纯 curl，无第三方工具（jq 仅用于美化，缺失也能跑）。
#
# 确定性顺序（与 test_api.py 第 12 节的线程回归一致）：
#   1. 放置挂点标记后发起声明 A；
#   2. 等到 $PAUSE_DIR/declare_update.held 出现 —— 这表示 A 已提交且确实
#      停在挂点上。不能用“数据库里查得到”代替这一确认：A 可能在 commit
#      之后、进入挂点之前被调度出去，此时标记尚未被接管，若就此发出 B，
#      B 会抢占标记并挂起，而脚本又在等 B 返回，形成等待环（脚本挂死）；
#   3. 再发声明 B 并等它完整返回（它见不到标记，直接放行）；
#   4. 确认 A 的响应仍未返回，才删除 .held 放行。
# 任何一步等待超时或失败：释放挂点（删除标记与 .held）后以非零退出，
# 脚本本身不会无限挂起。
set -u

BASE=${BASE_URL:-http://localhost:8000}
PAUSE_DIR=${FIRMWARE_TEST_PAUSE_DIR:-/tmp/fw-pause}
# 每次运行使用唯一设备，避免与历史数据相互干扰（API 不提供删除）
DEV=${DEV:-race-http-$(date +%s)-$$}
OUT=${OUT_DIR:-/tmp/fw-race-out}
mkdir -p "$OUT"

MARKER="$PAUSE_DIR/declare_update"
HELD="$PAUSE_DIR/declare_update.held"
# 各等待环节的超时（秒）：覆盖慢启动/调度延迟，但绝不无限等
WAIT_MAX=${WAIT_MAX:-30}

PID_A=""

release_pause() { # 释放挂点：无论脚本以何种方式退出都让服务侧放行
  rm -f "$MARKER" "$HELD" 2>/dev/null || true
}

fail() {
  echo "FAIL: $*" >&2
  release_pause
  [ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null
  exit 1
}

# 兜底：异常退出（含 Ctrl-C）也释放挂点，不在服务侧留下挂起的请求
trap release_pause EXIT

jqf() { if command -v jq >/dev/null 2>&1; then jq "$@"; else cat; fi; }
sha256_hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# 从整设备视图取“第一个非空 declared_length”（本例候选为 slot1；slot0 为
# 已确认槽，declared_length 为 null，不会匹配至少一位数字的模式）。
first_declared() { grep -o '"declared_length":[0-9][0-9]*' | head -1 | cut -d: -f2; }
req() { # method path [json-body]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" "$BASE$2" -H 'Content-Type: application/json' -d "$3"
  else
    curl -sS -X "$1" "$BASE$2"
  fi
}

# 等待文件出现，带超时（0.05s 粒度，总时长 $2 秒）
wait_file() { # path timeout_sec
  local tries=$(( $2 * 20 ))
  while [ "$tries" -gt 0 ]; do
    [ -e "$1" ] && return 0
    sleep 0.05
    tries=$(( tries - 1 ))
  done
  return 1
}

echo ">> 健康检查"
curl -fsS "$BASE/health" >/dev/null || { echo "服务未就绪：$BASE/health"; exit 1; }

echo ">> 设备：$DEV"
echo ">> 创建设备（初始镜像 base）"
INIT_B64=$(printf 'base' | base64 | tr -d '\n')
req POST /devices "$(printf '{"device_id":"%s","initial_image_base64":"%s"}' "$DEV" "$INIT_B64")" \
  | jqf '.slots' >/dev/null

SHA3=$(sha256_hex abc)
SHA6=$(sha256_hex abcdef)

echo ">> 放置挂点标记：$MARKER"
mkdir -p "$PAUSE_DIR"
release_pause          # 清掉可能残留的旧标记，保证本次协议从干净状态开始
: > "$MARKER"

echo ">> 发起声明 A（length=3），它会在提交后停在挂点上"
( req PUT "/devices/$DEV/update" "$(printf '{"length":3,"sha256":"%s"}' "$SHA3")" \
    > "$OUT/respA.json" ) &
PID_A=$!

echo ">> 等待 A 确认停在挂点（$HELD 出现；不能用数据库可见代替暂停确认）"
wait_file "$HELD" "$WAIT_MAX" \
  || fail "未等到 A 进入挂点（.held 未出现），已释放挂点"
# 附带核对：A 的写入已随 commit 落库（挂点在 commit 之后触发，必然可见）
L=$(req GET "/devices/$DEV" | first_declared)
[ "$L" = "3" ] || fail "A 已挂起但库中 declared_length=$L（期望 3）"
echo "   A 已提交且停在返回前（库中=3）"

echo ">> 在 A 返回前，完整执行声明 B（length=6）"
req PUT "/devices/$DEV/update" "$(printf '{"length":6,"sha256":"%s"}' "$SHA6")" \
  > "$OUT/respB.json" || fail "声明 B 请求失败"
LB=$(first_declared < "$OUT/respB.json")
[ "$LB" = "6" ] || fail "B 自身响应应为 6，实际：$LB"

echo ">> 确认 A 的响应仍未返回，然后删除 .held 放行"
kill -0 "$PID_A" 2>/dev/null || fail "A 在放行前已返回，交错不成立"
[ -s "$OUT/respA.json" ] && fail "A 的响应文件在放行前已有内容，交错不成立"
release_pause

echo ">> 等待 A 返回（带超时）"
tries=$(( WAIT_MAX * 20 ))
while [ "$tries" -gt 0 ]; do
  kill -0 "$PID_A" 2>/dev/null || break
  sleep 0.05
  tries=$(( tries - 1 ))
done
kill -0 "$PID_A" 2>/dev/null && fail "放行后 A 仍未返回"
wait "$PID_A" 2>/dev/null

LA=$(first_declared < "$OUT/respA.json")
FINAL=$(req GET "/devices/$DEV" | first_declared)

echo
echo "A 响应 declared_length = $LA   （期望 3）"
echo "B 响应 declared_length = $LB   （期望 6）"
echo "最终数据库 declared_length = $FINAL （期望 6）"
echo
if [ "$LA" = 3 ] && [ "$LB" = 6 ] && [ "$FINAL" = 6 ]; then
  echo "PASS：响应快照彼此独立，终态等价串行执行（A -> B）。"
  exit 0
else
  echo "FAIL：并发响应混入了后续写入。"
  echo "-- A 响应 --"; cat "$OUT/respA.json"
  exit 1
fi
