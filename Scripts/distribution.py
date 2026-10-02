#!/usr/bin/env python3
"""Release metadata, checksum validation, cask rendering and Sparkle publication."""
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz'
SPARKLE_SHA256 = '5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
WARNING = '''This preview is ad-hoc signed, NOT Developer ID signed, and NOT notarized. Download only from this repository and verify the SHA-256 checksum.

On macOS 15 Sequoia and macOS 26 Tahoe: copy TinyPrune.app into /Applications, try opening it once, dismiss the Gatekeeper alert, then open System Settings > Privacy & Security > Open Anyway. Confirm Open and authenticate if prompted. Control-click Open is not a substitute on these macOS versions.

If you deliberately trust this preview and Open Anyway is unavailable, run exactly:

    xattr -dr com.apple.quarantine /Applications/TinyPrune.app

Then open /Applications/TinyPrune.app again. This removes quarantine, not proof of safety; it does not notarize the app. Finder extension and launch-at-login may need separate approval in System Settings > General > Login Items & Extensions. Automatic in-app updates are unavailable (Sparkle is not linked yet). Preview signing does not guarantee Finder extension or login-item activation on every Mac.'''

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def tag():
    value = os.environ['RELEASE_TAG']
    if not re.fullmatch(r'v\d+\.\d+\.\d+', value):
        raise ValueError('Expected vX.Y.Z release tag')
    return value

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def tools(root):
    archive = root / 'Sparkle.tar.xz'
    urllib.request.urlretrieve(SPARKLE_URL, archive)
    if digest(archive) != SPARKLE_SHA256:
        raise ValueError('Sparkle tarball checksum mismatch')
    target = root / 'sparkle'
    target.mkdir(exist_ok=True)
    run('tar', '-xf', str(archive), '-C', str(target))
    return target / 'bin'

def download(channel):
    version = tag()[1:]
    root = Path(os.environ['RUNNER_TEMP']) / ('distribution-' + channel)
    root.mkdir(parents=True, exist_ok=True)
    filename = f'TinyPrune-{version}' + ('-homebrew' if channel == 'homebrew' else '') + '.dmg'
    for asset in [filename, filename + '.sha256', f'TinyPrune-{version}.json']:
        run('gh', 'release', 'download', tag(), '--repo', os.environ['GITHUB_REPOSITORY'], '--pattern', asset, '--dir', str(root), '--clobber')
    dmg = root / filename
    checksum = (root / (filename + '.sha256')).read_text().strip().split()
    if len(checksum) != 2 or checksum[1] != filename or checksum[0] != digest(dmg):
        raise ValueError('Released DMG checksum mismatch')
    metadata = json.loads((root / f'TinyPrune-{version}.json').read_text())
    if metadata['tag'] != tag() or metadata['signing'] not in ['signed', 'unsigned']:
        raise ValueError('Invalid release distribution metadata')
    url = f'https://github.com/{os.environ["GITHUB_REPOSITORY"]}/releases/download/{tag()}/{filename}'
    return root, dmg, metadata, url

def render():
    root, dmg, metadata, url = download('homebrew')
    postflight = ''
    if metadata['signing'] == 'unsigned':
        postflight = '''  postflight do
    ohai "Unsigned preview: not notarized. Clearing quarantine only for this trusted release."
    ohai "Finder extension and launch-at-login may need approval in System Settings."
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/TinyPrune.app"]
  end
'''
    text = Path('Resources/Homebrew/tinyprune.rb.template').read_text()
    for key, value in {'VERSION': tag()[1:], 'SHA256': digest(dmg), 'URL': url, 'POSTFLIGHT': postflight}.items():
        text = text.replace('@' + key + '@', value)
    destination = Path(os.environ['CASK_OUTPUT'])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)

def feed():
    root, dmg, metadata, url = download('direct')
    if metadata['signing'] != 'signed':
        print('Unsigned preview: stable Sparkle feed publication skipped.')
        return
    bin_path = tools(root)
    notes = subprocess.check_output(['gh', 'release', 'view', tag(), '--repo', os.environ['GITHUB_REPOSITORY'], '--json', 'body', '--jq', '.body'], text=True)
    note = '<!doctype html><html lang="en"><meta charset="utf-8"><title>TinyPrune ' + tag()[1:] + '</title><body><pre>' + html.escape(notes) + '</pre></body></html>'
    (root / (dmg.stem + '.html')).write_text(note)
    output = Path('website/updates')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'appcast.xml').exists():
        (root / 'appcast.xml').write_bytes((output / 'appcast.xml').read_bytes())
    run(str(bin_path / 'generate_appcast'), '--ed-key-file', '-', '--maximum-versions', '0', '--maximum-deltas', '0', '--download-url-prefix', url.rsplit('/', 1)[0] + '/', '--release-notes-url-prefix', 'https://tinyprune.com/updates/', str(root), input=(os.environ['SPARKLE_ED25519_PRIVATE_KEY'] + '\n').encode())
    tree = ET.parse(root / 'appcast.xml')
    for item in tree.findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is not None and enclosure.get('url') == url:
            notes_link = item.find('{' + NS + '}releaseNotesLink')
            if notes_link is not None:
                notes_link.text = 'https://tinyprune.com/updates/' + tag()[1:] + '.html'
    tree.write(output / 'appcast.xml', encoding='utf-8', xml_declaration=True)
    (output / (tag()[1:] + '.html')).write_text(note)

def verify():
    root, dmg, metadata, url = download('direct')
    if metadata['signing'] != 'signed':
        print('Unsigned preview has no stable feed entry; verification skipped.')
        return
    with urllib.request.urlopen('https://tinyprune.com/updates/appcast.xml', timeout=30) as response:
        tree = ET.fromstring(response.read())
    matches = [e for e in tree.findall('./channel/item/enclosure') if e.get('url') == url]
    if len(matches) != 1 or matches[0].get('length') != str(dmg.stat().st_size):
        raise ValueError('Public feed enclosure URL/length does not match release')
    signature = matches[0].get('{' + NS + '}edSignature')
    if not signature:
        raise ValueError('Public enclosure has no EdDSA signature')
    run(str(tools(root) / 'sign_update'), '--verify', '--ed-key-file', '-', str(dmg), signature, input=(os.environ['SPARKLE_ED25519_PRIVATE_KEY'] + '\n').encode())
    print('Public appcast enclosure URL, length and EdDSA signature verified.')

if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'notes':
        print(WARNING if os.environ['SIGNING_MODE'] == 'unsigned' else 'Developer ID signed and notarized universal macOS release.')
    elif command == 'metadata':
        (Path(os.environ['RUNNER_TEMP']) / f'TinyPrune-{tag()[1:]}.json').write_text(json.dumps({'tag': tag(), 'signing': os.environ['SIGNING_MODE']}))
    elif command == 'cask':
        render()
    elif command == 'feed':
        feed()
    elif command == 'verify':
        verify()
    else:
        raise ValueError('Unknown distribution command')
