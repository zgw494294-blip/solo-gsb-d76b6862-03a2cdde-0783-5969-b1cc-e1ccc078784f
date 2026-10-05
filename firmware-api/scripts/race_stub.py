#!/usr/bin/env python3
"""本地可控传输桩（仅标准库，无第三方依赖）。

用途：在**不启动真实服务、不碰数据库**的情况下，为 scripts/race_repro.sh
提供一个黑盒 HTTP 对端，确定性地注入传输层异常，回归脚本“传输异常时不挂死、
不误报 PASS”的行为。桩遵守与 app/main.py 相同的挂点文件协议
（FIRMWARE_TEST_PAUSE_DIR 下的 declare_update -> declare_update.held），
因此 race_repro.sh 无需任何改动就能以真实交错驱动它。

模式（--mode / RACE_STUB_MODE）：
  success           正常受控交错：首请求快照 3、竞争请求 6、终态 6。
  stall-competitor  竞争请求（在 .held 已存在时到达的 /update）的响应永不
                    结束，模拟对端接受请求后在传输层挂死。
  truncate-first    首请求被放行后，只回一个包含 "declared_length":3 的
                    残缺 JSON（声明 Content-Length 大于实际字节后断连），
                    curl 必须以 CURLE_PARTIAL_FILE(18) 失败。
  garbled-first     首请求被放行后，返回 HTTP 200、Content-Length 自洽、
                    curl 成功（rc=0），但响应体是包含 "declared_length":3
                    的非法 JSON，用于核验“传输成功但响应不完整”也必须失败。
  competitor-500    竞争请求返回完整的 HTTP 500。

健康检查、创建设备、设备查询始终正常；挂点只影响 PUT /devices/{id}/update。
"""

from __future__ import annotations

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER_NAME = "declare_update"


class RaceState:
    def __init__(self, pause_dir: str, mode: str):
        self.pause_dir = pause_dir
        self.mode = mode
        self.lock = __import__("threading").Lock()
        self.declared: dict[str, int] = {}  # device_id -> 最近声明长度
        self.shas: dict[str, str] = {}

    def commit_declare(self, dev: str, length: int, sha: str) -> None:
        with self.lock:
            self.declared[dev] = length
            self.shas[dev] = sha


def slot0_view() -> dict:
    # 已确认槽：declared_length 为 null（脚本取“第一个非空 declared_length”）
    return {
        "status": "confirmed",
        "image_sha256": None,
        "image_length": 4,
        "declared_length": None,
        "declared_sha256": None,
        "bytes_received": None,
    }


def slot1_view(length, sha) -> dict:
    if length is None:
        return {
            "status": "empty",
            "image_sha256": None,
            "image_length": None,
            "declared_length": None,
            "declared_sha256": None,
            "bytes_received": None,
        }
    return {
        "status": "in-progress",
        "image_sha256": None,
        "image_length": None,
        "declared_length": length,
        "declared_sha256": sha,
        "bytes_received": 0,
    }


def device_view(dev: str, length, sha) -> dict:
    return {
        "device_id": dev,
        "trial_state": "running-confirmed",
        "confirmed_slot": 0,
        "running_slot": 0,
        "pending_token": None,
        "slots": {"slot0": slot0_view(), "slot1": slot1_view(length, sha)},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # 连接被异常掐断时不打堆栈：传输失败本来就是被测场景
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def log_message(self, fmt, *args):  # 安静：日志由调用方按需收集
        pass

    # -- 辅助 ---------------------------------------------------------------

    @property
    def state(self) -> RaceState:
        return self.server.state  # type: ignore[attr-defined]

    def _read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode()) if raw else {}
        except Exception:
            return {}

    def _send_json(self, code: int, obj) -> None:
        # 紧凑 JSON（separators 无空格）：与 Starlette JSONResponse 的输出一致，
        # race_repro.sh 据此用 "declared_length":[0-9]* 提取字段。
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _dev_from_path(self) -> str | None:
        # /devices/{id} 或 /devices/{id}/update
        parts = self.path.strip("/").split("/")
        if len(parts) >= 2 and parts[0] == "devices":
            return parts[1]
        return None

    def _current_view(self, dev: str) -> dict:
        with self.state.lock:
            length = self.state.declared.get(dev)
            sha = self.state.shas.get(dev)
        return device_view(dev, length, sha)

    # -- 路由 ---------------------------------------------------------------

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        dev = self._dev_from_path()
        if dev is None:
            self._send_json(404, {"detail": "not found"})
            return
        # 未创建的设备也返回视图；脚本每次用唯一设备且会先 POST /devices
        self._send_json(200, self._current_view(dev))

    def do_POST(self):
        if self.path != "/devices":
            self._send_json(404, {"detail": "not found"})
            return
        body = self._read_json()
        dev = str(body.get("device_id") or "stub-dev")
        self._send_json(201, device_view(dev, None, None))

    def do_PUT(self):
        dev = self._dev_from_path()
        if dev is None or not self.path.endswith("/update"):
            self._send_json(404, {"detail": "not found"})
            return
        body = self._read_json()
        try:
            length = int(body.get("length"))
        except (TypeError, ValueError):
            self._send_json(422, {"detail": "bad length"})
            return
        sha = str(body.get("sha256") or "")

        # “写事务提交”发生在进入挂点之前：先落库（内存），再处理挂点协议
        self.state.commit_declare(dev, length, sha)
        snapshot = device_view(dev, length, sha)

        pause_dir = self.state.pause_dir
        marker = os.path.join(pause_dir, MARKER_NAME)
        held = os.path.join(pause_dir, MARKER_NAME + ".held")

        parked = False
        try:
            # 原子接管：只有第一个命中的请求能 rename 成功
            os.rename(marker, held)
            parked = True
        except OSError:
            parked = False

        if not parked:
            # 竞争请求：首请求正停在挂点上（.held 存在）。按模式注入传输异常。
            if os.path.exists(held):
                if self.state.mode == "stall-competitor":
                    self._stall_forever()
                    return
                if self.state.mode == "competitor-500":
                    self._send_json(500, {"detail": {"code": "simulated_500",
                                                     "message": "stub injected"}})
                    return
            self._send_json(200, snapshot)
            return

        # 首请求：阻塞到 .held 被删除（删除即脚本放行）
        while os.path.exists(held):
            time.sleep(0.02)

        if self.state.mode == "truncate-first":
            self._send_truncated(dev)
            return
        if self.state.mode == "garbled-first":
            # 传输完整、状态 200、长度自洽，但体不是合法 JSON
            self._send_bytes(200, b'{"slots":{"slot1":{"declared_length":3},},,')
            return
        self._send_json(200, snapshot)

    # -- 异常注入 -----------------------------------------------------------

    def _stall_forever(self) -> None:
        # 请求体已读完、响应一个字节都不发。工作线程为 daemon，
        # 进程退出时随之消失；脚本侧必须靠 curl 的有限等待超时并 kill/回收。
        while True:
            time.sleep(3600)

    def _send_bytes(self, code: int, payload: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_truncated(self, dev: str) -> None:
        # 完整响应应含 length=3 的快照，但这里只发前半截：
        # 声明的 Content-Length 大于实际写出的字节，随后断连，
        # curl 得到 CURLE_PARTIAL_FILE(18)。残缺内容里恰好包含 3，
        # 专门用来证明旧脚本会误报 PASS。
        payload = (
            '{"device_id":"' + dev + '",'
            '"slots":{"slot0":{"declared_length":null},'
            '"slot1":{"declared_length":3}'
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload) + 500))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(payload)
            self.wfile.flush()
            # 显式半关闭并给对端一点读取时间：残缺字节必须确实到达客户端
            # （curl 写出部分响应体后再以 18 失败），不能随 RST 一起被丢弃。
            self.connection.shutdown(__import__("socket").SHUT_WR)
            time.sleep(0.2)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0,
                    help="监听端口；0 表示由内核分配（输出 PORT <port>）")
    ap.add_argument("--mode", default=os.environ.get("RACE_STUB_MODE", "success"),
                    choices=["success", "stall-competitor", "truncate-first",
                             "garbled-first", "competitor-500"])
    ap.add_argument("--pause-dir",
                    default=os.environ.get("FIRMWARE_TEST_PAUSE_DIR", "/tmp/fw-pause"))
    args = ap.parse_args()

    os.makedirs(args.pause_dir, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.state = RaceState(args.pause_dir, args.mode)  # type: ignore[attr-defined]
    print(f"PORT {server.server_port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
