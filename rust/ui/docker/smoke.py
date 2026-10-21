"""Real Tauri/WebKitGTK integration and offline axe audit; no browser IPC shim."""
import base64
import json
import os
import http.client
from pathlib import Path
import signal
import subprocess
import time
import urllib.request
import urllib.error

out = Path('rust/ui/docker/out')
axe = Path('/opt/a11y/node_modules/axe-core/axe.min.js').read_text()
report = []
driver = subprocess.Popen(['tauri-driver'], stdout=(out / 'webdriver.log').open('w'), stderr=subprocess.STDOUT)
session = None

def _ready():
    try:
        return request('GET', '/status') is not None
    except Exception:
        return False

def request(method, path, value=None, retry=False):
    data = None if value is None else json.dumps(value).encode()
    # tauri-driver 2.0.4 sometimes resets a proxied keep-alive connection ("Connection reset by peer").
    # Only side-effect-free reads are retried; clicks and typing are never replayed.
    for attempt in range(3 if retry else 1):
        req = urllib.request.Request('http://127.0.0.1:4444' + path, data=data, method=method, headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=45) as response:
                result = json.load(response)['value']
            break
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read().decode()) from error
        except (http.client.RemoteDisconnected, ConnectionResetError):
            if attempt == (2 if retry else 0):
                raise
    if isinstance(result, dict) and result.get('error'):
        raise RuntimeError(result)
    return result

def command(path, value=None, method='POST', retry=False):
    return request(method, '/session/' + session + path, value, retry)

def js(script, *args):
    return command('/execute/sync', {'script':script,'args':list(args)}, retry=True)

def until(predicate, description):
    end = time.monotonic() + 35
    while True:
        result = predicate()
        if result:
            return result
        if time.monotonic() > end:
            raise AssertionError('Timed out: ' + description + '\n' + str(js('return document.body.innerText')))

def element(selector):
    return command('/element', {'using':'css selector','value':selector}, retry=True)['element-6066-11e4-a52e-4f735466cecf']

def click(selector):
    command('/element/' + element(selector) + '/click', {})

def text(value):
    return until(lambda: js('return document.body.innerText.includes(arguments[0])', value), value)

def route(name, heading):
    click('nav a[href="#' + name + '"]')
    text(heading)

def shot(name):
    (out / (name + '.png')).write_bytes(base64.b64decode(command('/screenshot', method='GET', retry=True)))
    subprocess.run(['import','-window','root',str(out / (name + '-desktop.png'))], check=True)

def audit(name):
    js(axe)
    result = command('/execute/async', {'script':"const done=arguments[arguments.length-1]; axe.run(document,{runOnly:{type:'tag',values:['wcag2a','wcag2aa','wcag21a','wcag21aa']}}).then(done).catch(e=>done({error:String(e)}));",'args':[]}, retry=True)
    (out / ('axe-' + name + '.json')).write_text(json.dumps(result, indent=2))
    assert not result.get('error'), result
    violations = result['violations']
    report.append({'page':name,'violations':len(violations),'passes':len(result['passes'])})
    assert not violations, [(v['id'], [(n['target'],n.get('failureSummary')) for n in v['nodes']]) for v in violations]

try:
    until(lambda: _ready(), 'tauri-driver')
    response = request('POST', '/session', {'capabilities':{'alwaysMatch':{'tauri:options':{'application':'/build/release/tinyprune-ui'}}}})
    session = response['sessionId']
    text('Agent connected')
    text('tinyprune-ui-fixture')
    shot('real-overview'); audit('real-overview')
    route('rules', 'Rules with a reason.'); text('Docker Preview fixture'); audit('real-rules')
    click('a[href="#rules/new"]'); text('A thoughtful new rule.')
    # Use WebDriver keystrokes for the editor, rather than assigning fixture DOM.
    command('/element/' + element('input[name="name"]') + '/value', {'text':'Created through Linux UI'})
    click('#preview-rule'); text('Preview completed.')
    until(lambda: js('return !document.querySelector("#save-rule").disabled'), 'Preview enables save')
    audit('real-preview'); shot('real-preview')
    click('[data-explain]'); text('The agent’s complete decision context.')
    audit('real-explanation'); shot('real-explanation')
    assert js('return document.querySelector("#explanation").open')
    # Escape closes the native modal; focus must return to its triggering button.
    command('/element/' + element('#close-explanation') + '/value', {'text':'\ue00c'})
    until(lambda: js('return !document.querySelector("#explanation").open'), 'Escape closes drawer')
    assert js('return document.activeElement.matches("[data-explain]")'), 'explanation focus was not restored'
    click('#save-rule'); text('Rules with a reason.'); text('Created through Linux UI')
    policy = subprocess.check_output(['/build/release/tinyprune','rules','--json'], text=True)
    assert 'Created through Linux UI' in policy and 'preview' in policy
    route('upcoming','What comes next.'); text('old.txt'); text('1 of 1 item'); audit('real-upcoming'); shot('real-upcoming')
    assert js('return getComputedStyle(document.querySelector("#load-more")).display === "none"'), 'Load more is visible without a next cursor'
    click('[data-explain]'); text('/tmp/tinyprune-ui-fixture/old.txt'); click('#close-explanation')
    route('activity','A clear paper trail.'); text('rule'); audit('real-activity'); shot('real-activity')
    route('settings','Quiet by design.'); audit('real-settings')
    # Dark theme (user-selectable) and a narrow window: contrast, reflow and no horizontal overflow.
    js('document.documentElement.dataset.theme="dark"'); audit('real-settings-dark'); shot('real-settings-dark')
    command('/window/rect', {'width':390,'height':800})
    until(lambda: js('return innerWidth <= 400'), 'window narrows')
    assert js('return document.documentElement.scrollWidth <= innerWidth + 1'), 'horizontal overflow at 390 px'
    audit('real-settings-narrow'); shot('real-settings-narrow')
    command('/window/rect', {'width':1180,'height':820})
    js('document.documentElement.dataset.theme="light"')
    click('#pause'); text('Resume cleanup')
    assert 'true' in subprocess.check_output(['/build/release/tinyprune','rules','--json'], text=True).lower()
    click('#pause'); text('Pause cleanup'); shot('real-settings')
    # Native WebDriver Tab navigation and reduced-motion computed contract.
    command('/element/' + element('#pause') + '/value', {'text':'\ue004'})
    assert js('return document.activeElement.id === "hidden-protection"'), 'Tab order from pause to hidden protection'
    assert js('return matchMedia("(prefers-reduced-motion: reduce)").matches'), 'Linux reduced motion preference is not active'
    assert js('return getComputedStyle(document.querySelector("button")).transitionDuration === "0s"')
    os.kill(int(os.environ['TINYPRUNE_UI_AGENT_PID']), signal.SIGINT)
    until(lambda: not Path(os.environ['TINYPRUNE_ENDPOINT']).exists(), 'agent socket removed after SIGINT')
    route('overview','Your files can wait.')
    text('Agent unavailable'); text('The TinyPrune agent is not running'); audit('real-offline'); shot('real-offline')
    # Explicit mock only, in the same actual Linux WebKitGTK frontend.
    js('location.search="?mock=1"')
    text('Browser demo')
    for name, heading in [('overview','Room for what matters.'),('rules','Rules with a reason.'),('upcoming','What comes next.'),('activity','A clear paper trail.'),('settings','Quiet by design.')]:
        route(name, heading); audit('mock-' + name)
    assert Path('/tmp/tinyprune-ui-fixture/old.txt').exists()
    assert Path('/tmp/tinyprune-ui-fixture/keep.txt').exists()
    assert not list(Path(os.environ['XDG_DATA_HOME']).glob('Trash/files/*')), 'Preview moved files'
    (out / 'summary.json').write_text(json.dumps(report, indent=2))
    print('UI DOCKER PASS: real agent CRUD/Preview, navigation, explanations, pause, keyboard, reduced motion, offline, mock, axe', flush=True)
finally:
    if session:
        try:
            shot('last-state')
            command('', method='DELETE')
        except Exception:
            pass
    driver.terminate()
    driver.wait(timeout=10)
