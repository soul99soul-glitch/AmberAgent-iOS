#!/usr/bin/env python3
"""Exercise the packaged MainKt against a loopback provider, with disposable pairing/data only."""
import argparse
import base64
import hashlib
import json
import os
import platform
from pathlib import Path
import socket
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
    req = Request(url, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        with urlopen(req, timeout=3) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, json.load(error)


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", type=Path, required=True)
    parser.add_argument("--java", type=Path, required=True)
    parser.add_argument("--configuration-client", type=Path, help="optional native JWE fixture executable")
    args = parser.parse_args()
    jar, java = args.jar.resolve(), args.java.resolve()
    worker_calls = []
    expected_key = ["local-http-provider-key"]

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert self.path == "/v1/chat/completions"
            assert self.headers["Authorization"] == "Bearer " + expected_key[0]
            text = json.dumps(body, ensure_ascii=False)
            if "受管 Worker" in text:
                worker_calls.append(1)
                output = '打包入口已完成本地 stub 任务\n```json\n{"package":true}\n```'
            elif "你是对话标签提取器" in text:
                output = '{"tags":[]}'
            else:
                output = "本地汇报完成"
            message = {"role": "assistant", "content": output}
            if "受管 Worker" in text:
                python = "/Library/Developer/CommandLineTools/usr/bin/python3" if platform.system() == "Darwin" else "/usr/bin/python3"
                script = "import csv,json\nr=list(csv.DictReader(open('data.csv')))\njson.dump({'sum':sum(int(x['value']) for x in r)},open('result.json','w'))"
                steps = [
                    ("host_info", {}),
                    ("workspace_file_write", {"path": "data.csv", "content": "name,value\na,2\nb,3\n"}),
                    ("workspace_file_write", {"path": "run.py", "content": script}),
                    ("process_run", {"argv": [python, "run.py"], "background": False}),
                    ("workspace_file_read", {"path": "result.json"}),
                    ("task_finish", {"outcome": "completed", "summary": output, "artifacts": ["result.json"]}),
                ]
                name, arguments = steps[len(worker_calls) - 1] if len(worker_calls) <= 6 else ("task_finish", {"outcome": "completed", "summary": "configuration reload verified"})
                message["tool_calls"] = [{"id": "call-" + str(len(worker_calls)), "type": "function", "function": {
                    "name": name, "arguments": json.dumps(arguments, ensure_ascii=False)}}]
            data = json.dumps({"id": "package-smoke", "object": "chat.completion", "choices": [
                {"index": 0, "finish_reason": "stop", "message": message}
            ]}, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    provider.daemon_threads = True
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="amber-native-package-") as temp:
            root, port = Path(temp), unused_port()
            data_dir = root / "data"
            env = {
                "HOME": "/Users/arquiel", "PATH": str(java.parent) + os.pathsep + "/usr/bin:/bin",
                "JAVA_HOME": str(java.parent.parent), "AMBER_MASTER_KEY": "local-package-smoke-master",
                "AMBER_MODEL_PROVIDER": "openai", "AMBER_MODEL_ID": "local-package-model",
                "AMBER_MODEL_BASE_URL": f"http://127.0.0.1:{provider.server_port}/v1",
                "AMBER_MODEL_API_KEY": "local-http-provider-key",
            }
            issued = subprocess.run([str(java), "-cp", str(jar), "app.amber.cloud.CliMainKt", "pair",
                "--data-dir", str(data_dir), "--addr", "127.0.0.1", "--port", str(port)],
                env=env, capture_output=True, text=True, check=True)
            link = next(line for line in issued.stdout.splitlines() if line.startswith("amber://"))
            encoded = parse_qs(urlparse(link).query)["p"][0]
            payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
            original = {name: hashlib.sha256((data_dir / name).read_bytes()).hexdigest()
                        for name in ("identity.json", "tls-identity.p12")}
            base_url = f"http://127.0.0.1:{port}"

            def stop():
                nonlocal process
                if process is not None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    process = None

            def boot():
                nonlocal process
                log = open(root / "daemon.log", "ab")
                process = subprocess.Popen([str(java), "-Xmx256m", "-jar", str(jar), "--data-dir",
                    str(data_dir), "--host", "127.0.0.1", "--port", str(port)], env=env, stdout=log, stderr=log)
                log.close()
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise AssertionError("packaged daemon exited before readiness")
                    try:
                        if request(base_url + "/v2/agents")[0] == 401:
                            return
                    except (URLError, TimeoutError):
                        pass
                    time.sleep(0.1)
                raise AssertionError("packaged daemon readiness timed out")

            try:
                boot()
                status, pair = request(base_url + "/v1/pair", {"secret": payload["s"], "platform": "ios", "deviceName": "local-package-test"})
                assert status == 200
                token = pair["token"]
                body = {"requestId": "package-retry-1", "text": "整理一项本地验收结果"}
                status, receipt = request(base_url + "/v2/work-items", body, token)
                assert status == 202
                work_id = receipt["workItem"]["id"]
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    status, detail = request(base_url + "/v2/work-items/" + work_id, token=token)
                    assert status == 200
                    assert detail["workItem"]["state"] not in ("FAILED", "CANCELLED")
                    if detail["workItem"]["state"] == "COMPLETED":
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError("packaged task did not complete")
                assert '{"package":true}' in detail["resultMarkdown"]
                assert detail["outcome"] == "completed"
                status, artifacts = request(base_url + "/v2/work-items/" + work_id + "/artifacts", token=token)
                assert status == 200
                result_file = next(item for item in artifacts if item["path"] == "result.json")
                status, csv_result = request(base_url + "/v2/work-items/" + work_id + "/artifacts/download?path=result.json", token=token)
                assert status == 200 and csv_result == {"sum": 5}
                config_envelope = None
                config_kid = None
                def finish_simple_task(request_id):
                    status, submitted = request(base_url + "/v2/work-items", {"requestId": request_id, "text": "验证后续任务配置"}, token)
                    assert status == 202
                    simple_id = submitted["workItem"]["id"]
                    until = time.monotonic() + 10
                    while time.monotonic() < until:
                        status, output = request(base_url + "/v2/work-items/" + simple_id, token=token)
                        assert status == 200
                        if output["workItem"]["state"] == "COMPLETED":
                            return
                        assert output["workItem"]["state"] not in ("FAILED", "CANCELLED")
                        time.sleep(0.05)
                    raise AssertionError("configuration follow-up task timed out")
                if args.configuration_client:
                    status, configuration = request(base_url + "/v2/configuration", token=token)
                    assert status == 200 and configuration["revision"] == 0
                    status, public_key = request(base_url + "/v2/configuration/import-key", token=token)
                    assert status == 200 and public_key["gatewayId"] == pair["gatewayId"]
                    config_kid = public_key["kid"]
                    clear = {"version": 1, "gatewayId": public_key["gatewayId"], "deviceId": public_key["deviceId"],
                        "requestId": "native-package-config", "expectedRevision": 0,
                        "issuedAt": public_key["serverTime"], "expiresAt": public_key["serverTime"] + 300,
                        "configuration": {"search": {"sources": ["bing", "duckduckgo", "exa"], "mode": "aggregate"}},
                        "credentials": {"modelApiKey": {"action": "replace", "value": "local-updated-provider-key"},
                            "exaApiKey": {"action": "replace", "value": "local-imported-exa-key"}}}
                    encrypted = subprocess.run([str(args.configuration_client.resolve())], input=json.dumps({"importKey": public_key, "payload": clear}).encode(), capture_output=True, check=True)
                    config_envelope = encrypted.stdout.decode().strip()
                    assert "local-updated-provider-key" not in config_envelope
                    status, changed = request(base_url + "/v2/configuration", {"jwe": config_envelope}, token)
                    assert status == 200 and changed["revision"] == 1
                    expected_key[0] = "local-updated-provider-key"
                    finish_simple_task("after-import")
                stop()
                if not args.configuration_client:
                    del env["AMBER_MODEL_API_KEY"]  # Original smoke uses only the encrypted vault on restart.
                # Configuration mode deliberately retains the obsolete startup env key to prove managed precedence.
                boot()
                if args.configuration_client:
                    status, config_recovered = request(base_url + "/v2/configuration", token=token)
                    assert status == 200 and config_recovered["revision"] == 1
                    status, repeated = request(base_url + "/v2/configuration", {"jwe": config_envelope}, token)
                    assert status == 200 and repeated["replayed"]
                    status, public_recovered = request(base_url + "/v2/configuration/import-key", token=token)
                    assert status == 200 and public_recovered["kid"] == config_kid
                    finish_simple_task("after-restart")
                status, recovered = request(base_url + "/v2/work-items/" + work_id, token=token)
                assert status == 200 and recovered["resultMarkdown"] == detail["resultMarkdown"]
                status, replay = request(base_url + "/v2/work-items", body, token)
                assert status == 200 and replay["replayed"] and replay["workItem"]["id"] == work_id
                assert len(worker_calls) == (8 if args.configuration_client else 6)
                assert all(hashlib.sha256((data_dir / name).read_bytes()).hexdigest() == sha for name, sha in original.items())
                assert "local-http-provider-key" not in (data_dir / "secrets.enc.json").read_text()
                print(json.dumps({"entrypoint": "packaged MainKt", "provider": "loopback OpenAI HTTP stub",
                    "state": "COMPLETED", "csvResult": csv_result, "artifactSha256": result_file["sha256"], "workerCalls": len(worker_calls), "restartResultAndTokenReused": True,
                    "identityAndCertificateUnchanged": True, "nativeEncryptedConfigurationApplied": bool(args.configuration_client), "credentialHotReloadAndStaleEnvPrecedence": bool(args.configuration_client), "realProviderCalled": False}, ensure_ascii=False))
            finally:
                stop()
    finally:
        provider.shutdown()
        provider.server_close()


if __name__ == "__main__":
    main()
