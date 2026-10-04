#!/usr/bin/env python3
"""Real unsigned cask installation on a disposable GitHub-hosted macOS runner only."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading

import distribution


def run(*args, **kwargs):
    return subprocess.run(args, check=True, timeout=180, **kwargs)


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise RuntimeError('This smoke installs/uninstalls a cask; use only a disposable GitHub-hosted runner.')
    repository = Path(__file__).resolve().parent.parent
    os.chdir(repository)
    app = repository / '.build/package/TinyPrune.app'
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('TinyPruneDistribution') != 'homebrew' or info.get('TinyPruneSigning') != 'ad-hoc':
        raise RuntimeError('Expected the actual ad-hoc Homebrew distribution bundle.')
    if info.get('TinyPruneUpdatesEnabled') or info.get('SUEnableAutomaticChecks'):
        raise RuntimeError('Homebrew build must disable in-app updates.')
    prefix = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip())
    linked_cli = prefix / 'bin/tinyprune'
    operational_state = Path.home() / 'Library/Application Support/TinyPrune/state.sqlite3'
    if linked_cli.exists() or linked_cli.is_symlink() or operational_state.exists() or Path('/Applications/TinyPrune.app').exists():
        raise RuntimeError('Runner contains an existing TinyPrune installation or operational state.')
    environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_INSTALL_FROM_API='1', HOMEBREW_NO_ANALYTICS='1')
    tap = f'local/tinyprune-smoke-{os.environ["GITHUB_RUN_ID"]}-{os.environ["GITHUB_RUN_ATTEMPT"]}'
    cask = tap + '/tinyprune'
    run('brew', '--version', env=environment)
    with tempfile.TemporaryDirectory(prefix='tinyprune-install-') as temporary:
        root = Path(temporary)
        stage = root / 'stage'
        environment['XDG_CONFIG_HOME'] = str(root / 'config')
        stage.mkdir()
        run('ditto', str(app), str(stage / 'TinyPrune.app'))
        dmg = root / 'TinyPrune.dmg'
        run('hdiutil', 'create', '-volname', 'TinyPrune smoke', '-srcfolder', str(stage), '-format', 'UDZO', str(dmg))
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        tap_created = False
        try:
            run('brew', 'tap-new', tap, env=environment)
            tap_created = True
            tap_directory = Path(subprocess.check_output(['brew', '--repo', tap], text=True, env=environment).strip())
            cask_directory = tap_directory / 'Casks'
            cask_directory.mkdir(exist_ok=True)
            run('brew', 'trust', '--tap', tap, env=environment)
            url = f'http://127.0.0.1:{server.server_port}/TinyPrune.dmg'
            (cask_directory / 'tinyprune.rb').write_text(distribution.cask_text(info['CFBundleShortVersionString'], distribution.digest(dmg), url, 'unsigned'))
            apps = root / 'apps'
            apps.mkdir()
            run('brew', 'install', '--verbose', '--cask', f'--appdir={apps}', cask, env=environment)
            installed = apps / 'TinyPrune.app'
            run('codesign', '--verify', '--deep', '--strict', str(installed))
            with (installed / 'Contents/Info.plist').open('rb') as stream:
                installed_info = plistlib.load(stream)
            if installed_info.get('TinyPruneDistribution') != 'homebrew' or installed_info.get('TinyPruneUpdatesEnabled') or installed_info.get('SUEnableAutomaticChecks'):
                raise RuntimeError('Installed bundle lost Homebrew channel separation.')
            bundled_cli = installed / 'Contents/MacOS/tinyprune'
            if linked_cli.resolve() != bundled_cli.resolve():
                raise RuntimeError('Homebrew did not link the actual bundled CLI.')
            for executable in [bundled_cli, linked_cli]:
                result = subprocess.run([str(executable), 'status', '--json'], capture_output=True, text=True, timeout=30)
                if result.returncode != 69 or json.loads(result.stdout) != {'schemaVersion': 1, 'status': 'unavailable'} or result.stderr:
                    raise RuntimeError(f'Fresh-runner CLI contract failed: {result.returncode}, {result.stdout}, {result.stderr}')
            attributes = subprocess.check_output(['xattr', str(installed)], text=True).splitlines()
            if 'com.apple.quarantine' in attributes:
                raise RuntimeError('Unsigned cask postflight did not clear app quarantine.')
            print('PASS: unattended cask installation, sealed bundle, Homebrew-only updates, linked/bundled CLI and unsigned postflight; agent intentionally not registered.')
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            if tap_created:
                # No zap: cleanup only this receipt/app/link on the fresh runner.
                subprocess.run(['brew', 'uninstall', '--cask', '--force', cask], env=environment, timeout=60, check=False)
                run('brew', 'untap', tap, env=environment)


if __name__ == '__main__':
    main()
