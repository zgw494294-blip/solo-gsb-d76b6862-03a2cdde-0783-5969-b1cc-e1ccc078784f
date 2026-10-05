#!/usr/bin/env bash
# scripts/race_repro.sh 的黑盒回归：用 scripts/race_stub.py（仅标准库的本地
# 可控传输桩）注入传输层异常，断言脚本：
#   - 成功路径：确定性交错（先确认 A 暂停 → B 完整返回 → 放行 A），PASS；
#   - 竞争请求在传输层停滞：脚本有限等待后非零退出，不挂死、不误报；
#   - 首响应残缺（只含长度 3 的半截 JSON，curl rc=18）：非零退出，不 PASS；
#   - 首响应 HTTP 200 但体是非法 JSON（curl rc=0）：非零退出，不 PASS；
#   - 竞争请求 HTTP 500：非零退出；
#   - 对端不可达（连接失败）：非零退出；
#   - 首请求预算配置过小：启动期直接拒绝，不破坏交错。
# 任何失败路径都额外核对：标记与 .held 已清理、无残留 curl 进程。
#
# 运行：bash test_race_repro.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/scripts/race_repro.sh"
STUB="$HERE/scripts/race_stub.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 用极小的预算跑，异常场景秒级结束；成功路径同样在几百毫秒内完成
COMMON_ENV=(
  WAIT_MAX=3
  HTTP_MAX_TIME=2
  HTTP_CONNECT_TIMEOUT=1
  FIRMWARE_TEST_PAUSE_DIR="$WORK/pause"
  OUT_DIR="$WORK/out"
)

FAILURES=0
STUB_PID=""
STUB_PORT=""
SCRIPT_RC=0

ok()   { echo "  ok - $1"; }
bad()  { echo "  NOT OK - $1"; FAILURES=$(( FAILURES + 1 )); }

expect_contains() { # file pattern message
  if grep -qF "$2" "$1"; then ok "$3"; else bad "$3（缺少：$2）"; fi
}

# start_stub <mode>：启动桩并从首行读取内核分配的端口
start_stub() { # mode
  local mode=$1 i
  rm -rf "$WORK/pause"; mkdir -p "$WORK/pause"
  RACE_STUB_MODE="$mode" FIRMWARE_TEST_PAUSE_DIR="$WORK/pause" \
    python3 "$STUB" --pause-dir "$WORK/pause" >"$WORK/stub.log" 2>&1 &
  STUB_PID=$!
  for (( i = 0; i < 100; i++ )); do
    if grep -q '^PORT ' "$WORK/stub.log" 2>/dev/null; then
      STUB_PORT=$(cut -d' ' -f2 "$WORK/stub.log")
      return 0
    fi
    kill -0 "$STUB_PID" 2>/dev/null || { echo "桩进程退出，日志："; cat "$WORK/stub.log"; return 1; }
    sleep 0.05
  done
  echo "桩未在 5s 内输出端口，日志："; cat "$WORK/stub.log"
  return 1
}

stop_stub() {
  [ -n "$STUB_PID" ] || return 0
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""; STUB_PORT=""
}

# 在当前 BASE_URL 上运行脚本（15 秒硬上限兜底，正常 1~3 秒），记录退出码
run_script() {
  rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  env "${COMMON_ENV[@]}" BASE_URL="http://127.0.0.1:$STUB_PORT" \
      timeout --signal=KILL 15 bash "$SCRIPT" >"$WORK/run.out" 2>"$WORK/run.err"
  SCRIPT_RC=$?
}

# 失败路径的共同收尾断言：非零退出、无 PASS、标记清理、无残留 curl、未挂死
assert_failure_cleanup() { # name
  local name=$1
  if [ "$SCRIPT_RC" -ne 0 ]; then
    ok "$name：非零退出 ($SCRIPT_RC)"
  else
    bad "$name：脚本退出码为 0（应非零）"
  fi
  if grep -q '^PASS' "$WORK/run.out"; then bad "$name：竟然打印了 PASS"; else ok "$name：未打印 PASS"; fi
  if [ -e "$WORK/pause/declare_update" ] || [ -e "$WORK/pause/declare_update.held" ]; then
    bad "$name：标记/.held 未清理：$(ls "$WORK/pause")"
  else
    ok "$name：标记与 .held 已清理"
  fi
  # 残留 curl（脚本的子进程已随 timeout 进程组结束；这里查的是游离进程）
  if pgrep -f "race-http-" >/dev/null 2>&1 || pgrep -f "127.0.0.1:$STUB_PORT/devices" >/dev/null 2>&1; then
    bad "$name：存在残留 curl 进程"
    pgrep -af "race-http-|127.0.0.1:$STUB_PORT" || true
  else
    ok "$name：无残留 curl 进程"
  fi
}

echo "== 1. 成功路径：3 / 6 / 终态 6，PASS，交错顺序成立 =="
start_stub success
run_script
if [ "$SCRIPT_RC" -eq 0 ]; then ok "success 退出 0"; else bad "success 退出码 $SCRIPT_RC"; cat "$WORK/run.err"; fi
expect_contains "$WORK/run.out" 'A 响应 declared_length = 3（期望 3）' "A=3"
expect_contains "$WORK/run.out" 'B 响应 declared_length = 6（期望 6）' "B=6"
expect_contains "$WORK/run.out" '最终数据库 declared_length = 6（期望 6）' "终态=6"
expect_contains "$WORK/run.out" 'PASS：响应快照彼此独立' "打印 PASS"
# 交错顺序在输出中可见（.held 确认发生在 B 之前，放行发生在 B 之后）
expect_contains "$WORK/run.out" 'A 已提交且停在返回前' "先确认 A 暂停"
expect_contains "$WORK/run.out" '完整执行声明 B' "再完成 B"
expect_contains "$WORK/run.out" '删除 .held 放行' "最后放行"
stop_stub

echo "== 2. 竞争请求在传输层停滞：有限等待后失败，不挂死 =="
start_stub stall-competitor
t0=$(date +%s%N)
run_script
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
assert_failure_cleanup "stall-competitor"
# 预算：B 在 HTTP_MAX_TIME(2s) 超时，整体应远小于硬上限 15s
if [ "$elapsed_ms" -lt 14000 ]; then
  ok "stall 场景 ${elapsed_ms}ms 返回（未挂死）"
else
  bad "stall 场景耗时 ${elapsed_ms}ms，疑似挂死"
fi
expect_contains "$WORK/run.err" '传输失败' "诊断信息指向传输失败"
stop_stub

echo "== 3. 首响应残缺（半截 JSON 含长度 3，curl rc=18）：失败，不误报 PASS =="
start_stub truncate-first
run_script
assert_failure_cleanup "truncate-first"
expect_contains "$WORK/run.err" '传输失败' "诊断指向传输失败（curl rc=18 截断）"
# 旧脚本正是从这份残缺文件里提取出 3 而误报；新脚本必须拒绝它
if grep -q '^PASS' "$WORK/run.out"; then bad "残缺响应被当成有效快照"; else ok "残缺长度 3 未被当作有效快照"; fi
stop_stub

echo "== 3b. 首响应为 200 但体是非法 JSON（curl rc=0）：失败，不误报 PASS =="
start_stub garbled-first
run_script
assert_failure_cleanup "garbled-first"
expect_contains "$WORK/run.err" '响应不完整或不是合法 JSON' "诊断指向响应不是合法 JSON"
stop_stub

echo "== 4. 竞争请求返回 HTTP 500：失败 =="
start_stub competitor-500
run_script
assert_failure_cleanup "competitor-500"
expect_contains "$WORK/run.err" 'HTTP 500' "诊断包含 HTTP 500"
stop_stub

echo "== 5. 对端不可达（连接失败）：健康检查即失败 =="
STUB_PORT=1     # 1 号端口上没有服务
rm -rf "$WORK/pause"; mkdir -p "$WORK/pause"
env "${COMMON_ENV[@]}" BASE_URL="http://127.0.0.1:1" \
    timeout --signal=KILL 15 bash "$SCRIPT" >"$WORK/run.out" 2>"$WORK/run.err"
SCRIPT_RC=$?
assert_failure_cleanup "unreachable"
STUB_PORT=""

echo "== 6. 首请求预算配置过小：启动期直接拒绝（防止提前破坏交错） =="
start_stub success
env FIRST_HTTP_MAX_TIME=1 "${COMMON_ENV[@]}" BASE_URL="http://127.0.0.1:$STUB_PORT" \
    timeout --signal=KILL 15 bash "$SCRIPT" >"$WORK/run.out" 2>"$WORK/run.err"
SCRIPT_RC=$?
if [ "$SCRIPT_RC" -ne 0 ] && grep -q 'FIRST_HTTP_MAX_TIME' "$WORK/run.err"; then
  ok "过小预算被拒绝"
else
  bad "过小预算未被拒绝（rc=$SCRIPT_RC）"
fi
if [ -e "$WORK/pause/declare_update" ]; then bad "拒绝后仍有标记残留"; else ok "拒绝时未留下标记"; fi
stop_stub

echo "== 7. HTTP_MAX_TIME=0（curl 语义为无限等待）：启动期直接拒绝 =="
start_stub success
env "${COMMON_ENV[@]}" HTTP_MAX_TIME=0 BASE_URL="http://127.0.0.1:$STUB_PORT" \
    timeout --signal=KILL 15 bash "$SCRIPT" >"$WORK/run.out" 2>"$WORK/run.err"
SCRIPT_RC=$?
if [ "$SCRIPT_RC" -eq 2 ] && grep -q 'HTTP_MAX_TIME' "$WORK/run.err"; then
  ok "0 超时（无限等待语义）被拒绝"
else
  bad "0 超时未被拒绝（rc=$SCRIPT_RC）"
fi
stop_stub

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL RACE-SCRIPT REGRESSIONS PASSED"
  exit 0
fi
echo "$FAILURES CHECK(S) FAILED"
exit 1
