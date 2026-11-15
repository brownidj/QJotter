"""Install and manage a private, per-user macOS Notefile server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.request
from contextlib import closing
from datetime import datetime, timedelta, timezone

LABEL = 'com.example.notefile.server'
ROOT = Path.home() / 'Library/Application Support/NotefileServer'
PLIST = Path.home() / 'Library/LaunchAgents' / f'{LABEL}.plist'
DOMAIN = f'gui/{os.getuid()}'
BACKUP_LABEL = 'com.example.notefile.backup'
BACKUP_PLIST = PLIST.with_name(f'{BACKUP_LABEL}.plist')


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def secure_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def read_config():
    return json.loads((ROOT / 'config.json').read_text())


def save_config(config):
    target = ROOT / 'config.json'
    temporary = ROOT / 'config.json.next'
    temporary.write_text(json.dumps(config, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(target)


def service_loaded(label=LABEL):
    return run('launchctl', 'print', f'{DOMAIN}/{label}', check=False).returncode == 0


def stop():
    if service_loaded():
        run('launchctl', 'bootout', f'{DOMAIN}/{LABEL}')


def write_plist(config):
    arguments = [config['python'], '-u', str(ROOT / 'app/notefile_server.py'),
                 '--database', config['database'], '--host', config['listen_host'],
                 '--port', str(config['port']), '--tls-cert', config['certificate'],
                 '--tls-key', config['private_key']]
    if config['allow_registration']:
        arguments.append('--allow-registration')
    if config.get('keep_awake', True):
        # Hold an idle-sleep assertion only for the server's lifetime. The
        # display can sleep, and no administrator-level power setting changes.
        arguments = ['/usr/bin/caffeinate', '-i', *arguments]
    plist = {'Label': LABEL, 'ProgramArguments': arguments,
             'WorkingDirectory': str(ROOT), 'RunAtLoad': True, 'KeepAlive': True,
             'ThrottleInterval': 10, 'Umask': 0o077,
             'StandardOutPath': str(ROOT / 'logs/server.log'),
             'StandardErrorPath': str(ROOT / 'logs/server-error.log'),
             'EnvironmentVariables': {'PYTHONUNBUFFERED': '1', 'PYTHONDONTWRITEBYTECODE': '1'}}
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    temporary = PLIST.with_suffix('.plist.next')
    temporary.write_bytes(plistlib.dumps(plist))
    temporary.chmod(0o600)
    temporary.replace(PLIST)
    run('plutil', '-lint', str(PLIST))


def start():
    if not service_loaded():
        run('launchctl', 'enable', f'{DOMAIN}/{LABEL}')
        run('launchctl', 'bootstrap', DOMAIN, str(PLIST))


def health(config):
    context = ssl.create_default_context(cafile=config['certificate'])
    url = f"https://127.0.0.1:{config['port']}/health"
    with urllib.request.urlopen(url, context=context, timeout=3) as response:
        return json.load(response) == {'ok': True}


def wait_for_health(config):
    for _ in range(30):
        try:
            if health(config):
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.3)
    raise RuntimeError(f'Server did not become healthy. Check {ROOT / "logs/server-error.log"}')


def backup(config, scheduled=False):
    source = Path(config['database'])
    if not source.exists():
        return None
    secure_directory(ROOT / 'backups')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    prefix = 'scheduled' if scheduled else 'notefile'
    target = ROOT / 'backups' / f'{prefix}-{stamp}.sqlite3'
    temporary = target.with_suffix('.sqlite3.partial')
    temporary.touch(mode=0o600, exist_ok=False)
    # sqlite3.backup includes committed WAL writes while the service is online.
    try:
        with closing(sqlite3.connect(f'{source.resolve().as_uri()}?mode=ro', uri=True)) as src:
            with closing(sqlite3.connect(temporary)) as dst:
                src.backup(dst)
                if dst.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                    raise RuntimeError('Backup integrity check failed.')
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def prune_backups(config):
    """Only expire scheduled copies, preserving at least 30 successful copies."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=config.get('backup_retention_days', 30))
    copies = sorted((ROOT / 'backups').glob('scheduled-*.sqlite3'), reverse=True)
    for path in copies[30:]:
        try:
            created = datetime.strptime(path.stem.removeprefix('scheduled-'), '%Y%m%dT%H%M%S%fZ').replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        if created < cutoff and path.is_file() and not path.is_symlink():
            path.unlink()


def scheduled_backup(config):
    import fcntl
    secure_directory(ROOT / 'backups')
    with (ROOT / 'backups/.scheduled.lock').open('a') as lock:
        lock_path = Path(lock.name)
        lock_path.chmod(0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        state_path = ROOT / 'backup-status.json'
        try:
            state = json.loads(state_path.read_text()) if state_path.exists() else {}
        except (ValueError, OSError):
            state = {}
        try:
            target = backup(config, scheduled=True)
            if target is None:
                raise RuntimeError('No server database exists.')
            prune_backups(config)
            state = {'last_success': datetime.now(timezone.utc).isoformat(), 'path': str(target), 'error': None}
            print(f'Scheduled backup verified: {target}')
        except Exception as error:
            state['error'] = str(error)
            state['last_failure'] = datetime.now(timezone.utc).isoformat()
            raise
        finally:
            temporary = state_path.with_suffix('.json.next')
            temporary.write_text(json.dumps(state, indent=2) + '\n')
            temporary.chmod(0o600)
            temporary.replace(state_path)


def configure_backups(config):
    if service_loaded(BACKUP_LABEL):
        run('launchctl', 'bootout', f'{DOMAIN}/{BACKUP_LABEL}')
    if not config.get('backups_enabled', False):
        run('launchctl', 'disable', f'{DOMAIN}/{BACKUP_LABEL}')
        return
    secure_directory(ROOT / 'logs')
    for name in ('backup.log', 'backup-error.log'):
        log = ROOT / 'logs' / name
        log.touch(mode=0o600, exist_ok=True)
        log.chmod(0o600)
    plist = {'Label': BACKUP_LABEL,
             'ProgramArguments': [config['python'], '-u', str(ROOT / 'app/manage_server.py'), 'scheduled-backup'],
             'WorkingDirectory': str(ROOT), 'RunAtLoad': True, 'Umask': 0o077,
             'StartCalendarInterval': {'Hour': config.get('backup_hour', 3), 'Minute': config.get('backup_minute', 0)},
             'StandardOutPath': str(ROOT / 'logs/backup.log'),
             'StandardErrorPath': str(ROOT / 'logs/backup-error.log'),
             'EnvironmentVariables': {'PYTHONDONTWRITEBYTECODE': '1'}}
    temporary = BACKUP_PLIST.with_suffix('.plist.next')
    temporary.write_bytes(plistlib.dumps(plist))
    temporary.chmod(0o600)
    temporary.replace(BACKUP_PLIST)
    run('plutil', '-lint', str(BACKUP_PLIST))
    run('launchctl', 'enable', f'{DOMAIN}/{BACKUP_LABEL}')
    run('launchctl', 'bootstrap', DOMAIN, str(BACKUP_PLIST))


def create_certificate(config, hostname, lan_ip):
    certificate, key = Path(config['certificate']), Path(config['private_key'])
    if certificate.exists() and key.exists():
        return
    if certificate.exists() or key.exists():
        raise RuntimeError('An incomplete certificate/key pair exists. Preserve it and inspect before reinstalling.')
    # Keep the generated certificate local to this application, not system-wide trust.
    san = ['DNS:localhost', f'DNS:{hostname}', 'IP:127.0.0.1']
    if lan_ip:
        import ipaddress
        san.append(f'IP:{ipaddress.ip_address(lan_ip)}')
    config_file = ROOT / 'tls/openssl.cnf'
    config_file.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=server\n'
                           f'[dn]\nCN={hostname}\n[server]\nbasicConstraints=critical,CA:FALSE\n'
                           'keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n'
                           'subjectAltName=' + ','.join(san) + '\n')
    config_file.chmod(0o600)
    run('openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
        '-days', '825', '-config', str(config_file), '-keyout', str(key), '-out', str(certificate))
    key.chmod(0o600)
    certificate.chmod(0o644)  # Public; the containing directory remains private.


def install(args):
    if sys.platform != 'darwin':
        raise RuntimeError('This installer manages macOS LaunchAgents. The server itself is portable.')
    for suffix in ('', 'app', 'data', 'tls', 'logs', 'backups'):
        secure_directory(ROOT / suffix)
    config_path = ROOT / 'config.json'
    if config_path.exists():
        config = read_config()
        if args.hostname and args.hostname.lower() != config['hostname'].lower():
            raise RuntimeError('This installation uses a different hostname. Follow the migration guide instead of overwriting its certificate.')
        saved = backup(config)
        if saved:
            print(f'Pre-update backup: {saved}')
    else:
        hostname = args.hostname or 'localhost'
        if not all(c.isalnum() or c in '.-' for c in hostname):
            raise RuntimeError('Use a hostname containing only letters, digits, periods and hyphens.')
        config = {'hostname': hostname, 'listen_host': '127.0.0.1' if args.local_only else '0.0.0.0',
                  'port': args.port, 'public_url': f'https://{hostname}:{args.port}',
                  'database': str(ROOT / 'data/notes.sqlite3'),
                  'certificate': str(ROOT / 'tls/notefile-server.pem'),
                  'private_key': str(ROOT / 'tls/notefile-server-key.pem'),
                  'allow_registration': True, 'python': str(Path(sys.executable).resolve())}
        with socket.socket() as probe:
            probe.bind((config['listen_host'], config['port']))
    create_certificate(config, config['hostname'], args.lan_ip)
    stop()
    for name in ('notefile_server.py', 'manage_server.py'):
        source = Path(__file__).with_name(name)
        temporary = ROOT / 'app' / f'{name}.next'
        shutil.copyfile(source, temporary)
        temporary.chmod(0o600)
        temporary.replace(ROOT / 'app' / name)
    save_config(config)
    for name in ('server.log', 'server-error.log'):
        log = ROOT / 'logs' / name
        log.touch(mode=0o600, exist_ok=True)
        log.chmod(0o600)
    write_plist(config)
    start()
    wait_for_health(config)
    if config.get('backups_enabled'):
        configure_backups(config)
    print(f"Server ready: {config['public_url']}")
    print(f"Public certificate: {config['certificate']}")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    setup = sub.add_parser('install')
    setup.add_argument('--hostname')
    setup.add_argument('--lan-ip')
    setup.add_argument('--port', type=int, default=8766)
    setup.add_argument('--local-only', action='store_true')
    for name in ('start', 'stop', 'status', 'backup', 'scheduled-backup'):
        sub.add_parser(name)
    backups = sub.add_parser('backups', help='Configure daily backups and a backup at each login.')
    backups.add_argument('state', choices=['on', 'off'])
    backups.add_argument('--hour', type=int, choices=range(24), default=3)
    backups.add_argument('--minute', type=int, choices=range(60), default=0)
    backups.add_argument('--retain-days', type=int, choices=range(1, 366), default=30)
    reset = sub.add_parser('issue-reset', help='Issue a one-use, 30-minute recovery code after verifying account ownership.')
    reset.add_argument('email')
    registration = sub.add_parser('registration')
    registration.add_argument('state', choices=['on', 'off'])
    args = parser.parse_args()
    if args.command == 'install':
        install(args)
        return
    config = read_config()
    if args.command == 'stop':
        stop()
        print('Server stopped. Its database and registration for next login are retained.')
    elif args.command == 'start':
        start()
        wait_for_health(config)
        print(f"Server ready: {config['public_url']}")
    elif args.command == 'backup':
        print(backup(config) or 'No server database exists yet.')
    elif args.command == 'scheduled-backup':
        scheduled_backup(config)
    elif args.command == 'backups':
        config.update(backups_enabled=args.state == 'on', backup_hour=args.hour,
                      backup_minute=args.minute, backup_retention_days=args.retain_days)
        save_config(config)
        configure_backups(config)
        print(f'Automatic backups: {args.state}; daily {args.hour:02}:{args.minute:02}, plus login; retention {args.retain_days} days (at least 30 copies).')
    elif args.command == 'issue-reset':
        from notefile_server import Api, ApiError
        try:
            api = Api(config['database'])
            # Back up before issuing recovery access. Do not change a password.
            saved = backup(config)
            code = api.issue_password_reset(args.email)
        except ApiError as error:
            raise RuntimeError(error.message) from None
        print(f'Pre-recovery backup: {saved}')
        print('Give this code privately to the verified account owner. It expires in 30 minutes and can be used once.')
        print(code)
        print('In Notefile Settings, choose Forgot password? and enter the code with a new password.')
    elif args.command == 'registration':
        config['allow_registration'] = args.state == 'on'
        stop()
        save_config(config)
        write_plist(config)
        start()
        wait_for_health(config)
        print(f'Account registration: {args.state}')
    else:
        print(f'LaunchAgent loaded: {service_loaded()}')
        print(f"Address: {config['public_url']}")
        print(f"Database: {config['database']}")
        print(f"Registration enabled: {config['allow_registration']}")
        print(f'HTTPS health: {health(config)}')
        pem = Path(config['certificate']).read_text()
        print('Certificate SHA-256: ' + hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest())
        print(f"Automatic backups enabled: {config.get('backups_enabled', False)}")
        print(f'Backup job loaded: {service_loaded(BACKUP_LABEL)}')
        status_path = ROOT / 'backup-status.json'
        if status_path.exists():
            state = json.loads(status_path.read_text())
            print(f"Last verified backup: {state.get('last_success', 'never')}")
            print(f"Backup error: {state.get('error') or 'none'}")


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f'Server management failed: {error}', file=sys.stderr)
        sys.exit(1)
