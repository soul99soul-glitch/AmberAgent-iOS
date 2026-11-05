#!/usr/bin/env python3
"""Join Time Profiler sample weights to the captured replay's measured phases."""
import argparse
import collections
import datetime
import json
import xml.etree.ElementTree as ET
from pathlib import Path


def load_samples(path):
    root = ET.parse(path).getroot()
    ids = {node.get('id'): node for node in root.iter() if node.get('id')}

    def resolve(node):
        return ids[node.get('ref')] if node.get('ref') else node

    rows = []
    for row in root.iter('row'):
        fields = {node.tag: resolve(node) for node in row}
        if 'Main Thread' not in fields['thread'].get('fmt', ''):
            continue
        stack = fields.get('tagged-backtrace')
        frames = []
        if stack is not None:
            for node in stack.iter('frame'):
                frame = resolve(node)
                binary = frame.find('binary')
                frames.append((frame.get('name', '?'),
                               resolve(binary).get('name', '?') if binary is not None else '?'))
        # Preserve sentinel/no-stack weight in the denominator.
        rows.append((int(fields['sample-time'].text) / 1e9,
                     int(fields['weight'].text) / 1e6, frames))
    return rows


def summarize(rows, phase, trace_epoch):
    start = phase['startEpochSeconds'] - trace_epoch
    end = start + phase['wallSeconds']
    selected = [row for row in rows if start <= row[0] < end]
    total = sum(row[1] for row in selected)
    inclusive, leaves, app = (collections.Counter() for _ in range(3))
    for _, weight, frames in selected:
        for name in {name for name, _ in frames}:
            inclusive[name] += weight
        for name in {name for name, binary in frames
                     if binary in ('iosApp', 'iosApp.debug.dylib', 'iosAppTests')}:
            app[name] += weight
        leaves[frames[0][0] if frames else '<no stack>'] += weight

    def top(counter, limit):
        return [{'name': name, 'weightMs': value, 'percent': value * 100 / total}
                for name, value in counter.most_common(limit)] if total else []

    return {'phase': phase['phase'], 'rangeSeconds': [start, end],
            'sampleCount': len(selected), 'sampleWeightMs': total,
            'topInclusive': top(inclusive, 80), 'topLeaves': top(leaves, 30),
            'topAppInclusive': top(app, 50)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('time_profile_xml', type=Path)
    parser.add_argument('trace_toc_xml', type=Path)
    parser.add_argument('replay_metrics_json', type=Path)
    args = parser.parse_args()
    samples = load_samples(args.time_profile_xml)
    epoch = datetime.datetime.fromisoformat(
        ET.parse(args.trace_toc_xml).findtext('.//start-date')).timestamp()
    phases = json.loads(args.replay_metrics_json.read_text())
    print(json.dumps([summarize(samples, phase, epoch) for phase in phases],
                     ensure_ascii=False, indent=2))
