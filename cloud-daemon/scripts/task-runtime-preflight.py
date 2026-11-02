#!/usr/bin/env python3
"""Read-only Linux task-execution checks. No installs, sudo, data/key reads or network."""
import json
import os
import platform
import shutil
import subprocess

result = {"os": platform.system(), "arch": platform.machine(), "python": platform.python_version()}
result["tools"] = {name: shutil.which(name) for name in ("python3", "bwrap", "ffmpeg", "ffprobe", "yt-dlp")}
command = ["bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL"]
for path in ("/usr", "/bin", "/sbin", "/lib", "/lib64"):
    if os.path.exists(path):
        command += ["--ro-bind", path, path]
command += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--chdir", "/tmp", "--", "/usr/bin/python3", "-c", "print('isolated-python-ok')"]
if platform.system() == "Linux" and result["tools"]["bwrap"]:
    try:
        check = subprocess.run(command, capture_output=True, text=True, timeout=10, env={"PATH": "/usr/bin:/bin"})
        result["isolation"] = {"ok": check.returncode == 0, "exitCode": check.returncode, "stdout": check.stdout[:1000], "stderr": check.stderr[:2000]}
    except (OSError, subprocess.TimeoutExpired) as error:
        result["isolation"] = {"ok": False, "error": str(error)}
else:
    result["isolation"] = {"ok": False, "error": "Linux bubblewrap is required; no unconfined fallback"}
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(0 if result["isolation"]["ok"] else 1)
