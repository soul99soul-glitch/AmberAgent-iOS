#!/usr/bin/env python3
"""Summarize the captured three-round foreground-completion replay."""
import json
import math
import sys
from pathlib import Path


def summarize(round_data):
    frames = sorted(
        frame["mainCPUMs"] for frame in round_data["frames"]
        if not frame["partialStart"] and not frame["partialEnd"]
    )
    result = {key: value for key, value in round_data.items() if key != "frames"}
    result["completeFrameCount"] = len(frames)
    for percentile in (50, 95):
        result[f"completeFrameMainCPUP{percentile}Ms"] = (
            frames[math.ceil(len(frames) * percentile / 100) - 1] if frames else None
        )
    result["completeFrameMainCPUMaxMs"] = max(frames, default=None)
    result["frameGapsOver50msPerSecond"] = (
        result["frameGapsOver50ms"] / result["endToEndSeconds"]
    )
    for key, value in round_data.items():
        if key.endswith("Bytes"):
            result[key.removesuffix("Bytes") + "MiB"] = value / 1048576
    result["turns"] = [
        dict(turn, sourceClosedToLastVisibleSeconds=(
            turn["lastTextVisibleSeconds"] - turn["sourceClosedSeconds"]
            if turn["lastTextVisibleSeconds"] >= 0 else None
        )) for turn in round_data["turns"]
    ]
    return result


if __name__ == "__main__":
    rounds = json.loads(Path(sys.argv[1]).read_text())
    print(json.dumps([summarize(row) for row in rounds], indent=2, sort_keys=True))
