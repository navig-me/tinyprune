import json
import os
from pathlib import Path
import subprocess
import time

cli = os.environ.get('TINYPRUNE_UI_CLI', '/build/release/tinyprune')
fixture = Path(os.environ.get('TINYPRUNE_UI_FIXTURE', '/tmp/tinyprune-ui-fixture'))
rule_file = fixture.parent / 'tinyprune-ui-rule.json'
fixture.mkdir(parents=True, exist_ok=True)
# Both files are far older than the one-day rule lifetime, so old.txt is due; keep.txt is protected by Keep.
for name, body in (('old.txt', 'metadata fixture\n'), ('keep.txt', 'keep fixture\n')):
    (fixture / name).write_text(body)
    os.utime(fixture / name, (1577836800, 1577836800))  # 2020-01-01T00:00:00Z
# Readiness is condition-driven, not a fixed delay or a production sleep.
end = time.monotonic() + 30
while subprocess.run([cli, 'status'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
    if time.monotonic() > end:
        raise RuntimeError('agent did not become ready')
    time.sleep(0.25)
subprocess.run([cli, 'roots', 'add', 'ui-fixture', str(fixture), 'Fixture'], check=True)
subprocess.run([cli, 'keep', str(fixture / 'keep.txt')], check=True)
rule = {'id':'11111111-1111-4111-8111-111111111111','name':'Docker Preview fixture','scope':{'path':str(fixture),'recursive':True},'matcher':{'itemKind':'file','exactNames':[],'globPatterns':['*.txt']},'expiryBasis':'modified','lifetime':86400,'gracePeriod':3600,'action':'trashItem','state':'preview','matchMode':'scoped'}
rule_file.write_text(json.dumps(rule))
subprocess.run([cli, 'rules', 'add', str(rule_file)], check=True)
end = time.monotonic() + 30
while 'old.txt' not in subprocess.check_output([cli, 'upcoming'], text=True, encoding='utf-8'):
    if time.monotonic() > end:
        raise RuntimeError('fixture was not indexed')
    time.sleep(0.25)
