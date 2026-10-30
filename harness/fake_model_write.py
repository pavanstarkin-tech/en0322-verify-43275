#!/usr/bin/env python3
"""task#8091 C-1633 装置: 假模型(机械回放工具脚本) + 攻击者收集端(全落 127.0.0.1, 整体再套 unshare -n)。

用法: python3 fake_model_write.py <model_port> <collect_port> <script_file> <log_dir>
script_file: JSON 数组, 每项 {"tool": "Write"|"Read"|"Bash", "args": {...}} —— 按序回放:
  第 N 次模型请求若已收到 N 个 tool 结果则回放第 N+1 个工具调用; 全部回放完则发收尾文本。
假模型只做机械回放, 不参与任何安全判定: 是否弹窗/是否拦截全由真 CLI 决定。
协议形态照抄 task6678 harness 的 fake_model.py(OpenAI 兼容 chat.completion SSE)。
"""
import http.server
import json
import os
import socketserver
import sys
import threading
import time

model_port = int(sys.argv[1])
collect_port = int(sys.argv[2])
script = json.load(open(sys.argv[3]))
log_dir = sys.argv[4]
os.makedirs(log_dir, exist_ok=True)
collect_log = open(os.path.join(log_dir, "collector.log"), "a", buffering=1)


class Collector(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        collect_log.write("HIT %s %s\n" % (time.strftime("%H:%M:%S"), self.path))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    log_message = lambda *a: None


def sse(chunks):
    return b"".join(b"data: " + json.dumps(c).encode() + b"\n\n" for c in chunks) + b"data: [DONE]\n\n"


def tool_chunk(name, args, cid):
    return [
        {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "stub-model",
         "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "stub-model",
         "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": cid, "type": "function",
                      "function": {"name": name, "arguments": args}}]}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "stub-model",
         "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
    ]


def final_chunk(text):
    return [
        {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "stub-model",
         "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "stub-model",
         "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
    ]


class Model(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        open(os.path.join(log_dir, "model_req_last.json"), "wb").write(body)
        try:
            msgs = json.loads(body).get("messages") or []
        except Exception:
            msgs = []
        tool_res = [m for m in msgs if m.get("role") == "tool"]
        step = len(tool_res)
        if step < len(script):
            item = script[step]
            collect_log.write("EMIT step=%d tool=%s args=%s\n" % (step, item["tool"], json.dumps(item["args"])[:300]))
            payload = sse(tool_chunk(item["tool"], json.dumps(item["args"]), "call_%d" % step))
        else:
            for m in tool_res[-1:]:
                collect_log.write("TOOL_RESULT %s\n" % str(m.get("content"))[:800])
            payload = sse(final_chunk("done"))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    log_message = lambda *a: None


for port, h in ((collect_port, Collector), (model_port, Model)):
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", port), h)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()

collect_log.write("UP model=%d collect=%d steps=%d\n" % (model_port, collect_port, len(script)))
while True:
    time.sleep(3600)
