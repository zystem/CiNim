#!/usr/bin/env python3
"""What the ThreadSanitizer reports of a test log are about. Usage: tsan-report.py LOG...
A report is two accesses; each is given the first frame of its stack that is not the runtime of Nim or of the sanitizer (its origin), and the report the class of its
origins: `ours` when either is in src/, `test` when the worst is in tests/, `guildenstern` and `nimgrpc` for those libraries, `runtime` when both are the start or the
end of a thread or the exit of the program. Prints the count of each class for every log and the distinct pairs of the classes asked for (TSAN_SHOW, default "ours").
Exit code 1 when any log has a report of the class `ours`."""
import collections, os, re, sys
RUNTIME = ('/lib/system/', '/lib/system.nim', '/lib/std/', '/lib/pure/', 'libsanitizer', '/usr/include/', 'sanitizer_common', 'tsan_')
def origin(frames):
    for fn, path, line in frames:
        if any(r in path for r in RUNTIME): continue
        return fn, path, line
    return frames[0] if frames else ('?', '?', '0')
def kind(path):
    if any(r in path for r in RUNTIME) or path == '?': return 'runtime'
    if '/guildenstern' in path: return 'guildenstern'
    if '/nimgrpc' in path: return 'nimgrpc'
    if '/src/' in path and '/pkgs2/' not in path: return 'ours'
    if '/tests/' in path: return 'test'
    if '/unittest2' in path: return 'test'
    return 'other'
RANK = ['ours', 'nimgrpc', 'guildenstern', 'other', 'test', 'runtime']
def reports(text):
    for rep in text.split('WARNING: ThreadSanitizer: ')[1:]:
        what = rep.split(' (pid', 1)[0].split('\n', 1)[0]
        rep = rep.split('SUMMARY:')[0]
        accesses = []
        for sec in re.split(r'\n  (?=\S)', rep):
            if not re.match(r'(Previous |Atomic )?(atomic )?(read|write|Read|Write)', sec): continue
            frames = []
            for line in sec.split('\n')[1:]:
                m = re.match(r'\s+#\d+ (.*?) (\S+?):(\d+)(?::\d+)? \(', line) or re.match(r'\s+#\d+ (.*?) (\S+?):(\d+)\s*$', line)
                if m: frames.append((m.group(1).split('(')[0], m.group(2), m.group(3)))
            thread = 'main' if 'main thread' in sec.split('\n', 1)[0] else 'thread'
            accesses.append((thread, frames))
        yield what, accesses
show = os.environ.get('TSAN_SHOW', 'ours').split(',')
bad = False
total = collections.Counter(); pairs = collections.Counter()
for log in sys.argv[1:]:
    c = collections.Counter()
    for what, accesses in reports(open(log, errors='replace').read()):
        if what != 'data race':
            c[what] += 1; continue
        os_ = [origin(f) for _, f in accesses]
        kinds = sorted((kind(o[1]) for o in os_), key=RANK.index) or ['runtime']
        cls = kinds[0]
        if cls == 'runtime' and len(kinds) > 1: cls = kinds[-1]
        c[cls] += 1
        if cls in show:
            short = lambda o: '%s@%s:%s' % (o[0].split('::')[-1], o[1].split('/')[-1], o[2])
            top = lambda fr: (fr[0][0].split('::')[-1] if fr else '?')
            pairs[(cls, ' || '.join('%s %s [%s]' % (t, short(o), top(f)) for (t, f), o in zip(accesses, os_)))] += 1
    total.update(c)
    if c: print('%-44s %s' % (os.path.basename(log), '  '.join('%s=%d' % kv for kv in sorted(c.items()))))
    bad = bad or c['ours'] > 0
print('TOTAL', '  '.join('%s=%d' % kv for kv in sorted(total.items())))
for (cls, p), n in pairs.most_common(60): print('%3d %s: %s' % (n, cls, p[:400]))
sys.exit(1 if bad else 0)
