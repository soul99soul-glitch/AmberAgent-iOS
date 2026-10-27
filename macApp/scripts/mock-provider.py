#!/usr/bin/env python3
"""Loopback-only OpenAI/Anthropic fixture used by the Mac KMP integration tests."""

import argparse
import json
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class ProviderHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            self.send_error(400)
            return
        is_claude = self.path.rstrip("/").endswith("/messages")
        is_openai = self.path.rstrip("/").endswith("/chat/completions")
        if not (is_claude or is_openai) or not body.get("stream") or not body.get("messages"):
            self.send_error(400)
            return
        key = self.headers.get("x-api-key", "") if is_claude else self.headers.get("Authorization", "")
        if "amber-mac-integration-only" not in key or body.get("model") == "mock-error":
            payload = json.dumps({"error": {"message": "Rejected credential: " + key}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            if is_claude:
                self.claude(body)
            else:
                self.openai(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, payload, name=None):
        prefix = ("event: " + name + "\n") if name else ""
        data = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
        self.wfile.write((prefix + "data: " + data + "\n\n").encode())
        self.wfile.flush()

    def openai(self, body):
        def chunk(delta, finish=None, usage=None):
            result = {"id": "chatcmpl-mac-test", "object": "chat.completion.chunk", "created": 1,
                      "model": body["model"], "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if usage is not None:
                result["usage"] = usage
            return result
        if body["model"] == "mock-agent-scope":
            tool_names = {
                tool.get("function", {}).get("name")
                for tool in body.get("tools", [])
                if isinstance(tool, dict)
            }
            allowed = {"tool_search", "subagent_dispatch", "list_agents", "interrupt_agent"}
            has_tool_output = any(
                isinstance(message, dict) and message.get("role") == "tool"
                for message in body.get("messages", [])
            )
            if tool_names - allowed:
                self.event(chunk({"role": "assistant", "content": "tool-scope-leak"}, "stop"))
            elif has_tool_output:
                self.event(chunk({"role": "assistant", "content": "scope-safe"}, "stop"))
            else:
                self.event(chunk({
                    "role": "assistant",
                    "tool_calls": [{
                        "index": 0,
                        "id": "scope-hidden-call",
                        "type": "function",
                        "function": {
                            "name": "workspace_file_write",
                            "arguments": '{"path":"forbidden.txt","content":"must-not-write","overwrite":true}',
                        },
                    }],
                }, "tool_calls"))
            self.event("[DONE]")
            return
        if body["model"] == "mock-scheduled-write":
            # One workspace write, then echo the tool result so tests can tell executed / denied apart.
            tool_outputs = [
                message.get("content") for message in body.get("messages", [])
                if isinstance(message, dict) and message.get("role") == "tool"
            ]
            if tool_outputs:
                text = tool_outputs[-1] if isinstance(tool_outputs[-1], str) else json.dumps(tool_outputs[-1], ensure_ascii=False)
                self.event(chunk({"role": "assistant", "content": "scheduled-result:" + text[:300]}, "stop"))
            else:
                self.event(chunk({
                    "role": "assistant",
                    "tool_calls": [{
                        "index": 0,
                        "id": "scheduled-write-call",
                        "type": "function",
                        "function": {
                            "name": "workspace_file_write",
                            "arguments": '{"path":"summary.txt","content":"scheduled","overwrite":true}',
                        },
                    }],
                }, "tool_calls"))
            self.event("[DONE]")
            return
        if body["model"].startswith("mock-burst-"):
            try:
                count = int(body["model"].removeprefix("mock-burst-"))
            except ValueError:
                self.send_error(400)
                return
            self.event(chunk({"role": "assistant", "content": ""}))
            for _ in range(count):
                self.event(chunk({"content": "x"}))
            self.event(chunk({}, "stop", usage={
                "prompt_tokens": 11,
                "completion_tokens": count,
                "total_tokens": count + 11,
            }))
            self.event("[DONE]")
            return
        if body["model"] == "mock-stream-error":
            self.event(chunk({"role": "assistant", "content": "partial"}))
            self.event({"error": {"message": "fixture stream error"}})
            return
        self.event(chunk({"role": "assistant", "content": ""}))
        self.event(chunk({"reasoning_content": "先确认顺序。"}))
        pieces = ["partial", " should not arrive"] if body["model"] == "mock-cancel" else ["你", "好", "，Amber"]
        for index, piece in enumerate(pieces):
            self.event(chunk({"content": piece}))
            time.sleep(3 if body["model"] == "mock-cancel" and index == 0 else 0.03)
        self.event(chunk({}, "stop"))
        self.event("[DONE]")

    def claude(self, body):
        self.event({"type": "message_start", "message": {"id": "msg_mac_test", "type": "message",
                    "role": "assistant", "model": body["model"], "content": [],
                    "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 4, "output_tokens": 0}}}, "message_start")
        self.event({"type": "content_block_start", "index": 0,
                    "content_block": {"type": "text", "text": ""}}, "content_block_start")
        for piece in ["你", "好", "，Amber"]:
            self.event({"type": "content_block_delta", "index": 0,
                        "delta": {"type": "text_delta", "text": piece}}, "content_block_delta")
            time.sleep(0.03)
        self.event({"type": "content_block_stop", "index": 0}, "content_block_stop")
        self.event({"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": 6}}, "message_delta")
        self.event({"type": "message_stop"}, "message_stop")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), ProviderHandler)
    server.daemon_threads = True
    Path(args.ready_file).write_text(str(server.server_port))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
