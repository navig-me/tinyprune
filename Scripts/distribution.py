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

SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz'
SPARKLE_SHA256 = '01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
WARNING = '''This preview is ad-hoc signed, NOT Developer ID signed, and NOT notarized. Download only from this repository and verify the SHA-256 checksum.

On macOS 15 Sequoia and macOS 26 Tahoe: copy TinyPrune.app into /Applications, try opening it once, dismiss the Gatekeeper alert, then open System Settings > Privacy & Security > Open Anyway. Confirm Open and authenticate if prompted. Control-click Open is not a substitute on these macOS versions.

If you deliberately trust this preview and Open Anyway is unavailable, run exactly:

    xattr -dr com.apple.quarantine /Applications/TinyPrune.app

Then open /Applications/TinyPrune.app again. This removes quarantine, not proof of safety; it does not notarize the app. Finder extension and launch-at-login may need separate approval in System Settings > General > Login Items & Extensions. In-app updates are disabled for unsigned previews; download updates manually. Preview signing does not guarantee Finder extension or login-item activation on every Mac.'''

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def tag():
    value = os.environ['RELEASE_TAG']
    if not re.fullmatch(r'v\d+\.\d+\.\d+', value):
        raise ValueError('Expected vX.Y.Z release tag')
    return value

def digest(path):
    with path.open('rb') as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
        return checksum.hexdigest()

def tools(root):
    root = root / 'tooling'
    root.mkdir(exist_ok=True)
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

def cask_text(version, checksum, url, signing):
    postflight = ''
    if signing == 'unsigned':
        postflight = '''  postflight do
    ohai "Unsigned preview: not notarized. Clearing quarantine only for this trusted release."
    ohai "Finder extension and launch-at-login may need approval in System Settings."
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/TinyPrune.app"]
  end

'''
    text = Path('Resources/Homebrew/tinyprune.rb.template').read_text()
    for key, value in {'VERSION': version, 'SHA256': checksum, 'URL': url, 'POSTFLIGHT': postflight}.items():
        text = text.replace('@' + key + '@', value)
    return text

def render():
    root, dmg, metadata, url = download('homebrew')
    destination = Path(os.environ['CASK_OUTPUT'])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(cask_text(tag()[1:], digest(dmg), url, metadata['signing']))

def verify_bundle_key(root, dmg, signature):
    mount = root / 'verify-update-mount'
    mount.mkdir(exist_ok=True)
    run('hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-mountpoint', str(mount))
    try:
        plist = mount / 'TinyPrune.app/Contents/Info.plist'
        public_key = subprocess.check_output(['plutil', '-extract', 'SUPublicEDKey', 'raw', '-o', '-', str(plist)], text=True).strip()
        enabled = subprocess.check_output(['plutil', '-extract', 'TinyPruneUpdatesEnabled', 'raw', '-o', '-', str(plist)], text=True).strip()
        if enabled != 'true' or not public_key:
            raise ValueError('Released direct app has no enabled, public-key-configured updater')
        run('swift', 'Scripts/verify-update-signature.swift', public_key, str(dmg), signature)
    finally:
        run('hdiutil', 'detach', str(mount))

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
    key_input = (os.environ['SPARKLE_ED25519_PRIVATE_KEY'] + '\n').encode()
    signature = run(str(bin_path / 'sign_update'), '--ed-key-file', '-', '-p', str(dmg), input=key_input, stdout=subprocess.PIPE).stdout.decode().strip()
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(dmg), signature, input=key_input)
    verify_bundle_key(root, dmg, signature)
    ET.register_namespace('sparkle', NS)
    matched = 0
    note_path = output / (tag()[1:] + '.html')
    note_path.write_text(note)
    note_signature = run(str(bin_path / 'sign_update'), '--ed-key-file', '-', '--disable-signing-warning', '-p', str(note_path), input=key_input, stdout=subprocess.PIPE).stdout.decode().strip()
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(note_path), note_signature, input=key_input)
    for item in tree.findall('./channel/item'):
        enclosure = item.find('enclosure')
        if enclosure is not None and enclosure.get('url') == url:
            matched += 1
            enclosure.set('{' + NS + '}edSignature', signature)
            if enclosure.get('length') != str(dmg.stat().st_size):
                raise ValueError('Generated enclosure length mismatch')
            notes_link = item.find('{' + NS + '}releaseNotesLink')
            if notes_link is not None:
                notes_link.text = 'https://tinyprune.com/updates/' + tag()[1:] + '.html'
                notes_link.set('{' + NS + '}edSignature', note_signature)
                notes_link.set('{' + NS + '}length', str(note_path.stat().st_size))
    if matched != 1:
        raise ValueError('Generated appcast must contain exactly one released enclosure')
    tree.write(output / 'appcast.xml', encoding='utf-8', xml_declaration=True)
    # Sign the final bytes AFTER all enclosure/note URL and signature mutations.
    run(str(bin_path / 'sign_update'), '--ed-key-file', '-', '-p', str(output / 'appcast.xml'), input=key_input)
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(output / 'appcast.xml'), input=key_input)

def verify():
    root, dmg, metadata, url = download('direct')
    if metadata['signing'] != 'signed':
        print('Unsigned preview has no stable feed entry; verification skipped.')
        return
    bin_path = tools(root)
    key_input = (os.environ['SPARKLE_ED25519_PRIVATE_KEY'] + '\n').encode()
    public_feed = root / 'public-appcast.xml'
    with urllib.request.urlopen('https://tinyprune.com/updates/appcast.xml', timeout=30) as response:
        public_feed.write_bytes(response.read())
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(public_feed), input=key_input)
    tree = ET.parse(public_feed).getroot()
    matches = [e for e in tree.findall('./channel/item/enclosure') if e.get('url') == url]
    if len(matches) != 1 or matches[0].get('length') != str(dmg.stat().st_size):
        raise ValueError('Public feed enclosure URL/length does not match release')
    signature = matches[0].get('{' + NS + '}edSignature')
    if not signature:
        raise ValueError('Public enclosure has no EdDSA signature')
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(dmg), signature, input=key_input)
    verify_bundle_key(root, dmg, signature)
    item = next(item for item in tree.findall('./channel/item') if item.find('enclosure') is not None and item.find('enclosure').get('url') == url)
    notes_link = item.find('{' + NS + '}releaseNotesLink')
    expected_notes_url = 'https://tinyprune.com/updates/' + tag()[1:] + '.html'
    if notes_link is None or notes_link.text != expected_notes_url:
        raise ValueError('Public release notes URL does not match release')
    public_notes = root / 'public-notes.html'
    with urllib.request.urlopen(expected_notes_url, timeout=30) as response:
        public_notes.write_bytes(response.read())
    notes_signature = notes_link.get('{' + NS + '}edSignature')
    if not notes_signature or notes_link.get('{' + NS + '}length') != str(public_notes.stat().st_size):
        raise ValueError('Public release notes signature/length is missing or mismatched')
    run(str(bin_path / 'sign_update'), '--verify', '--ed-key-file', '-', str(public_notes), notes_signature, input=key_input)
    print('Public signed feed, direct enclosure URL/length/signature and release notes verified.')

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
