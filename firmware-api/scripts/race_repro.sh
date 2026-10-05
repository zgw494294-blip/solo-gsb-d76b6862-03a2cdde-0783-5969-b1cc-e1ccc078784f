#!/usr/bin/env bash
# 受控交错回归（黑盒 HTTP）：
# 同一设备两次合法声明，长度分别为 3、6；让第二次在第一次“已提交且停在
# 返回之前”的窗口内完整落库。修复前两份响应都显示 declared_length=6，
# 修复后必须分别为 3、6，且最终数据库状态为 6（等价某种串行执行）。
#
# 依赖服务以 FIRMWARE_TEST_PAUSE_DIR=<目录> 启动（见 README“并发交错复现”）。
# 纯 curl，无第三方工具（jq/python3 仅用于 JSON 完整性校验，二选一即可）。
#
# 确定性顺序（与 test_api.py 第 12 节的线程回归一致）：
#   1. 放置挂点标记后发起声明 A；
#   2. 等到 $PAUSE_DIR/declare_update.held 出现 —— 这表示 A 已提交且确实
#      停在挂点上。不能用“数据库里查得到”代替这一确认：A 可能在 commit
#      之后、进入挂点之前被调度出去，此时标记尚未被接管，若就此发出 B，
#      B 会抢占标记并挂起，而脚本又在等 B 返回，形成等待环（脚本挂死）；
#   3. 再发声明 B 并等它完整返回（它见不到标记，直接放行）；
#   4. 确认 A 的响应仍未返回，才删除 .held 放行。
#
# 有界等待（任何一环都不会无限挂起）：
#   - 每个 HTTP 调用都带 --connect-timeout / --max-time（可经环境变量配置）；
#   - 首请求 A 的总预算 FIRST_HTTP_MAX_TIME 默认覆盖“等 .held + 竞争请求 +
#     等放行”的全程，绝不能在交错完成前提前掐断 A，否则会人为破坏交错；
#   - 传输失败（curl 非零，含 --max-time 超时、连接失败、响应截断 18）、
#     HTTP 状态非 2xx、或响应不是完整合法的 JSON，一律视为失败：
#     非零退出、清理标记与 .held、终止并回收后台 A；
#   - 只有两份响应与终态查询都通过“传输 + 状态码 + 完整 JSON + 长度 3/6/6”
#     核验时才打印 PASS。
set -u

BASE=${BASE_URL:-http://localhost:8000}
PAUSE_DIR=${FIRMWARE_TEST_PAUSE_DIR:-/tmp/fw-pause}
# 每次运行使用唯一设备，避免与历史数据相互干扰（API 不提供删除）
DEV=${DEV:-race-http-$(date +%s)-$$}
OUT=${OUT_DIR:-/tmp/fw-race-out}
mkdir -p "$OUT"

MARKER="$PAUSE_DIR/declare_update"
HELD="$PAUSE_DIR/declare_update.held"
# 文件出现等轮询环节的超时（秒）：覆盖慢启动/调度延迟，但绝不无限等
WAIT_MAX=${WAIT_MAX:-30}
# 普通 HTTP 调用（健康检查、创建、查询、竞争请求 B）的有限等待（秒）
HTTP_MAX_TIME=${HTTP_MAX_TIME:-30}
HTTP_CONNECT_TIMEOUT=${HTTP_CONNECT_TIMEOUT:-5}
# 首请求 A 从发起到放行后返回的总预算（秒）。A 在挂点上停留的全程包括：
#   脚本等 .held(WAIT_MAX) + 挂起后的核对 GET(HTTP_MAX_TIME)
#   + 竞争请求 B(HTTP_MAX_TIME) + 放行后等 A 返回(WAIT_MAX)
# 再留建连与调度余量；默认必须覆盖这一全程，可用 FIRST_HTTP_MAX_TIME 覆盖。
FIRST_HTTP_MAX_TIME=${FIRST_HTTP_MAX_TIME:-$(( 2 * WAIT_MAX + 2 * HTTP_MAX_TIME + HTTP_CONNECT_TIMEOUT + 5 ))}

# 配置必须是正整数；curl 的 --max-time/--connect-timeout 取 0 表示“无限”，
# 这里连同轮询超时一并拒绝 0。首请求预算还不得小于交错全程所需，避免提前掐断 A。
for _n in WAIT_MAX HTTP_MAX_TIME HTTP_CONNECT_TIMEOUT FIRST_HTTP_MAX_TIME; do
  _v=${!_n}
  case "$_v" in
    ''|*[!0-9]*) echo "FAIL: $_n 必须是正整数（当前：$_v）" >&2; exit 2;;
  esac
  if [ "$_v" -lt 1 ]; then
    echo "FAIL: $_n 必须 >= 1（0 在 curl 中表示无限等待，当前：$_v）" >&2; exit 2
  fi
done
_FIRST_MIN=$(( 2 * WAIT_MAX + 2 * HTTP_MAX_TIME + HTTP_CONNECT_TIMEOUT ))
if [ "$FIRST_HTTP_MAX_TIME" -lt "$_FIRST_MIN" ]; then
  echo "FAIL: FIRST_HTTP_MAX_TIME=$FIRST_HTTP_MAX_TIME 小于交错全程所需的 $_FIRST_MIN" >&2
  echo "      （2*WAIT_MAX + 2*HTTP_MAX_TIME + HTTP_CONNECT_TIMEOUT），会提前掐断首请求、破坏交错" >&2
  exit 2
fi

PID_A=""
# 当前前台请求（健康检查/创建/查询/竞争 B）所在的进程组；收到信号时必须
# 连同它一起终止，否则停滞的 curl 会把 trap 挡到 --max-time 才执行。
FG_PGID=""
# 最近一次前台调用的 HTTP 状态码文件（http_expect 使用）
OUT_STATUS=""

release_pause() { # 释放挂点：无论脚本以何种方式退出都让服务侧放行
  rm -f "$MARKER" "$HELD" 2>/dev/null || true
}

kill_group() { # pgid  杀掉一个独立进程组（负号 PGID），容忍已消失
  [ -n "$1" ] || return 0
  kill -TERM "-$1" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "-$1" 2>/dev/null || return 0
    sleep 0.05
    i=$(( i + 1 ))
  done
  kill -KILL "-$1" 2>/dev/null || true
}

reap_a() { # 终止并回收后台首请求，保证不残留挂在对端的 curl
  [ -n "$PID_A" ] || return 0
  local i=0
  kill "$PID_A" 2>/dev/null || true
  while [ "$i" -lt 100 ]; do
    kill -0 "$PID_A" 2>/dev/null || break
    sleep 0.05
    i=$(( i + 1 ))
  done
  kill -9 "$PID_A" 2>/dev/null || true
  wait "$PID_A" 2>/dev/null || true
  PID_A=""
}

fail() {
  echo "FAIL: $*" >&2
  release_pause
  kill_group "$FG_PGID"; FG_PGID=""
  reap_a
  exit 1
}

# 兜底：异常退出（含 Ctrl-C）也释放挂点、回收后台请求，不留下挂起的连接
# shellcheck disable=SC2317  # 仅由 EXIT trap 间接调用
on_exit() {
  local rc=$?
  release_pause
  kill_group "$FG_PGID"
  [ -n "$PID_A" ] && { kill "$PID_A" 2>/dev/null || true; wait "$PID_A" 2>/dev/null || true; }
  exit "$rc"
}
# 信号到达时，停滞的前台 curl 可能正占着执行流（非交互 shell 不会把信号
# 转发给它）：先杀掉它的进程组，trap 才能继续执行清理。
# shellcheck disable=SC2317  # 仅由 INT/TERM trap 间接调用
on_signal() {
  kill_group "$FG_PGID"; FG_PGID=""
  fail "被中断"
}
trap on_exit EXIT
trap on_signal INT TERM

first_declared() {
  # 从整设备视图取“第一个非空 declared_length”（本例候选为 slot1；slot0 为
  # 已确认槽，declared_length 为 null，不会匹配至少一位数字的模式）。
  grep -o '"declared_length":[0-9][0-9]*' | head -1 | cut -d: -f2
}
sha256_hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# JSON 完整性校验：jq 与 python3 任一可用即可，都没有时退回括号配对检查。
json_valid() { # file
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  else
    # 最后兜底：非空、花括号/方括号配平（传输截断通常少右括号）
    local t
    t=$(tr -d '[:space:]' < "$1")
    [ -n "$t" ] || return 1
    case "$t" in
      \{*\}) ;;
      *) return 1;;
    esac
    local open close
    open=$(printf '%s' "$t" | tr -cd '{' | wc -c)
    close=$(printf '%s' "$t" | tr -cd '}' | wc -c)
    [ "$open" = "$close" ] || return 1
    open=$(printf '%s' "$t" | tr -cd '[' | wc -c)
    close=$(printf '%s' "$t" | tr -cd ']' | wc -c)
    [ "$open" = "$close" ]
  fi
}

# 在新进程组中运行参数给出的命令并 wait，进程组 PGID 记入 $1 变量名。
# 优先用 setsid；缺失时（如部分 macOS）退回 bash 作业自带的独立进程组：
# 启用作业控制后，后台作业即位于新进程组，PGID 可用 jobs -p 取得。
run_in_group() { # pgid_var_name command [args...]
  local _var=$1; shift
  local _pid _rc=0
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
    _pid=$!
    eval "$_var=\$_pid"     # setsid 新会话首进程：PID 即 PGID
    wait "$_pid" || _rc=$?
  else
    set -m
    "$@" &
    _pid=$!
    eval "$_var=\$_pid"     # 作业控制下后台作业自成进程组，PGID == PID
    wait "$_pid" || _rc=$?
    set +m
  fi
  return "$_rc"
}

# http_call <out-file> <max-time> <method> <path> [json-body]
# 响应体写入 <out-file>，HTTP 状态码写入 $OUT_STATUS（供 http_expect 读取）；
# curl 传输层失败（含超时、连接失败、响应截断）时返回非零。
#
# 必须在主 shell 中直接调用（不要放进命令替换 $()）：curl 在新进程组中
# 后台运行、主 shell 用 wait 等它——trap 能打断 wait 并杀掉整个进程组。
# 若包在 $() 子 shell 里，发给脚本的信号到不了 wait 中的调用，停滞的 curl
# 会把中断处理挡到 --max-time 超时之后。
http_call() {
  local out=$1 max=$2 method=$3 path=$4 body=${5:-}
  : > "$out"; : > "$OUT_STATUS"
  local args=( -sS --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$max"
               -o "$out" -w '%{http_code}' -X "$method" "$BASE$path" )
  if [ -n "$body" ]; then
    args+=( -H 'Content-Type: application/json' -d "$body" )
  fi
  run_in_group FG_PGID curl "${args[@]}" >"$OUT_STATUS"
  local rc=$?
  FG_PGID=""
  return "$rc"
}

# http_expect <out-file> <max-time> <method> <path> [json-body]
# 发起调用并要求“传输成功 + HTTP 2xx + 完整合法 JSON”，否则 fail 退出。
http_expect() {
  local out=$1 max=$2 method=$3 path=$4 body=${5:-}
  OUT_STATUS="$out.status"
  local code rc=0
  http_call "$out" "$max" "$method" "$path" ${body:+"$body"} || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "----- 响应体（传输失败，curl rc=$rc）-----" >&2
    cat "$out" >&2 2>/dev/null || true
    fail "$method $path 传输失败（curl rc=$rc，可能为超时/连接失败/响应截断）"
  fi
  code=$(cat "$OUT_STATUS" 2>/dev/null)
  case "$code" in
    2*) ;;
    *)
      echo "----- 响应体（HTTP $code）-----" >&2
      cat "$out" >&2 2>/dev/null || true
      fail "$method $path 返回 HTTP ${code:-<无状态码>}（期望 2xx）";;
  esac
  if ! json_valid "$out"; then
    echo "----- 响应体（不是完整合法的 JSON）-----" >&2
    cat "$out" >&2 2>/dev/null || true
    fail "$method $path 的响应不完整或不是合法 JSON"
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

# 轮询等待后台首请求进程结束（最多 $1 秒）。
# 正常结束：wait 回收后全局 RC_A 为 curl 退出码，返回 0；超时：返回 1。
wait_a_done() { # timeout_sec
  local tries=$(( $1 * 20 ))
  while [ "$tries" -gt 0 ]; do
    if ! kill -0 "$PID_A" 2>/dev/null; then
      wait "$PID_A"; RC_A=$?
      return 0
    fi
    sleep 0.05
    tries=$(( tries - 1 ))
  done
  return 1
}

echo ">> 健康检查（有限等待 ${HTTP_MAX_TIME}s）"
http_expect "$OUT/health.json" "$HTTP_MAX_TIME" GET /health \
  || { echo "服务未就绪：$BASE/health" >&2; exit 1; }

echo ">> 设备：$DEV"
echo ">> 创建设备（初始镜像 base）"
INIT_B64=$(printf 'base' | base64 | tr -d '\n')
http_expect "$OUT/create.json" "$HTTP_MAX_TIME" POST /devices \
  "$(printf '{"device_id":"%s","initial_image_base64":"%s"}' "$DEV" "$INIT_B64")"

SHA3=$(sha256_hex abc)
SHA6=$(sha256_hex abcdef)

echo ">> 放置挂点标记：$MARKER"
mkdir -p "$PAUSE_DIR"
release_pause          # 清掉可能残留的旧标记，保证本次协议从干净状态开始
: > "$MARKER"

echo ">> 发起声明 A（length=3），它会在提交后停在挂点上（总预算 ${FIRST_HTTP_MAX_TIME}s）"
# 后台化的是 curl 本身（exec）：PID_A 可被 kill/wait 直接终止与回收，
# 不会留下“子 shell 还在、curl 已成孤儿”的挂起请求。
( exec curl -sS --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
      --max-time "$FIRST_HTTP_MAX_TIME" \
      -o "$OUT/respA.json" -w '%{http_code}' \
      -X PUT "$BASE/devices/$DEV/update" \
      -H 'Content-Type: application/json' \
      -d "$(printf '{"length":3,"sha256":"%s"}' "$SHA3")" \
      > "$OUT/statusA" 2> "$OUT/curlA.err" ) &
PID_A=$!

echo ">> 等待 A 确认停在挂点（$HELD 出现；不能用数据库可见代替暂停确认）"
wait_file "$HELD" "$WAIT_MAX" \
  || fail "未等到 A 进入挂点（.held 未出现），已释放挂点"
# 附带核对：A 的写入已随 commit 落库（挂点在 commit 之后触发，必然可见）。
# 该查询本身也有有限等待与完整性要求，失败不能静默通过。
http_expect "$OUT/dev-hung.json" "$HTTP_MAX_TIME" GET "/devices/$DEV"
L=$(first_declared < "$OUT/dev-hung.json")
[ "$L" = "3" ] || fail "A 已挂起但库中 declared_length=$L（期望 3）"
echo "   A 已提交且停在返回前（库中=3）"

echo ">> 在 A 返回前，完整执行声明 B（length=6）"
http_expect "$OUT/respB.json" "$HTTP_MAX_TIME" PUT "/devices/$DEV/update" \
  "$(printf '{"length":6,"sha256":"%s"}' "$SHA6")"
LB=$(first_declared < "$OUT/respB.json")
[ "$LB" = "6" ] || fail "B 自身响应应为 6，实际：$LB"

echo ">> 确认 A 的响应仍未返回，然后删除 .held 放行"
kill -0 "$PID_A" 2>/dev/null || fail "A 在放行前已返回，交错不成立"
[ -s "$OUT/respA.json" ] && fail "A 的响应文件在放行前已有内容，交错不成立"
release_pause

echo ">> 等待 A 返回（带超时 ${WAIT_MAX}s）"
RC_A=124
if ! wait_a_done "$WAIT_MAX"; then
  fail "放行后 A 仍未返回（超过 ${WAIT_MAX}s）"
fi
PID_A=""
[ "$RC_A" -eq 0 ] || { echo "----- A 的 curl 错误输出（rc=$RC_A）-----" >&2
                       cat "$OUT/curlA.err" >&2 2>/dev/null || true
                       fail "声明 A 传输失败（curl rc=$RC_A，可能为超时/响应截断）"; }
CODE_A=$(cat "$OUT/statusA" 2>/dev/null)
case "$CODE_A" in
  2*) ;;
  *) fail "声明 A 返回 HTTP ${CODE_A:-<无状态码>}（期望 2xx）";;
esac
json_valid "$OUT/respA.json" || { echo "----- A 响应体（不完整）-----" >&2
                                  cat "$OUT/respA.json" >&2 2>/dev/null || true
                                  fail "声明 A 的响应不完整或不是合法 JSON"; }

LA=$(first_declared < "$OUT/respA.json")
http_expect "$OUT/dev-final.json" "$HTTP_MAX_TIME" GET "/devices/$DEV"
FINAL=$(first_declared < "$OUT/dev-final.json")

echo
echo "A 响应 declared_length = ${LA:-<无法解析>}（期望 3）"
echo "B 响应 declared_length = ${LB:-<无法解析>}（期望 6）"
echo "最终数据库 declared_length = ${FINAL:-<无法解析>}（期望 6）"
echo
if [ "$LA" = 3 ] && [ "$LB" = 6 ] && [ "$FINAL" = 6 ]; then
  echo "PASS：响应快照彼此独立，终态等价串行执行（A -> B）。"
  exit 0
else
  echo "FAIL：并发响应混入了后续写入，或响应不完整/无效。"
  echo "-- A 响应 --"; cat "$OUT/respA.json"
  exit 1
fi
