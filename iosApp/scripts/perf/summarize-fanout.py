#!/usr/bin/env python3
"""Summarize local capture counters without including captured message content."""
import argparse
import json
import math
import statistics
from pathlib import Path


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(event):
    # First display-link delivery is a partial interval starting at the event.
    frames = [frame for frame in event["frames"]
              if not frame.get("partialStart") and not frame.get("partialEnd")]
    if event["frames"] and "partialStart" not in event["frames"][0]:
        frames = event["frames"][1:]
    cpu = [frame["mainCPUMs"] for frame in frames]
    wall = [frame["wallMs"] for frame in frames]
    return {
        **{key: value for key, value in event.items() if key != "frames"},
        "completeFrameIntervals": len(frames),
        "maxCPUIntervalIncludingBoundariesMs": max((f["mainCPUMs"] for f in event["frames"]), default=None),
        "maxWallIntervalIncludingBoundariesMs": max((f["wallMs"] for f in event["frames"]), default=None),
        "frameMainCPUMedianMs": statistics.median(cpu) if cpu else None,
        "frameMainCPUP95Ms": percentile(cpu, 0.95),
        "frameMainCPUMaxMs": max(cpu) if cpu else None,
        "frameDeliveryGapMaxMs": max(wall) if wall else None,
        "frameDeliveryGapsOver50ms": sum(value > 50 for value in wall),
        "frameDeliveryGapsOver100ms": sum(value > 100 for value in wall),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    print(json.dumps([summarize(event) for event in json.loads(args.input.read_text())],
                     ensure_ascii=False, indent=2))
