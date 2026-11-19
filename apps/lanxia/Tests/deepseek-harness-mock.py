"""Run the Swift integration test against the packaged SDK and a loopback SSE API."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import socket

parser = argparse.ArgumentParser()
parser.add_argument("test_binary", type=Path)
parser.add_argument("bundled_runtime", type=Path)
args = parser.parse_args()
turns = []
cancelled_connections = []


class MockDeepSeek(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        turns.append((self.path, self.headers.get("x-api-key"), request))
        serialized = json.dumps(request, ensure_ascii=False)
        if "模拟中断" in serialized:
            (root / "cancel-request-received").touch()
            self.connection.settimeout(4)
            try:
                cancelled_connections.append(self.connection.recv(1, socket.MSG_PEEK) == b"")
            except (OSError, TimeoutError):
                cancelled_connections.append(False)
            return
        if "模拟鉴权失败" in serialized:
            payload = b'{"type":"error","error":{"type":"authentication_error","message":"test key rejected"}}'
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        frames = [
            ("message_start", {"message": {
                "id": "msg_stashcat_test", "type": "message", "role": "assistant",
                "model": "deepseek-flash", "content": [], "stop_reason": None,
                "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0},
            }}),
            ("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": "本地联调成功。"}}),
            ("content_block_stop", {"index": 0}),
            ("message_delta", {"delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 5}}),
            ("message_stop", {}),
        ]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for event, body in frames:
                payload = json.dumps({"type": event, **body}, ensure_ascii=False)
                self.wfile.write(f"event: {event}\ndata: {payload}\n\n".encode("utf-8"))
        except (BrokenPipeError, ConnectionResetError):
            pass


with ThreadingHTTPServer(("127.0.0.1", 0), MockDeepSeek) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="StashCat-DeepSeek-Integration-") as temporary:
            root = Path(temporary)
            fixture = root / "Runtime"
            fixture.mkdir()
            runtime = args.bundled_runtime.resolve()
            (fixture / "bin").symlink_to(runtime / "bin", target_is_directory=True)
            (fixture / "node_modules").symlink_to(runtime / "node_modules", target_is_directory=True)
            (fixture / "chat.patch.yml").write_text(
                (runtime / "chat.patch.yml").read_text(encoding="utf-8")
                + f"\n- id: llm-deepseek\n  config:\n    baseURL: http://127.0.0.1:{server.server_port}\n",
                encoding="utf-8",
            )
            subprocess.run([args.test_binary.resolve(), fixture, root / "Transcript"], check=True, timeout=80)
    finally:
        server.shutdown()

assert len(turns) == 5, turns
assert cancelled_connections == [True], cancelled_connections
for path, key, request in turns:
    assert path == "/v1/messages", path
    assert key == "sk-stashcat-loopback-test", key
    assert request["model"] == "deepseek-flash", request
    assert not request.get("tools"), request
    assert all(field not in request for field in ("dsh_session_log", "dsh_plugins", "plugin_packages", "dsh_plugin_inventory")), request

first, second, after_stop = [json.dumps(turn[2], ensure_ascii=False) for turn in (turns[0], turns[1], turns[3])]
assert "第一次联调" in first and "关闭时不能发送" not in first
assert all(piece in second for piece in ("第一次联调", "本地联调成功。", "第二次联调"))
assert "中断后重试" in after_stop and "模拟中断" not in after_stop
print("PASS loopback API request, on-demand dispatch, transcript context, and tool-free model payload.")
