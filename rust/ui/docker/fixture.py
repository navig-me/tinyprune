import json
import os
from pathlib import Path
import subprocess
import time

cli = '/build/release/tinyprune'
# Readiness is condition-driven, not a fixed delay or a production sleep.
end = time.monotonic() + 30
while subprocess.run([cli, 'status'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
    if time.monotonic() > end:
        raise RuntimeError('agent did not become ready')
subprocess.run([cli, 'roots', 'add', 'ui-fixture', '/tmp/tinyprune-ui-fixture', 'Docker fixture'], check=True)
subprocess.run([cli, 'keep', '/tmp/tinyprune-ui-fixture/keep.txt'], check=True)
rule = {'id':'11111111-1111-4111-8111-111111111111','name':'Docker Preview fixture','scope':{'path':'/tmp/tinyprune-ui-fixture','recursive':True},'matcher':{'itemKind':'file','exactNames':[],'globPatterns':['*.txt']},'expiryBasis':'modified','lifetime':86400,'gracePeriod':3600,'action':'trashItem','state':'preview','matchMode':'scoped'}
Path('/tmp/tinyprune-ui-rule.json').write_text(json.dumps(rule))
subprocess.run([cli, 'rules', 'add', '/tmp/tinyprune-ui-rule.json'], check=True)
end = time.monotonic() + 30
while 'old.txt' not in subprocess.check_output([cli, 'upcoming'], text=True):
    if time.monotonic() > end:
        raise RuntimeError('fixture was not indexed')
