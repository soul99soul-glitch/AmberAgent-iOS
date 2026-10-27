import json
import os
import sys
import time
import signal
import subprocess

# Test server fixture: real newline-delimited JSON-RPC over an actual child process.
if os.environ.get("AMBER_MCP_FIXTURE_STARTS"):
    with open(os.environ["AMBER_MCP_FIXTURE_STARTS"], "a") as starts:
        starts.write(str(os.getpid()) + "\n")
descendant = None
if os.environ.get("AMBER_MCP_FIXTURE_IGNORE_TERM"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    descendant = subprocess.Popen([sys.executable, "-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)"])
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "Amber test fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": name, "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}} for name in ["echo", "wait", "exit"]]}
    elif method == "tools/call":
        params = request.get("params", {})
        if params.get("name") == "wait":
            with open(os.environ["AMBER_MCP_FIXTURE_MARKER"], "w") as marker:
                marker.write("dispatched")
            time.sleep(30)
        text = params.get("arguments", {}).get("text", "")
        result = {"content": [{"type": "text", "text": text + " " + os.environ.get("AMBER_MCP_FIXTURE_VALUE", "")}], "structuredContent": {"pid": os.getpid(), "childPID": descendant.pid if descendant else None}}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    if method == "tools/call" and request.get("params", {}).get("name") == "exit":
        break
if os.environ.get("AMBER_MCP_FIXTURE_IGNORE_TERM"):
    time.sleep(60)
