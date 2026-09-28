#!/usr/bin/env python3
"""analyze.py — 解析 Time Profiler .trace，定位“发送气泡上屏卡顿”问题。

只用标准库。所有子命令都基于 `xcrun xctrace export` 的 XML 输出。

主线程样本会缓存为 <trace路径>.mainthread.pkl（与 trace 同目录），只在
第一次访问某个 trace 时导出+解析一次，之后的子命令自动复用缓存，不再重新
调用 xctrace export（除非显式跑 `export` 子命令重建缓存）。

子命令：
  export    <trace>                              导出并解析，重建主线程样本缓存
  hangs     <trace>                               列出 potential-hangs 表
  anchors   <trace> <函数子串>                     按函数子串聚类找锚点时间
  timeline  <trace> <锚点秒> [--span 1.2] [--bucket 25] [--label sub=LABEL ...]
  top       <trace> <起秒> <止秒> [-n 25]           区间内 app 函数 top N
  ab        <旧trace> <旧锚点秒> <新trace> <新锚点秒> [--span 1.0] [--keys k1,k2,...]
  gaps      <trace> <锚点函数子串> <锚点秒> [--span 0.4]

用法示例见同目录 README.md。
"""
import argparse
import collections
import os
import pickle
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

TIME_PROFILE_XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
HANGS_XPATH = '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]'

# timeline 默认标签集，沿用排查“发送气泡卡顿”时的锚点函数分类。
# 越靠前优先级越高（第一个匹配到的子串生效）。
DEFAULT_TIMELINE_LABELS = [
    ('prepareUploadMessages', 'PREP'),
    ('CA::Transaction::commit', 'COMMIT'),
    ('inputText.setter', 'flush'),
    ('appendUserMessage', 'append'),
    ('sendComposerMessage', 'send'),
    ('NativeTimelineScrollDriver', 'scrollDriver'),
    ('OrbCanvasView', 'orb'),
    ('NativeChatTimelineView.body', 'timelineBody'),
    ('ChatView.body', 'chatBody'),
    ('ConversationsView', 'home'),
    ('ConversationSummaryRow', 'home'),
    ('AG::', 'AG'),
]

# ab 子命令默认对比的关键函数集合。
DEFAULT_AB_KEYS = [
    'sendComposerMessage',
    'appendUserMessage',
    'inputText.setter',
    'prepareUploadMessages',
    'CA::Transaction::commit',
    'NativeChatTimelineView.body',
    'ChatView.body.getter',
    'ConversationsView.body',
    'ConversationSummaryRow',
    'AmberMarkdownView',
    'AG::',
]


# ---------------------------------------------------------------------------
# xctrace 导出 + XML 解析
# ---------------------------------------------------------------------------

def _pkl_path(trace):
    return trace.rstrip('/') + '.mainthread.pkl'


def _xctrace_export(trace, xpath, out_xml):
    cmd = ['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', xpath, '--output', out_xml]
    subprocess.run(cmd, check=True)


def _resolve_ids(root):
    ids = {}
    for e in root.iter():
        i = e.get('id')
        if i:
            ids[i] = e

    def R(e):
        r = e.get('ref')
        return ids[r] if r else e

    return R


def _parse_time_profile_xml(xml_path):
    """只保留 Main Thread 样本：list[(sample_time_秒, [(frame_name, binary_name), ...])]，
    frames 按 leaf-first（最内层在前）排列，与 xctrace 原始顺序一致。"""
    root = ET.parse(xml_path).getroot()
    R = _resolve_ids(root)
    rows = []
    for row in root.iter('row'):
        t = None
        thr = None
        bt = None
        for c in row:
            c2 = R(c)
            if c.tag == 'sample-time':
                t = int(c2.text) / 1e9
            elif c.tag == 'thread':
                thr = c2
            elif c.tag in ('backtrace', 'tagged-backtrace'):
                bt = c2
        if t is None or bt is None or thr is None:
            continue
        if 'Main Thread' not in (thr.get('fmt') or ''):
            continue
        if bt.tag == 'tagged-backtrace':
            b = bt.find('backtrace')
            bt = R(b) if b is not None else bt
        frames = []
        for f in bt.iter('frame'):
            f = R(f)
            b = f.find('binary')
            frames.append((f.get('name') or '?', R(b).get('name') if b is not None else '?'))
        rows.append((t, frames))
    rows.sort(key=lambda r: r[0])
    return rows


def _parse_hangs_xml(xml_path):
    root = ET.parse(xml_path).getroot()
    R = _resolve_ids(root)
    out = []
    for row in root.iter('row'):
        start = None
        dur = None
        htype = None
        for c in row:
            c2 = R(c)
            if c.tag == 'start-time':
                start = int(c2.text) / 1e9
            elif c.tag == 'duration':
                dur = int(c2.text) / 1e9
            elif c.tag == 'hang-type':
                htype = c2.get('fmt') or c2.text
        if start is None:
            continue
        out.append((start, dur, htype))
    out.sort(key=lambda r: r[0])
    return out


def load_mainthread(trace, rebuild=False):
    """加载 trace 的主线程样本缓存；缺失或 rebuild=True 时重新导出+解析。"""
    cache = _pkl_path(trace)
    if not rebuild and os.path.exists(cache):
        with open(cache, 'rb') as f:
            return pickle.load(f)
    fd, xml_path = tempfile.mkstemp(prefix='amber-perf-tp-', suffix='.xml')
    os.close(fd)
    try:
        print(f'[analyze] 导出 time-profile XML: {trace}', file=sys.stderr)
        _xctrace_export(trace, TIME_PROFILE_XPATH, xml_path)
        print('[analyze] 解析主线程样本...', file=sys.stderr)
        rows = _parse_time_profile_xml(xml_path)
    finally:
        if os.path.exists(xml_path):
            os.remove(xml_path)
    with open(cache, 'wb') as f:
        pickle.dump(rows, f)
    print(f'[analyze] 主线程样本 {len(rows)} 条，缓存于 {cache}', file=sys.stderr)
    return rows


def is_app_binary(binary_name):
    """判断是否是 app 自身的二进制（debug.dylib 或 iosApp 可执行文件）。"""
    if not binary_name:
        return False
    return 'debug.dylib' in binary_name or binary_name == 'iosApp' or binary_name.startswith('iosApp.')


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_export(args):
    rows = load_mainthread(args.trace, rebuild=True)
    if not rows:
        print('（无主线程样本）')
        return
    print(f'主线程样本数: {len(rows)}')
    print(f'时间范围: {rows[0][0]:.3f}s - {rows[-1][0]:.3f}s')


def cmd_hangs(args):
    fd, xml_path = tempfile.mkstemp(prefix='amber-perf-hangs-', suffix='.xml')
    os.close(fd)
    try:
        _xctrace_export(args.trace, HANGS_XPATH, xml_path)
        hangs = _parse_hangs_xml(xml_path)
    finally:
        if os.path.exists(xml_path):
            os.remove(xml_path)
    if not hangs:
        print('（未检测到 potential hangs）')
        return
    print(f'{"起点(s)":>10}  {"时长(ms)":>9}  类型')
    for start, dur, htype in hangs:
        dur_ms = dur * 1000 if dur is not None else float('nan')
        print(f'{start:10.3f}  {dur_ms:9.1f}  {htype}')


def cmd_anchors(args):
    rows = load_mainthread(args.trace)
    ts = sorted(t for t, fr in rows if any(args.substr in n for n, b in fr))
    if not ts:
        print(f'（未找到包含 "{args.substr}" 的样本）')
        return
    clusters = []
    for t in ts:
        if clusters and t - clusters[-1][-1] < args.gap:
            clusters[-1].append(t)
        else:
            clusters.append([t])
    print(f'{"起点(s)":>10}  {"止点(s)":>10}  样本数')
    for c in clusters:
        print(f'{c[0]:10.3f}  {c[-1]:10.3f}  {len(c):6d}')


def _label_for(frames, labels):
    names = [n for n, b in frames]
    for sub, lab in labels:
        if any(sub in n for n in names):
            return lab
    return 'x'


def cmd_timeline(args):
    rows = load_mainthread(args.trace)
    labels = list(args.label_pairs) + DEFAULT_TIMELINE_LABELS
    s = args.anchor
    bucket_s = args.bucket / 1000.0
    buckets = collections.OrderedDict()
    for t, fr in rows:
        if s - 0.03 <= t <= s + args.span:
            k = int(round((t - s) * 1000)) // args.bucket * args.bucket
            buckets.setdefault(k, collections.Counter())[_label_for(fr, labels)] += 1
    if not buckets:
        print('（该窗口内无主线程样本）')
        return
    print(f'{"偏移(ms)":>9}  {"样本数":>5}  标签(前4)')
    for k in sorted(buckets):
        c = buckets[k]
        n = sum(c.values())
        print(f'{k:9d}  {n:5d}  {dict(c.most_common(4))}')


def cmd_top(args):
    rows = load_mainthread(args.trace)
    sel = [fr for t, fr in rows if args.start <= t <= args.stop]
    incl = collections.Counter()
    leaf = collections.Counter()
    for fr in sel:
        seen = set()
        for name, b in fr:
            if is_app_binary(b) and not name.startswith('0x') and name not in seen:
                seen.add(name)
                incl[name] += 1
        for name, b in fr:
            if is_app_binary(b) and not name.startswith('0x'):
                leaf[name] += 1
                break
    print(f'== [{args.start}, {args.stop}] 样本数={len(sel)}')
    print(f'-- 包含样本 top {args.n}（一个样本里同名函数只计一次）')
    for k, v in incl.most_common(args.n):
        print(f'{v:5d}  {k[:110]}')
    print(f'-- 最内层 app 帧 top {args.n}')
    for k, v in leaf.most_common(args.n):
        print(f'{v:5d}  {k[:110]}')


def cmd_ab(args):
    keys = args.keys.split(',') if args.keys else DEFAULT_AB_KEYS
    old_rows = load_mainthread(args.old_trace)
    new_rows = load_mainthread(args.new_trace)

    def window(rows, anchor):
        return [fr for t, fr in rows if anchor - 0.005 <= t <= anchor + args.span]

    old_sel = window(old_rows, args.old_anchor)
    new_sel = window(new_rows, args.new_anchor)

    def count_keys(sel):
        c = collections.Counter()
        for fr in sel:
            joined = '|'.join(n for n, b in fr)
            for k in keys:
                if k in joined:
                    c[k] += 1
        return c

    oc = count_keys(old_sel)
    nc = count_keys(new_sel)
    print(f'{"函数关键字":38s}{"旧":>9s}{"新":>9s}')
    print(f'{"窗口总样本数":38s}{len(old_sel):9d}{len(new_sel):9d}')
    for k in keys:
        print(f'{k:38s}{oc[k]:9d}{nc[k]:9d}')


def cmd_gaps(args):
    rows = load_mainthread(args.trace)
    s = args.anchor
    sel = sorted([(t, fr) for t, fr in rows if s - 0.03 <= t <= s + args.span])
    prev = None
    print(f'{"偏移(ms)":>8}  {"间隔(ms)":>8}  最内层帧 / app 帧链')
    hit = 0
    for t, fr in sel:
        names = [n for n, b in fr]
        idxs = [i for i, n in enumerate(names) if args.substr in n]
        if not idxs:
            continue
        hit += 1
        gap_ms = (t - prev) * 1000 if prev is not None else 0.0
        prev = t
        idx = idxs[0]
        app_frames = [n for n, b in fr[:idx] if is_app_binary(b)][:5]
        marker = '  <== 间隔>3ms，疑似阻塞' if gap_ms > 3.0 else ''
        leaf = names[0][:45] if names else '?'
        chain = ' <- '.join(a[:55] for a in app_frames)
        print(f'{(t - s) * 1000:8.1f}  {gap_ms:8.2f}  leaf={leaf} | app: {chain}{marker}')
    if hit == 0:
        print(f'（窗口内未找到包含 "{args.substr}" 的样本）')


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _label_pair(s):
    if '=' not in s:
        raise argparse.ArgumentTypeError(f'--label 需要 sub=LABEL 形式: {s!r}')
    sub, lab = s.split('=', 1)
    return (sub, lab)


def main():
    p = argparse.ArgumentParser(description='解析 Time Profiler trace，排查发送气泡上屏卡顿')
    sub = p.add_subparsers(dest='cmd', required=True)

    sp = sub.add_parser('export', help='导出并解析，重建主线程样本缓存')
    sp.add_argument('trace')
    sp.set_defaults(func=cmd_export)

    sp = sub.add_parser('hangs', help='列出 potential-hangs 表')
    sp.add_argument('trace')
    sp.set_defaults(func=cmd_hangs)

    sp = sub.add_parser('anchors', help='按函数子串聚类找锚点时间')
    sp.add_argument('trace')
    sp.add_argument('substr')
    sp.add_argument('--gap', type=float, default=1.0, help='合并间隔阈值(秒)，默认1.0')
    sp.set_defaults(func=cmd_anchors)

    sp = sub.add_parser('timeline', help='以锚点为0打印主线程时间线')
    sp.add_argument('trace')
    sp.add_argument('anchor', type=float)
    sp.add_argument('--span', type=float, default=1.2)
    sp.add_argument('--bucket', type=int, default=25, help='分格毫秒数，默认25')
    sp.add_argument('--label', dest='label_pairs', type=_label_pair, action='append', default=[],
                     help='sub=LABEL，可重复；优先于默认标签集')
    sp.set_defaults(func=cmd_timeline)

    sp = sub.add_parser('top', help='区间内 app 函数样本 top N')
    sp.add_argument('trace')
    sp.add_argument('start', type=float)
    sp.add_argument('stop', type=float)
    sp.add_argument('-n', type=int, default=25)
    sp.set_defaults(func=cmd_top)

    sp = sub.add_parser('ab', help='新旧 trace 同窗口关键函数样本对比')
    sp.add_argument('old_trace')
    sp.add_argument('old_anchor', type=float)
    sp.add_argument('new_trace')
    sp.add_argument('new_anchor', type=float)
    sp.add_argument('--span', type=float, default=1.0)
    sp.add_argument('--keys', type=str, default=None, help='逗号分隔的关键字列表，默认用内置集合')
    sp.set_defaults(func=cmd_ab)

    sp = sub.add_parser('gaps', help='锚点函数内样本间隔检测（找主线程阻塞）')
    sp.add_argument('trace')
    sp.add_argument('substr')
    sp.add_argument('anchor', type=float)
    sp.add_argument('--span', type=float, default=0.4)
    sp.set_defaults(func=cmd_gaps)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
