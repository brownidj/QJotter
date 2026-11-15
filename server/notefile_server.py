"""Notefile's account-isolated SQLite API. Run behind an HTTPS reverse proxy."""
import argparse
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import ssl
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 8 * 1024 * 1024
SESSION_SECONDS = 30 * 24 * 60 * 60
RESET_SECONDS = 30 * 60


class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def password_hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)


class Api:
    def __init__(self, database, allow_registration=False):
        self.database = str(database)
        self.allow_registration = allow_registration
        self._attempts = {}
        self._lock = threading.Lock()
        with self.connect() as db:
            if db.execute('PRAGMA user_version').fetchone()[0] > 1:
                raise ValueError('Unsupported server database version.')
            db.execute('PRAGMA journal_mode=WAL')
            db.executescript('''
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL,
                    salt BLOB NOT NULL, password_hash BLOB NOT NULL, revision INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS notes (
                    user_id TEXT NOT NULL REFERENCES users(id), id TEXT NOT NULL, text TEXT NOT NULL,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted INTEGER NOT NULL,
                    version INTEGER NOT NULL, PRIMARY KEY(user_id, id));
                CREATE TABLE IF NOT EXISTS operations (
                    user_id TEXT NOT NULL REFERENCES users(id), mutation_id TEXT NOT NULL,
                    PRIMARY KEY(user_id, mutation_id));
                CREATE TABLE IF NOT EXISTS operation_results (
                    user_id TEXT NOT NULL REFERENCES users(id), mutation_id TEXT NOT NULL,
                    source_id TEXT NOT NULL, note_id TEXT NOT NULL, version INTEGER NOT NULL,
                    PRIMARY KEY(user_id, mutation_id));
                CREATE TABLE IF NOT EXISTS password_resets (
                    token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
                    expires INTEGER NOT NULL);
                PRAGMA user_version=1;
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()

    def _rate_limit(self, peer):
        now = time.monotonic()
        with self._lock:
            self._attempts = {key: value for key, value in self._attempts.items() if value[0] > now - 600}
            started, count = self._attempts.get(peer, (now, 0))
            if count >= 20 or len(self._attempts) >= 10000:
                raise ApiError(429, 'Too many sign-in attempts. Please try again later.')
            self._attempts[peer] = (started, count + 1)

    @staticmethod
    def _session(db, user):
        token = secrets.token_urlsafe(32)
        db.execute('DELETE FROM sessions WHERE expires < ?', (int(time.time()),))
        db.execute('INSERT INTO sessions VALUES (?, ?, ?)',
                   (hashlib.sha256(token.encode()).hexdigest(), user['id'], int(time.time()) + SESSION_SECONDS))
        return {'userId': user['id'], 'email': user['email'], 'token': token}

    def auth(self, route, data, peer):
        self._rate_limit(peer)
        email, password = data.get('email'), data.get('password')
        if not isinstance(email, str) or not isinstance(password, str) or len(password) > 1024:
            raise ApiError(400, 'Enter a valid email and password.')
        email = email.strip().lower()
        if len(email) > 254 or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
            raise ApiError(400, 'Enter a valid email address.')
        with self.connect() as db:
            if route == 'register':
                if not self.allow_registration:
                    raise ApiError(403, 'Account registration is disabled on this server. Contact its administrator.')
                if len(password) < 12:
                    raise ApiError(400, 'Use a password of at least 12 characters.')
                salt = secrets.token_bytes(16)
                try:
                    db.execute('INSERT INTO users(id,email,salt,password_hash) VALUES (?,?,?,?)',
                               (str(uuid.uuid4()), email, salt, password_hash(password, salt)))
                except sqlite3.IntegrityError:
                    raise ApiError(409, 'An account with that email already exists.') from None
            user = db.execute('SELECT * FROM users WHERE email=?', (email,)).fetchone()
            salt = user['salt'] if user else bytes(16)
            actual = password_hash(password, salt)
            if not user or not hmac.compare_digest(actual, user['password_hash']):
                raise ApiError(401, 'Incorrect email or password.')
            return self._session(db, user)

    def issue_password_reset(self, email):
        """Local administrator operation. Never expose issuance as an HTTP route."""
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            user = db.execute('SELECT id FROM users WHERE email=?', (email.strip().lower(),)).fetchone()
            if not user:
                raise ApiError(404, 'No account has that email address.')
            token = secrets.token_urlsafe(32)
            db.execute('DELETE FROM password_resets WHERE user_id=? OR expires<=?',
                       (user['id'], int(time.time())))
            db.execute('INSERT INTO password_resets VALUES (?,?,?)',
                       (hashlib.sha256(token.encode()).hexdigest(), user['id'], int(time.time()) + RESET_SECONDS))
            return token

    def reset_password(self, data, peer):
        self._rate_limit(peer)
        email, token, password = data.get('email'), data.get('code'), data.get('password')
        if not isinstance(email, str) or not isinstance(token, str) or not 1 <= len(token) <= 256:
            raise ApiError(400, 'Invalid or expired recovery code. Ask the server administrator for a new code.')
        if not isinstance(password, str) or not 12 <= len(password) <= 1024:
            raise ApiError(400, 'Use a password of 12 to 1,024 characters.')
        # Compute outside the write transaction to keep sync writes responsive.
        salt = secrets.token_bytes(16)
        hashed = password_hash(password, salt)
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            reset = db.execute('''SELECT r.user_id FROM password_resets r
                JOIN users u ON u.id=r.user_id
                WHERE r.token_hash=? AND r.expires>? AND u.email=?''',
                (hashlib.sha256(token.encode()).hexdigest(), int(time.time()), email.strip().lower())).fetchone()
            if not reset:
                raise ApiError(400, 'Invalid or expired recovery code. Ask the server administrator for a new code.')
            db.execute('UPDATE users SET salt=?, password_hash=? WHERE id=?', (salt, hashed, reset['user_id']))
            db.execute('DELETE FROM sessions WHERE user_id=?', (reset['user_id'],))
            db.execute('DELETE FROM password_resets WHERE user_id=?', (reset['user_id'],))
        return {'ok': True}

    @staticmethod
    def _authorized(db, token):
        if not isinstance(token, str) or len(token) > 256:
            raise ApiError(401, 'Sign in again.')
        digest = hashlib.sha256(token.encode()).hexdigest()
        session = db.execute('SELECT user_id FROM sessions WHERE token_hash=? AND expires>?', (digest, int(time.time()))).fetchone()
        if not session:
            raise ApiError(401, 'Sign in again.')
        return session['user_id'], digest

    @staticmethod
    def _validate_change(change):
        if not isinstance(change, dict):
            raise ApiError(400, 'Invalid note change.')
        for field in ('id', 'text', 'createdAt', 'updatedAt', 'mutationId'):
            if not isinstance(change.get(field), str):
                raise ApiError(400, 'Invalid note change.')
        if not change['id'] or len(change['id']) > 128 or len(change['mutationId']) > 128 or not change['mutationId']:
            raise ApiError(400, 'Invalid note identifier.')
        if len(change['text'].encode()) > 256 * 1024:
            raise ApiError(413, 'A note exceeds the 256 KB sync limit.')
        if type(change.get('baseVersion')) is not int or change['baseVersion'] < 0 or type(change.get('deleted')) is not bool:
            raise ApiError(400, 'Invalid note version.')
        try:
            for field in ('createdAt', 'updatedAt'):
                if len(change[field]) > 40 or datetime.fromisoformat(change[field].replace('Z', '+00:00')).tzinfo is None:
                    raise ValueError()
        except ValueError:
            raise ApiError(400, 'Invalid note date.') from None

    def sync(self, token, data):
        changes = data.get('changes')
        if not isinstance(changes, list) or len(changes) > 1000:
            raise ApiError(400, 'Send at most 1,000 changes at a time.')
        for change in changes:
            self._validate_change(change)
        with self.connect() as db:
            # Serialize revision checks and writes across devices.
            db.execute('BEGIN IMMEDIATE')
            user_id, _ = self._authorized(db, token)
            revision = db.execute('SELECT revision FROM users WHERE id=?', (user_id,)).fetchone()[0]
            acknowledged = []
            resolved = []
            # Retire legacy empty entries as tombstones so every client removes them.
            for row in db.execute('SELECT * FROM notes WHERE user_id=? AND deleted=0', (user_id,)).fetchall():
                if not row['text'].strip():
                    revision += 1
                    db.execute('UPDATE notes SET deleted=1,version=? WHERE user_id=? AND id=?',
                               (revision, user_id, row['id']))
            for change in changes:
                if not change['text'].strip():
                    change = {**change, 'deleted': True}
                mutation = change['mutationId']
                acknowledged.append(mutation)
                if db.execute('SELECT 1 FROM operations WHERE user_id=? AND mutation_id=?', (user_id, mutation)).fetchone():
                    result = db.execute('SELECT * FROM operation_results WHERE user_id=? AND mutation_id=?', (user_id, mutation)).fetchone()
                    if result:
                        resolved.append({'mutationId': mutation, 'sourceId': result['source_id'],
                                         'noteId': result['note_id'], 'version': result['version']})
                    continue
                old = db.execute('SELECT * FROM notes WHERE user_id=? AND id=?', (user_id, change['id'])).fetchone()
                if old is None and change['deleted']:
                    # A blank draft must never become a server entry.
                    db.execute('INSERT INTO operations VALUES (?,?)', (user_id, mutation))
                    continue
                conflict = (old['version'] if old else 0) != change['baseVersion']
                note_id = change['id']
                if conflict and change['deleted']:
                    # A stale delete must not remove a newer edit.
                    db.execute('INSERT INTO operations VALUES (?,?)', (user_id, mutation))
                    continue
                if conflict:
                    # Preserve both versions instead of guessing which edit should win.
                    note_id = str(uuid.uuid4())
                    change = {**change, 'text': change['text'] + '\n\n[Conflict copy: edited on another device.]'}
                revision += 1
                db.execute('''INSERT INTO notes VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(user_id,id) DO UPDATE SET text=excluded.text,
                    updated_at=excluded.updated_at, deleted=excluded.deleted, version=excluded.version''',
                    (user_id, note_id, change['text'], change['createdAt'], change['updatedAt'], int(change['deleted']), revision))
                db.execute('INSERT INTO operations VALUES (?,?)', (user_id, mutation))
                db.execute('INSERT INTO operation_results VALUES (?,?,?,?,?)',
                           (user_id, mutation, change['id'], note_id, revision))
                resolved.append({'mutationId': mutation, 'sourceId': change['id'],
                                 'noteId': note_id, 'version': revision})
            quota = db.execute('SELECT COUNT(*), COALESCE(SUM(length(CAST(text AS BLOB))),0) FROM notes WHERE user_id=?', (user_id,)).fetchone()
            if quota[0] > 1000 or quota[1] > MAX_BODY:
                raise ApiError(413, 'This account exceeds the prototype sync limit of 1,000 notes or 8 MB.')
            db.execute('UPDATE users SET revision=? WHERE id=?', (revision, user_id))
            notes = [{'id': row['id'], 'text': row['text'], 'createdAt': row['created_at'],
                      'updatedAt': row['updated_at'], 'deleted': bool(row['deleted']), 'version': row['version']}
                     for row in db.execute('SELECT * FROM notes WHERE user_id=? ORDER BY version', (user_id,))]
            return {'notes': notes, 'acknowledged': acknowledged, 'resolved': resolved}

    def handle(self, route, data, token=None, peer='local'):
        if route in ('register', 'login'):
            return self.auth(route, data, peer)
        if route == 'reset-password':
            return self.reset_password(data, peer)
        if route == 'sync':
            return self.sync(token, data)
        if route == 'logout':
            with self.connect() as db:
                _, digest = self._authorized(db, token)
                db.execute('DELETE FROM sessions WHERE token_hash=?', (digest,))
            return {'ok': True}
        raise ApiError(404, 'Unknown endpoint.')


class Handler(BaseHTTPRequestHandler):
    server_version = 'Notefile/1'
    def reply(self, status, body):
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        self.reply(200, {'ok': True}) if self.path == '/health' else self.reply(404, {'error': 'Unknown endpoint.'})

    def do_POST(self):
        self.connection.settimeout(15)
        try:
            if not self.path.startswith('/v1/') or '?' in self.path:
                raise ApiError(404, 'Unknown endpoint.')
            length = int(self.headers.get('Content-Length', '0'))
            if length <= 0 or length > MAX_BODY or self.headers.get('Transfer-Encoding'):
                raise ApiError(413, 'Invalid request size.')
            if self.headers.get_content_type() != 'application/json':
                raise ApiError(415, 'Send JSON.')
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ApiError(400, 'Send a JSON object.')
            auth = self.headers.get('Authorization', '')
            token = auth[7:] if auth.startswith('Bearer ') else None
            response = self.server.api.handle(self.path[4:], data, token, self.client_address[0])
            self.reply(200, response)
        except ApiError as error:
            self.reply(error.status, {'error': error.message})
        except (ValueError, UnicodeError):
            self.reply(400, {'error': 'Invalid JSON request.'})
        except (sqlite3.Error, OSError):
            self.reply(503, {'error': 'Server unavailable. Retry later.'})

    def log_message(self, fmt, *args):
        # Never log credentials, tokens or note bodies.
        pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, api):
        self.api = api
        self.tls_context = None
        super().__init__(address, Handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(15)
        if self.tls_context:
            # Handshake in the request thread, so a slow client cannot block
            # the accept loop for every other device.
            connection = self.tls_context.wrap_socket(connection, server_side=True, do_handshake_on_connect=False)
        return connection, address


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', default='notefile-server.sqlite3')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--allow-registration', action='store_true')
    parser.add_argument('--tls-cert', help='PEM server certificate for direct HTTPS')
    parser.add_argument('--tls-key', help='PEM private key for direct HTTPS')
    args = parser.parse_args()
    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error('--tls-cert and --tls-key must be supplied together')
    Path(args.database).parent.mkdir(parents=True, exist_ok=True)
    server = Server((args.host, args.port), Api(args.database, args.allow_registration))
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.tls_context = context
    protocol = 'HTTPS' if args.tls_cert else 'HTTP'
    print(f'Notefile {protocol} API listening on {args.host}:{server.server_port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
