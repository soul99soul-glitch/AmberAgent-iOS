#!/usr/bin/env python3
"""Read-only prototype: baseline method -> current declaration -> per-target XCTest discovery.

Use only the final map for each phase. Missing current paths are unresolved evidence,
not presumed deletions. Discovery is required only with --require-discovery.
"""
import argparse
from collections import Counter, defaultdict
from functools import lru_cache
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
REV = Path(__file__).resolve().parent
INVENTORY = (Path(os.environ['AMBER_SWIFT_BASELINE_DIR'])/'test-method-inventory.json'
             if 'AMBER_SWIFT_BASELINE_DIR' in os.environ
             else REV/'phase-6-coverage-baseline-test-inventory.json')
MAPS = [
    ('p1', REV/'phase-1-test-identifiers.json'),
    ('p2', REV/'phase-2-test-identifiers.json'),
    ('p3_engine', REV/'phase-3-engine-test-identifiers.json'),
    ('p3_render', REV/'phase-3-render-session-test-identifiers.json'),
    ('p4_domain', REV/'phase-4-domain-test-identifiers.json'),
    ('p4_session_final', REV/'phase-4-session-test-identifiers-helper-fix.json'),
]
# An inventory name was inside a private actor in the original source. The
# repair moves the identical method body to an XCTestCase extension. Require
# the repaired owner in actual discovery; never silently waive this name.
ACTOR_EXCEPTION = {
    'old': ('iosApp/iosAppTests/NovelProjectPackageTests.swift', 'testExportSkipsDiscardedChapters'),
    'new': ('iosApp/iosAppTests/NovelProjectPackageTests.swift', 'NovelProjectPackageTests', 'testExportSkipsDiscardedChapters'),
    'evidence': str(REV/'phase-4-export-test-discovery-repair.json'),
}
# The original and current project.yml both leave this device-control smoke
# source out of every test target. Keep its declaration in the baseline audit,
# but do not require XCTest discovery for a test that never had a configured
# runner. Revoke this exception automatically if the source gains membership.
PREEXISTING_UNBOUND = {
    ('iosApp/iosAppUITests/AmberControlUITests.swift', 'testLaunchInstalledAmberAndSnapshot'): {
        'classification': 'pre_existing_unbound_test_source',
        'evidence': [
            'HEAD:iosApp/project.yml: IOSIntelligentUIAcceptance has two explicit sources; iosAppTests uses only iosAppTests/',
            'initial baseline status.txt: neither project.yml nor AmberControlUITests.swift modified',
            'current AmberControlUITests.swift is byte-identical to HEAD',
        ],
    },
}


def norm_method(s):
    return s.split('/')[-1].removesuffix('()')


def norm_path(s):
    s = str(s)
    for marker in ('/files/iosApp/', '/iosApp/'):
        if marker in s:
            return 'iosApp/' + s.split(marker, 1)[1]
    if s.startswith('iosApp/'):
        return s
    if s.endswith('.swift') and '/' not in s:
        return 'iosApp/iosAppTests/' + s
    raise ValueError(f'unknown test file path: {s}')


def ident_parts(s):
    bits = s.removesuffix('()').split('/')
    if len(bits) == 3:
        return bits[0], bits[1], bits[2]
    if len(bits) == 2:
        return None, bits[0], bits[1]
    raise ValueError(f'unknown test identifier: {s}')


def old_file_for_p2(old_id, inventory):
    _, cls, meth = ident_parts(old_id)
    candidates = [p for p, names in inventory.items()
                  if Path(p).stem == cls and meth in names and p.startswith('iosApp/iosAppTests/')]
    if len(candidates) != 1:
        raise ValueError(f'P2 original file ambiguous: {old_id}: {candidates}')
    return candidates[0]


def extra_phase(data):
    raw = data.get('phase', '')
    return f'p{raw}' if isinstance(raw, int) else str(raw).lower()


def read_edges(inventory, extra_maps=()):
    edges = defaultdict(list)
    map_extras = []
    for phase, path in MAPS:
        d = json.loads(path.read_text())
        if phase == 'p1':
            items = [(d['sourceFile'], m['oldIdentifier'], m['newFile'], m['newIdentifier']) for m in d['mappings']]
        elif phase == 'p2':
            items = [(old_file_for_p2(o, inventory), o,
                      'iosApp/iosAppTests/' + ident_parts(n)[1] + '.swift', n)
                     for o, n in d.items()]
        elif phase == 'p3_engine':
            items = [(m['old_file'], m['old_identifier'], m['new_file'], m['new_identifier'])
                     for m in d['mapping']]
        elif phase == 'p3_render':
            items = [(m['oldFile'], m['oldIdentifier'], m['newFile'], m['newIdentifier'])
                     for m in d['mappings']]
        elif phase == 'p4_domain':
            items = [(m['originalFile'], m['originalIdentifier'], m['migratedFile'], m['migratedIdentifier'])
                     for m in d['methods']]
        else:
            items = [(m['old_path'], m['old_id'], m['new_path'], m['new_id'])
                     for m in d['mappings']]
        for old_file, old_id, new_file, new_id in items:
            old_path = norm_path(old_file)
            new_path = norm_path(new_file)
            old_key = old_path, norm_method(old_id)
            new_target, new_class, new_method = ident_parts(new_id)
            if old_key[1] not in inventory.get(old_path, []):
                map_extras.append({'phase': phase, 'old': old_key, 'new': new_id,
                                   'reason': 'not_in_global_baseline_inventory'})
                continue
            edges[old_key].append({'phase': phase, 'path': new_path, 'class': new_class,
                                   'method': new_method, 'target_hint': new_target})
    for path in extra_maps:
        data = json.loads(Path(path).read_text())
        if data.get('schemaVersion') != 1:
            raise ValueError(f'{path}: expected schemaVersion=1')
        phase = extra_phase(data)
        if isinstance(data.get('mappings'), list):
            items = [(m['oldFile'], m['oldMethod'].removesuffix('()'),
                      m['newFile'], m['newClass'], m['newMethod'].removesuffix('()'), None)
                     for m in data['mappings']]
        elif data.get('phase') == 5 and isinstance(data.get('testMethods'), list):
            items = []
            for m in data['testMethods']:
                old_target, _, old_method = ident_parts(m['oldId'])
                new_target, new_class, new_method = ident_parts(m['newId'])
                if old_target != 'iosAppTests' or new_target != 'iosAppTests':
                    raise ValueError(f'{path}: unexpected P5 target in {m}')
                items.append((m['oldPath'], old_method, m['newPath'],
                              new_class, new_method, new_target))
        else:
            raise ValueError(f'{path}: expected normalized mappings or P5 testMethods list')
        for old_file, old_method, new_file, new_class, new_method, new_target in items:
            old_path = norm_path(old_file)
            new_path = norm_path(new_file)
            old_key = (old_path, old_method)
            if old_key[1] not in inventory.get(old_path, []):
                map_extras.append({'phase': phase, 'old': old_key,
                                   'reason': 'not_in_global_baseline_inventory'})
                continue
            edges[old_key].append({'phase': phase, 'path': new_path,
                                   'class': new_class, 'method': new_method,
                                   'target_hint': new_target})
    return edges, map_extras


def current_methods():
    result = {}
    files = subprocess.check_output(['rg', '--files', 'iosApp', '-g', '*.swift',
                                     '-g', '!**/build/**', '-g', '!**/.build/**'],
                                    cwd=ROOT, text=True).splitlines()
    for path in files:
        file = ROOT/path
        result[path] = Counter(re.findall(r'\bfunc\s+(test\w+)\s*\(',
                                          file.read_text(errors='replace')))
    return result


@lru_cache(maxsize=1)
def target_source_sets():
    import yaml
    result = {}
    for spec, names in [
        ('iosApp/project.yml', ['iosAppTests', 'IOSIntelligentUIAcceptance']),
        ('iosApp/NovelApp/project.yml', ['NovelTests']),
        ('iosApp/DeepReadApp/project.yml', ['DeepReadTests']),
        ('iosApp/PhoneControlRunner/project.yml', ['IPhoneUseRunnerUITests']),
    ]:
        base = (ROOT/spec).parent
        data = yaml.safe_load((ROOT/spec).read_text())
        for name in names:
            paths = set()
            for item in data['targets'][name]['sources']:
                item = {'path': item} if isinstance(item, str) else item
                location = (base/item['path']).resolve()
                if location.is_file():
                    if location.suffix == '.swift':
                        paths.add(location)
                elif location.is_dir():
                    paths.update(f.resolve() for f in location.rglob('*.swift'))
            result[name] = paths
    return result


@lru_cache(maxsize=None)
def memberships(path):
    location = (ROOT/path).resolve()
    targets = [name for name, files in target_source_sets().items() if location in files]
    # AmberPhoneControl uses SwiftPM's default Tests/<test-target> path.
    if path.startswith('iosApp/Packages/AmberPhoneControl/Tests/AmberPhoneControlTests/'):
        targets.append('AmberPhoneControlTests')
    # The vendor package declares this explicit test-target path.
    if path.startswith('iosApp/vendor/SwiftStreamingMarkdown/Tests/MarkdownTextTests/'):
        targets.append('SwiftStreamingMarkdownTests')
    return targets


def discovery_from_xcresult(path):
    raw = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                                   '--path', str(path), '--format', 'json'], text=True)
    return discovery_from_xcresult_tree(json.loads(raw))


def discovery_from_xcresult_tree(data):
    out = defaultdict(list)
    def visit(node):
        if isinstance(node, dict):
            if node.get('nodeType') == 'Test Case':
                url = node.get('nodeIdentifierURL', '')
                # test://com.apple.xcode/Project/Target/Class/testMethod
                bits = url.split('/')
                if len(bits) >= 4:
                    target, cls, method = bits[-3:]
                    out[(target, cls, norm_method(method))].append(node.get('result', 'Unknown'))
            for child in node.get('children', []):
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)
    visit(data.get('testNodes', []))
    return out


def discovery_from_xunit(path, target):
    out = defaultdict(list)
    root = ET.parse(path).getroot()
    for case in root.iter('testcase'):
        cls = case.get('classname', '').split('.')[-1]
        method = norm_method(case.get('name', ''))
        if not cls or not method:
            continue
        if case.find('failure') is not None or case.find('error') is not None:
            result = 'Failed'
        elif case.find('skipped') is not None:
            result = 'Skipped'
        else:
            result = 'Passed'
        out[(target, cls, method)].append(result)
    return out


def discovery_from_swiftpm_log(path):
    """Read complete, serial XCTest events; reject truncated/ambiguous logs.

    SwiftPM 6.4's --xunit-output is accepted by the CLI here but produced no
    XML for the observed default swiftbuild run. Do not manufacture xUnit.
    """
    lines = Path(path).read_text(errors='replace').splitlines()
    case_re = re.compile(r"^Test Case '-\[([A-Za-z_][\w]*)\.([A-Za-z_][\w]*) (test\w+)\]' (started|passed|failed|skipped)\b")
    suite_start_re = re.compile(r"^Test Suite '([A-Za-z_][\w]*Tests)\.xctest' started at ")
    suite_end_re = re.compile(r"^Test Suite '([A-Za-z_][\w]*Tests)\.xctest' (passed|failed) at ")
    all_end_re = re.compile(r"^Test Suite 'All tests' (passed|failed) at ")
    summary_re = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures?\b")
    swift_testing_re = re.compile(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)")
    active_suite = None
    suite_summaries = []
    all_summaries = []
    started = set()
    terminals = {}
    for index, line in enumerate(lines):
        match = suite_start_re.match(line)
        if match:
            if active_suite is not None or suite_summaries:
                raise ValueError(f'{path}: multiple or nested XCTest bundle runs')
            active_suite = match.group(1)
            continue
        match = case_re.match(line)
        if match:
            target, cls, method, state = match.groups()
            key = (target, cls, method)
            if active_suite != target:
                raise ValueError(f'{path}: XCTest case outside its bundle: {key}')
            if state == 'started':
                if key in started:
                    raise ValueError(f'{path}: duplicate XCTest start: {key}')
                started.add(key)
            else:
                if key not in started or key in terminals:
                    raise ValueError(f'{path}: unmatched or duplicate XCTest terminal: {key}')
                terminals[key] = state.capitalize()
            continue
        match = suite_end_re.match(line)
        if match:
            target, state = match.groups()
            if active_suite != target or index + 1 >= len(lines):
                raise ValueError(f'{path}: unmatched XCTest bundle summary')
            counts = summary_re.match(lines[index + 1])
            if not counts:
                raise ValueError(f'{path}: missing XCTest bundle count summary')
            total, failures = map(int, counts.groups())
            suite_summaries.append((target, state, total, failures))
            active_suite = None
            continue
        match = all_end_re.match(line)
        if match:
            counts = summary_re.match(lines[index + 1]) if index + 1 < len(lines) else None
            if not counts:
                raise ValueError(f'{path}: missing all-tests count summary')
            total, failures = map(int, counts.groups())
            all_summaries.append((match.group(1), total, failures))
    if active_suite is not None or len(suite_summaries) != 1:
        raise ValueError(f'{path}: expected one complete XCTest bundle summary')
    target, state, total, failures = suite_summaries[0]
    if started != terminals.keys() or len(terminals) != total:
        raise ValueError(f'{path}: case events do not match XCTest bundle total ({len(terminals)}/{total})')
    observed_failures = sum(result == 'Failed' for result in terminals.values())
    if observed_failures != failures or (state == 'passed') != (failures == 0):
        raise ValueError(f'{path}: case outcomes disagree with XCTest bundle summary')
    if all_summaries != [(state, total, failures)]:
        raise ValueError(f'{path}: all-tests summary disagrees with XCTest bundle summary')
    swift_testing = [swift_testing_re.search(line) for line in lines]
    swift_testing = [match for match in swift_testing if match]
    if len(swift_testing) > 1 or (swift_testing and int(swift_testing[0].group(1)) != 0):
        raise ValueError(f'{path}: nonzero Swift Testing cases require separate discovery evidence')
    return {key: [result] for key, result in terminals.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xcresult', action='append', default=[], help='repeat for all final product result bundles')
    ap.add_argument('--xcresult-tree', action='append', default=[], help='pre-exported xcresulttool test-results tests JSON; does not unpack result bundle')
    ap.add_argument('--extra-map', action='append', default=[], help='P5/P6 normalized map JSON')
    ap.add_argument('--xunit', action='append', default=[], help='TARGET=PATH, e.g. AmberPhoneControlTests=package.xml')
    ap.add_argument('--swiftpm-log', action='append', default=[], help='complete serial XCTest swift test log; strict event/summary validation')
    ap.add_argument('--require-discovery', action='store_true', help='fail if mapped XCTest test has no final discovery')
    ap.add_argument('--output', default='/tmp/amber-final-test-coverage-report.json')
    args = ap.parse_args()
    inventory = json.loads(INVENTORY.read_text())
    edges, extras = read_edges(inventory, args.extra_map)
    extra_phases = [extra_phase(json.loads(Path(path).read_text()))
                    for path in args.extra_map]
    declarations = current_methods()
    observed = defaultdict(list)
    swiftpm_log_summaries = []
    for bundle in args.xcresult:
        for key, statuses in discovery_from_xcresult(Path(bundle)).items():
            observed[key].extend({'bundle': bundle, 'result': status} for status in statuses)
    for filename in args.xcresult_tree:
        for key, statuses in discovery_from_xcresult_tree(json.loads(Path(filename).read_text())).items():
            observed[key].extend({'bundle': filename, 'result': status} for status in statuses)
    for spec in args.xunit:
        target, sep, filename = spec.partition('=')
        if not sep or not target or not filename:
            raise ValueError(f'--xunit expected TARGET=PATH: {spec}')
        for key, statuses in discovery_from_xunit(Path(filename), target).items():
            observed[key].extend({'bundle': filename, 'result': status} for status in statuses)
    for filename in args.swiftpm_log:
        events = discovery_from_swiftpm_log(filename)
        swiftpm_log_summaries.append({'path': filename, 'cases': len(events),
                                      'targets': dict(Counter(key[0] for key in events)),
                                      'outcomes': dict(Counter(statuses[0] for statuses in events.values()))})
        for key, statuses in events.items():
            observed[key].extend({'bundle': filename, 'result': status} for status in statuses)
    rows, conflicts, declaration_gaps, discovery_gaps, duplicates, membership_gaps, nonpassing, preexisting_unbound = [], [], [], [], [], [], [], []
    duplicate_map_entries = []
    destination_owners = defaultdict(list)
    for old_path, methods in inventory.items():
        for old_method in methods:
            old = (old_path, old_method)
            candidates = edges.get(old, [])
            if old == ACTOR_EXCEPTION['old']:
                p, c, m = ACTOR_EXCEPTION['new']
                candidates = [{'phase': 'p4_actor_discovery_repair', 'path': p,
                               'class': c, 'method': m, 'target_hint': 'iosAppTests'}]
            if not candidates:
                candidates = [{'phase': 'unchanged_path', 'path': old_path, 'class': None,
                               'method': old_method, 'target_hint': None}]
            unique = {(x['path'], x['class'], x['method']) for x in candidates}
            if len(unique) != 1:
                conflicts.append({'old': old, 'candidates': candidates})
            if len(candidates) > 1:
                duplicate_map_entries.append({'old': old, 'candidates': candidates})
            chosen = candidates[0]
            dest_path, dest_class, dest_method = chosen['path'], chosen['class'], chosen['method']
            count = declarations.get(dest_path, Counter())[dest_method]
            row = {'old_path': old_path, 'old_method': old_method,
                   'destination_path': dest_path, 'destination_class': dest_class,
                   'destination_method': dest_method, 'map_sources': [x['phase'] for x in candidates],
                   'declaration_count_in_file': count, 'targets': memberships(dest_path)}
            destination_owners[(dest_path, dest_method)].append(old)
            if not row['targets']:
                if (old in PREEXISTING_UNBOUND and chosen['phase'] == 'unchanged_path'
                        and dest_path == old_path and dest_method == old_method and count == 1):
                    row['preexisting_unbound'] = PREEXISTING_UNBOUND[old]
                    preexisting_unbound.append({'old': old, 'destination': [dest_path, dest_method],
                                                **PREEXISTING_UNBOUND[old]})
                else:
                    membership_gaps.append({'old': old, 'destination': [dest_path, dest_method],
                                            'classification': 'no_current_test_target_membership'})
            if old == ACTOR_EXCEPTION['old']:
                row['explicit_exception'] = ACTOR_EXCEPTION['evidence']
            if count != 1:
                declaration_gaps.append({'old': old, 'destination': [dest_path, dest_method],
                                         'declaration_count': count,
                                         'classification': 'unresolved_pending_map_or_source'})
            if chosen['phase'] != 'unchanged_path' and count == 1:
                for target in row['targets']:
                    if target.endswith('_unchecked') or target == 'membership_unresolved':
                        discovery_gaps.append({'old': old, 'target': target, 'reason': 'membership_unresolved'})
                        continue
                    if dest_class:
                        found = observed.get((target, dest_class, dest_method), [])
                    else:
                        found = []
                    per_bundle = Counter(x['bundle'] for x in found)
                    if any(n > 1 for n in per_bundle.values()):
                        duplicates.append({'old': old, 'target': target, 'observations': found})
                    if found and not any(x['result'] == 'Passed' for x in found):
                        nonpassing.append({'old': old, 'target': target, 'observations': found})
                    if not found:
                        discovery_gaps.append({'old': old, 'target': target,
                                               'expected': [dest_class, dest_method],
                                               'reason': ('not_observed_in_supplied_results' if args.xcresult or args.xcresult_tree or args.xunit or args.swiftpm_log else 'no_result_bundle_supplied')})
                    row.setdefault('discovery', {})[target] = found
            rows.append(row)
    report = {'baseline': str(INVENTORY),
              'baseline_files': len(inventory), 'baseline_methods': sum(map(len, inventory.values())),
              'map_files': [str(p) for _, p in MAPS] + args.extra_map,
              'pending_phases_without_maps': [p for p in ['p5', 'p6']
                                               if not any(phase == p or phase.startswith(p + '_')
                                                          for phase in extra_phases)],
              'mapped_baseline_methods': len(edges),
              'map_entries_outside_global_baseline': extras,
              'duplicate_map_entries': duplicate_map_entries,
              'conflicting_destinations': conflicts,
              'convergent_destinations': [{'destination': k, 'originals': v}
                                          for k, v in destination_owners.items() if len(v) > 1],
              'membership_gaps': membership_gaps, 'preexisting_unbound': preexisting_unbound,
              'declaration_gaps': declaration_gaps,
              'discovery_gaps': discovery_gaps, 'duplicate_discoveries': duplicates,
              'global_duplicate_discoveries': [
                  {'identifier': key, 'bundle': bundle, 'count': count}
                  for key, events in observed.items()
                  for bundle, count in Counter(event['bundle'] for event in events).items()
                  if count > 1],
              'discovered_but_nonpassing': nonpassing,
              'discovery_bundles': args.xcresult + args.xcresult_tree + args.xunit + args.swiftpm_log,
              'swiftpm_log_summaries': swiftpm_log_summaries,
              'actor_exception': ACTOR_EXCEPTION,
              'rows': rows}
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in report.items()
                      if k not in ('rows', 'map_files', 'baseline', 'actor_exception', 'swiftpm_log_summaries',
                                   'map_entries_outside_global_baseline', 'pending_phases_without_maps')}, ensure_ascii=False))
    return int(bool(extras or duplicate_map_entries or conflicts or
                    report['convergent_destinations'] or declaration_gaps or
                    (args.require_discovery and (membership_gaps or discovery_gaps or duplicates or
                                                 report['global_duplicate_discoveries'] or
                                                 report['pending_phases_without_maps']))))

if __name__ == '__main__':
    sys.exit(main())
