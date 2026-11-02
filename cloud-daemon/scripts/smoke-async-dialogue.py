#!/usr/bin/env python3
"""One packaged-Main scenario: long CSV A, independent B, followups, restart, physical stop.
Uses only disposable daemon data, fake provider credentials and synthetic task files.
"""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import platform
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


def request(url, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        with urlopen(Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers), timeout=10) as r:
            return r.status, json.load(r)
    except HTTPError as e:
        text = e.read().decode()
        return e.code, json.loads(text) if text else {}


def until(predicate, label, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.03)
    raise AssertionError("timed out: " + label)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", type=Path, required=True)
    parser.add_argument("--java", type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("native_smoke", Path(__file__).with_name("smoke-native-task.py"))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    python = "/Library/Developer/CommandLineTools/usr/bin/python3" if platform.system() == "Darwin" else "/usr/bin/python3"
    blocked, release, restarted = threading.Event(), threading.Event(), threading.Event()
    completion_consumed = threading.Event()
    provider_errors, observed = [], []
    long_script = """import csv,json,os,subprocess,sys,time
rows=list(csv.DictReader(open('data.csv')))
json.dump({'sum':sum(int(r['value']) for r in rows)},open('result.json','w'))
child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)'])
json.dump({'parent':os.getpid(),'child':child.pid},open('pids.json','w'))
while True:
 open('heartbeat.txt','w').write(str(time.monotonic()))
 time.sleep(.05)
"""
    calc = "import csv,json\nr=list(csv.DictReader(open('data.csv')))\nv=[int(x['value']) for x in r]\njson.dump({'sum':sum(v),'average':sum(v)/len(v)},open('result.json','w'))"

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.headers["Authorization"] == "Bearer fake-async-provider-key"
                messages = body["messages"]
                text = json.dumps(messages, ensure_ascii=False)
                tools = {x["function"]["name"]: x["function"] for x in body.get("tools", [])}
                calls = []
                output = "正在处理。"
                def tool(name, values):
                    calls.append({"id": "call-" + str(len(observed)) + "-" + str(len(calls)), "type": "function",
                                  "function": {"name": name, "arguments": json.dumps(values)}})
                history_calls = [c["function"] for m in messages for c in m.get("tool_calls", [])]
                def used(name, value):
                    return any(c["name"] == name and value in c["arguments"] for c in history_calls)
                if "受管 Worker" in text:
                    observed.append("worker")
                    if "任务事件 process" in text and "short-marker" in text:
                        completion_consumed.set()
                    if "RECOVERY_ADDITION" in text and not restarted.is_set():
                        blocked.set()
                        assert release.wait(30), "fixture gate expired"
                    if not used("workspace_file_write", "long.py"):
                        tool("workspace_file_write", {"path": "data.csv", "content": "name,value\na,2\nb,3\n"})
                        tool("workspace_file_write", {"path": "long.py", "content": long_script})
                        tool("workspace_file_write", {"path": "calc.py", "content": calc})
                    elif not used("process_run", "long.py"):
                        tool("process_run", {"argv": [python, "long.py"], "background": True, "timeoutSeconds": 120})
                    elif not used("process_run", "short-marker"):
                        tool("process_run", {"argv": [python, "-c", "print('short-marker')"], "background": True})
                    elif "ADD_AVERAGE" in text and not used("workspace_file_write", "addition.txt"):
                        tool("workspace_file_write", {"path": "addition.txt", "content": "ADD_AVERAGE consumed"})
                    elif "ADD_AVERAGE" in text and not used("process_run", "calc.py"):
                        tool("process_run", {"argv": [python, "calc.py"], "background": True})
                    elif "RECOVERY_ADDITION" in text and not used("workspace_file_write", "restored.txt"):
                        tool("workspace_file_write", {"path": "restored.txt", "content": "RECOVERY_ADDITION consumed"})
                    elif "RECOVERY_ADDITION" in text and restarted.is_set() and not used("process_run", "after-restart"):
                        # A deliberate new provider decision after reading the interruption event; never an automatic replay.
                        tool("process_run", {"argv": [python, "long.py", "after-restart"], "background": True, "timeoutSeconds": 120})
                    else:
                        output = "后台脚本仍在工作，等待补充或完成事件。"
                elif "你是对话标签提取器" in text:
                    output = '{"tags":[]}'
                elif "dispatch_work" in tools:
                    observed.append("router")
                    assert tools.get("dispatch_work", {}).get("parameters", {}).get("properties", {}).get("tasks"), "missing real Router schema"
                    last = str(messages[-1].get("content", ""))
                    if "QUESTION_B" in last:
                        output = "ANSWER_B: 2+2=4，与后台任务A独立。"
                    elif "LONG_CSV_A" in last:
                        output = "我会在后台处理CSV，你可以继续提问。"
                        tool("dispatch_work", {"tasks": [{"task_key": "csv-a", "title": "CSV A", "brief": "LONG_CSV_A：处理合成CSV，保留后台脚本以接受补充，显式停止才停止。"}]})
                    else:
                        output = "任务状态已归位。"
                else:
                    output = "main"  # Existing agent-selection/background classifiers use no Router tools.
                message = {"role": "assistant", "content": output}
                if calls:
                    message["tool_calls"] = calls
                data = json.dumps({"id": "async-fixture", "object": "chat.completion", "choices": [{"index": 0, "finish_reason": "tool_calls" if calls else "stop", "message": message}]}, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            except Exception as e:
                provider_errors.append(str(e))
                self.send_error(500)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    provider.daemon_threads = True
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    process = None
    metrics = {}
    try:
        with tempfile.TemporaryDirectory(prefix="amber-async-dialogue-") as temp:
            root, port = Path(temp), helper.unused_port()
            data_dir = root / "data"
            base = f"http://127.0.0.1:{port}"
            env = {"HOME": "/Users/arquiel", "PATH": str(args.java.resolve().parent) + ":/usr/bin:/bin",
                   "AMBER_MASTER_KEY": "fake-async-master", "AMBER_MODEL_PROVIDER": "openai", "AMBER_MODEL_ID": "async-fixture",
                   "AMBER_MODEL_API_KEY": "fake-async-provider-key", "AMBER_MODEL_BASE_URL": f"http://127.0.0.1:{provider.server_port}/v1"}
            issued = subprocess.run([str(args.java), "-cp", str(args.jar.resolve()), "app.amber.cloud.CliMainKt", "pair", "--data-dir", str(data_dir), "--addr", "127.0.0.1", "--port", str(port)], env=env, capture_output=True, text=True, check=True)
            link = next(x for x in issued.stdout.splitlines() if x.startswith("amber://"))
            encoded = parse_qs(urlparse(link).query)["p"][0]
            ticket = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
            def boot():
                nonlocal process
                with open(root / "daemon.log", "ab") as log:
                    process = subprocess.Popen([str(args.java), "-Xmx256m", "-jar", str(args.jar.resolve()), "--host", "127.0.0.1", "--port", str(port), "--data-dir", str(data_dir)], env=env, stdout=log, stderr=log)
                def ready():
                    if process.poll() is not None:
                        raise AssertionError("daemon exited: " + (root / "daemon.log").read_text()[-4000:])
                    try:
                        return request(base + "/v2/agents")[0] == 401
                    except (URLError, TimeoutError):
                        return False
                until(ready, "Main ready")
            def stop_daemon():
                nonlocal process
                if process is not None:
                    process.kill()
                    process.wait(timeout=10)
                    process = None
            def timed_post(path, body, name):
                start = time.monotonic()
                status, receipt = request(base + path, body, token)
                metrics[name] = round((time.monotonic() - start) * 1000, 2)
                return status, receipt
            def receipt(request_id):
                return request(base + "/v2/dialogue/receipts/" + request_id, token=token)[1]
            def all_events():
                return request(base + "/v2/dialogue/events?after=0&limit=100", token=token)[1]["items"]
            def work_record():
                with sqlite3.connect(data_dir / "orchestration.db") as db:
                    records = [json.loads(r[0]) for r in db.execute("SELECT record_json FROM work_items")]
                assert len(records) == 1, "duplicate native Worker"
                return records[0]
            def alive(pid):
                result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
                return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")
            tracked = {}
            def signature(pid):
                return subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
            def track(pids):
                for pid in pids.values():
                    tracked[pid] = signature(pid)
            try:
                boot()
                assert request(base + "/v2/dialogue/messages", {"requestId": "x", "text": "x"})[0] == 401
                status, paired = request(base + "/v1/pair", {"secret": ticket["s"], "platform": "ios", "deviceName": "async-fixture"})
                assert status == 200
                token = paired["token"]
                body_a = {"requestId": "native-A", "text": "LONG_CSV_A，请后台处理合成CSV。"}
                status, accepted = timed_post("/v2/dialogue/messages", body_a, "A_receive_ack_ms")
                assert status == 202, (status, accepted)
                main_receipt = until(lambda: (r if (r := receipt("native-A"))["workItemIds"] else None), "Router dispatch A")
                work_id = main_receipt["workItemIds"][0]
                initial = work_record()
                workspace = data_dir / "task-workspaces" / work_id.split(":")[1]
                pids = until(lambda: read_json(workspace / "pids.json"), "real long parent + child")
                track(pids)
                assert all(alive(x) for x in pids.values())
                until(completion_consumed.is_set, "background completion consumed by a woken Worker")
                b_start = time.monotonic()
                assert timed_post("/v2/dialogue/messages", {"requestId": "native-B", "text": "QUESTION_B：2+2等于多少？"}, "B_receive_ack_ms")[0] == 202
                until(lambda: any(x["kind"] == "assistant_reply" and "ANSWER_B" in x["text"] for x in all_events()), "independent semantic answer B")
                metrics["B_semantic_response_ms"] = round((time.monotonic() - b_start) * 1000, 2)
                assert all(alive(x) for x in pids.values()), "B waited for long A"
                add_start = time.monotonic()
                addition = {"requestId": "add-average", "text": "ADD_AVERAGE：原任务追加平均值，继续保留后台任务。"}
                assert timed_post(f"/v2/work-items/{work_id}/inputs", addition, "followup_receive_ack_ms")[0] == 202
                until(lambda: receipt("add-average")["state"] == "consumed", "followup model consumption")
                metrics["followup_consumption_ms"] = round((time.monotonic() - add_start) * 1000, 2)
                until(lambda: read_json(workspace / "result.json").get("average") == 2.5, "real CSV correction")
                assert request(base + f"/v2/work-items/{work_id}/inputs", addition, token)[1]["replayed"]
                recovery = {"requestId": "durable-add", "text": "RECOVERY_ADDITION：保存这条补充，重启后继续同任务。"}
                assert timed_post(f"/v2/work-items/{work_id}/inputs", recovery, "durable_followup_ack_ms")[0] == 202
                assert blocked.wait(10), "provider did not reach unconsumed input gate"
                assert receipt("durable-add")["state"] == "received"
                stop_daemon()
                restarted.set()
                release.set()
                boot()
                replay = request(base + f"/v2/work-items/{work_id}/inputs", recovery, token)
                assert replay[0] == 200 and replay[1]["replayed"]
                assert request(base + "/v2/dialogue/messages", body_a, token)[1]["eventId"] == accepted["eventId"]
                until(lambda: receipt("durable-add")["state"] == "consumed", "durable followup consumed after restart")
                until(lambda: (workspace / "restored.txt").exists(), "restored model action")
                until(lambda: not any(alive(x) for x in pids.values()), "old process tree cleared on recovery")
                new_pids = until(lambda: (x if (x := read_json(workspace / "pids.json")) and x != pids and all(alive(i) for i in x.values()) else None), "provider-directed continuation process")
                track(new_pids)
                final_record = work_record()
                assert final_record["workItemId"] == initial["workItemId"] and final_record["workerSessionId"] == initial["workerSessionId"]
                assert request(base + "/v2/dialogue/messages", dict(body_a, text="different"), token)[0] == 409
                stop_start = time.monotonic()
                status, stopped = timed_post(f"/v2/work-items/{work_id}/stop", {"requestId": "stop-A"}, "stop_http_ms")
                assert status == 200 and stopped["state"] == "consumed", (status, stopped)
                until(lambda: not any(alive(x) for x in new_pids.values()), "physical root and descendant stop", 5)
                metrics["stop_physical_tree_ms"] = round((time.monotonic() - stop_start) * 1000, 2)
                assert request(base + f"/v2/work-items/{work_id}/stop", {"requestId": "stop-A"}, token)[1]["replayed"]
                result = request(base + f"/v2/work-items/{work_id}", token=token)[1]
                assert result["workItem"]["state"] == "CANCELLED" and result["outcome"] == "cancelled"
                assert request(base + f"/v2/work-items/{work_id}/inputs", {"requestId": "too-late", "text": "late"}, token)[0] == 409
                assert request(base + f"/v2/work-items/{work_id}/artifacts", token=token)[0] == 200
                events = all_events()
                assert len([x for x in events if x["id"] == accepted["eventId"]]) == 1
                assert len([x for x in events if x["kind"] == "task_result" and x["workItemId"] == work_id and x["outcome"] == "cancelled"]) == 1
                assert any(x["kind"] == "assistant_reply" and "ANSWER_B" in x["text"] and x["topicId"] != accepted["topicId"] for x in events)
                cursor = max(x["seq"] for x in events)
                assert request(base + f"/v2/dialogue/events?after={cursor}", token=token)[1]["items"] == []
                assert request(base + "/v2/configuration", token=token)[0] == 200
                assert not provider_errors, provider_errors
                print(json.dumps({"entrypoint": "packaged Main HTTP", "provider": "controlled loopback OpenAI", "realCsvAndChildProcess": True,
                    "BAnsweredWhileAAlive": True, "followupConsumedAndAverage": 2.5, "restartUnconsumedInputRecovered": True,
                    "sameWorkItemAndSession": True, "physicalProcessTreeStopped": True, "terminalResultAndBOnTimeline": True,
                    "requestIdReplayNoDuplicateWorker": True, "backgroundCompletionWokeWorker": True, "metrics": metrics,
                    "realProviderCalled": False, "linuxIsolationValidated": platform.system() == "Linux"}, ensure_ascii=False))
            except Exception:
                print("daemon diagnostic tail (disposable fixture only):", (root / "daemon.log").read_text()[-5000:])
                raise
            finally:
                release.set()
                stop_daemon()
                # Guard cleanup only for matching processes explicitly recorded by this disposable fixture.
                for pid, started in tracked.items():
                    try:
                        if started and signature(pid) == started and alive(pid):
                            os.kill(pid, 9)
                    except (OSError, ValueError):
                        pass
    finally:
        provider.shutdown()
        provider.server_close()


if __name__ == "__main__":
    main()
