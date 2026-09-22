#!/usr/bin/env python3
"""Bounded anonymous native XPC lifecycle checks. No launchd/service registration."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
fixtures = Path(__file__).parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = root/'Sources/SecureXPC/Client/XPCClient.swift'
shutil.copy2(source, out/'XPCClient.swift')
def run(command, name, timeout=90):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    (out/name).write_text(result.stdout + result.stderr)
    result.check_returncode()
    return [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'SecureXPC',
     '-emit-module', '-emit-module-path', str(out/'SecureXPC.swiftmodule'), '-emit-library',
     '-o', str(out/'libSecureXPC.dylib'), *map(str, sorted((root/'Sources/SecureXPC').rglob('*.swift')))], 'build.log')
results = {}
for name, modes in [('ClientLifetime', ['cycles', 'sequences', 'held', 'races', 'security']),
                    ('ConnectionInterruption', ['']), ('MalformedSequence', [''])]:
    exe = out/name
    run(['xcrun', 'swiftc', '-swift-version', '5', '-I', str(out), '-L', str(out), '-lSecureXPC',
         str(fixtures/(name+'.swift')), '-o', str(exe)], name+'-build.log')
    for mode in modes:
        rows = run([str(exe), mode], name+'-'+mode+'.jsonl', 30)
        assert rows, (name, mode, 'no result')
        results[name+mode] = rows
        for row in rows:
            if 'completed' in row: assert row['completed'], row
            if 'retained' in row and row.get('phase') != 'callback-only-before-invalidate': assert row['retained'] == 0, row
        if mode == 'cycles': assert rows[-1]['echoes'] == 1000
        if mode == 'sequences': assert rows[0]['values'] == 20000 and rows[0]['finishes'] == 200 and rows[0]['errors'] == 0
        if mode == 'held': assert rows[0]['failures'] == 100 and rows[0]['finishes'] == 0
        if mode == 'races': assert rows[0]['callbacks'] == 3000 and rows[0]['future_failures'] == 1000
        if mode == 'security': assert rows[0]['insecure'] == 100 and rows[0]['server_calls'] == 0
        if name == 'ConnectionInterruption':
            assert rows[0]['reconnected_echoes'] == 30 and rows[0]['registered_handlers'] == 0 and rows[0]['terminal_callbacks'] == 30
            assert not rows[-1]['retained_client']
        if name == 'MalformedSequence':
            assert rows[0]['failures'] == 100 and rows[0]['registered_handlers'] == 0 and rows[0]['retained_callback_tokens'] == 0
for script in ['controlled-race.py', 'interruption-race.py']:
    run(['python3', str(fixtures/script), str(out)], script+'.log', 120)
(out/'receipt.json').write_text(json.dumps({'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'results': results,
    'scope': 'Owned anonymous in-process XPC. Test-only handshake hooks and reflection in race/handler checks; no privileged service, host restart, or elapsed-weeks claim.'}, indent=2))
print('PASS: client replacement, full replies, held sequences, startup races, interruption, trust rejection, malformed replies and cleanup')
