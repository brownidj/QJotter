import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:qjotter/app_services.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sqlite_notes_store.dart';

import 'support/account_fakes.dart';

class RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final stores = <SqliteNotesStore>[];
  final services = <AppServices>[];
  final apis = <AccountApi>[];
  Future<SqliteNotesStore> store(String name) async {
    final result = await NotesStore.open(Directory('${temp.path}/$name'));
    stores.add(result);
    return result;
  }

  setUp(
    () async =>
        temp = await Directory.systemTemp.createTemp('notefile-accounts-'),
  );
  tearDown(() async {
    for (final item in services) {
      item.dispose();
    }
    services.clear();
    for (final api in apis) {
      api.close();
    }
    apis.clear();
    for (final item in stores) {
      item.close();
    }
    stores.clear();
    await temp.delete(recursive: true);
  });

  test(
    'Startup defaults on once and respects opting out and OS changes',
    () async {
      final db = await store('startup');
      final startup = FakeStartupManager();
      AppServices make() {
        final result = AppServices(
          store: db,
          vault: MemorySessionVault(),
          startup: startup,
          automaticSync: false,
        );
        services.add(result);
        return result;
      }

      final first = make();
      await first.initialize();
      expect(startup.changes, [true]);
      await first.setAutoload(false);
      await make().initialize();
      expect(startup.changes, [true, false]);
      expect(db.setting('autoload'), 'false');
      expect(startup.current.enabled, isFalse);
    },
  );

  test(
    'A failed startup registration is shown and is not claimed as enabled',
    () async {
      final startup = FakeStartupManager()..fail = true;
      final service = AppServices(
        store: await store('startup-fail'),
        vault: MemorySessionVault(),
        startup: startup,
        automaticSync: false,
      );
      services.add(service);
      await service.initialize();
      expect(service.startupStatus.enabled, isFalse);
      expect(service.startupError, isNotNull);
    },
  );

  test('The LAN HTTPS address accepts copied invisible formatting', () {
    for (final address in [
      'https://davids-mac-mini.local:8766',
      ' HTTPS://davids-mac-mini.local:8766/ ',
      '\u200bhttps://davids-mac-mini.local:8766\u200b',
      '\ufeffhttps://davids-mac-mini.local:8766\u2060',
    ]) {
      expect(
        AccountApi.validateServer(address),
        'https://davids-mac-mini.local:8766',
      );
    }
  });

  test('A missing HTTPS slash pair explains the correct address format', () {
    expect(
      () => AccountApi.validateServer('https:davids-mac-mini.local:8766'),
      throwsA(
        isA<AccountError>().having(
          (error) => error.message,
          'message',
          contains('https://davids-mac-mini.local:8766'),
        ),
      ),
    );
  });

  test(
    'Remote credentials require HTTPS and cannot follow embedded user info',
    () {
      expect(
        () => AccountApi.validateServer('http://example.com'),
        throwsA(isA<AccountError>()),
      );
      expect(
        () => AccountApi.validateServer('https://name:secret@example.com'),
        throwsA(isA<AccountError>()),
      );
      expect(
        () => AccountApi.validateServer('https://example.com?token=x'),
        throwsA(isA<AccountError>()),
      );
      expect(
        AccountApi.validateServer('http://127.0.0.1:8765/'),
        'http://127.0.0.1:8765',
      );
    },
  );

  test('Two devices sync through the real server with account isolation and sign-out', () async {
    final process = await Process.start('python3', [
      'server/notefile_server.py',
      '--database',
      '${temp.path}/server.sqlite3',
      '--port',
      '0',
      '--allow-registration',
    ]);
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    final port = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line)!.group(1);
    final server = 'http://127.0.0.1:$port';
    final a = await store('device-a');
    final b = await store('device-b');
    await a.save(a.initialSnapshot.editSelected('Unsigned device note'));
    final vault = MemorySessionVault();
    final sa = AppServices(
      api: AccountApi(
        client: IOClient(RealHttpOverrides().createHttpClient(null)),
      ),
      store: a,
      vault: vault,
      startup: FakeStartupManager(),
      automaticSync: false,
    );
    final sb = AppServices(
      api: AccountApi(
        client: IOClient(RealHttpOverrides().createHttpClient(null)),
      ),
      store: b,
      vault: MemorySessionVault(),
      startup: FakeStartupManager(),
      automaticSync: false,
    );
    services.addAll([sa, sb]);
    await sa.initialize();
    await sb.initialize();
    await sa.signIn(
      server,
      'alice@example.test',
      'test passphrase only',
      create: true,
    );
    expect(a.initialSnapshot.selected.text, 'Unsigned device note');
    expect(a.pendingChanges(), isEmpty);
    expect(a.setting('deviceNotesAccount'), sa.session!.profile);
    await sb.signIn(server, 'alice@example.test', 'test passphrase only');
    expect(b.initialSnapshot.notes.map((n) => n.text), [
      'Unsigned device note',
    ]);
    await b.save(b.initialSnapshot.editSelected('Edited from device B 📝'));
    await sb.sync();
    await sa.sync();
    expect(a.initialSnapshot.selected.text, 'Edited from device B 📝');
    await sa.signOut();
    expect(a.profile, 'device');
    expect(a.initialSnapshot.selected.text, 'Unsigned device note');
    expect(vault.session, isNull);
    await sa.signIn(server, 'alice@example.test', 'test passphrase only');
    expect(a.initialSnapshot.notes.map((n) => n.text), [
      'Edited from device B 📝',
    ]);
    await sa.signOut();
    await sa.signIn(
      server,
      'bob@example.test',
      'different passphrase only',
      create: true,
    );
    expect(a.initialSnapshot.selected.text, isEmpty);
    expect(a.pendingChanges(), isEmpty);
    await expectLater(
      sa.signIn(server, 'alice@example.test', 'wrong password'),
      throwsA(isA<AccountError>()),
    );
    expect(sa.session!.email, 'bob@example.test');
    expect(errors.toString(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test(
    'Private HTTPS certificates enable sync without disabling hostname checks',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final cert = '${temp.path}/server.pem';
        final key = '${temp.path}/server-key.pem';
        final config = File('${temp.path}/openssl.cnf');
        await config.writeAsString(
          '[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=server\n[dn]\nCN=127.0.0.1\n[server]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n',
        );
        final generated = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-sha256',
          '-nodes',
          '-days',
          '1',
          '-config',
          config.path,
          '-keyout',
          key,
          '-out',
          cert,
        ]);
        expect(generated.exitCode, 0);
        final pem = await File(cert).readAsString();
        final process = await Process.start('python3', [
          'server/notefile_server.py',
          '--database',
          '${temp.path}/https.sqlite3',
          '--port',
          '0',
          '--allow-registration',
          '--tls-cert',
          cert,
          '--tls-key',
          key,
        ]);
        process.stderr.drain<void>();
        addTearDown(() async {
          process.kill();
          await process.exitCode;
        });
        final line = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        final port = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(line)!.group(1);
        final server = 'https://127.0.0.1:$port';
        final untrusted = AccountApi();
        final trusted = AccountApi(certificateForServer: (_) => pem);
        apis.addAll([untrusted, trusted]);
        await expectLater(
          untrusted.signIn(
            server,
            'https@example.test',
            'test passphrase only',
            create: true,
          ),
          throwsA(
            isA<AccountError>().having(
              (error) => error.message,
              'message',
              contains('HTTPS certificate'),
            ),
          ),
        );
        final session = await trusted.signIn(
          server,
          'https@example.test',
          'test passphrase only',
          create: true,
        );
        final configuredStore = await store('private-build');
        final configured = AppServices(
          store: configuredStore,
          vault: MemorySessionVault(),
          startup: FakeStartupManager(),
          automaticSync: false,
          defaultServer: server,
          defaultCertificate: pem,
        );
        services.add(configured);
        await configured.initialize();
        await configured.checkServerConnection();
        expect(configuredStore.setting('serverVerified:$server'), isNotNull);
        await configured.signIn(
          server,
          'https@example.test',
          'test passphrase only',
        );
        expect(configured.syncStatus, 'Saved to server');
        final note = {
          'id': 'https-note',
          'text': 'Encrypted sync fixture',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'updatedAt': DateTime.utc(2026).toIso8601String(),
          'mutationId': 'https-edit',
          'baseVersion': 0,
          'deleted': false,
        };
        final response = await trusted.sync(session, [note]);
        expect(
          (response['notes'] as List).single['text'],
          'Encrypted sync fixture',
        );
        await expectLater(
          trusted.signIn(
            'https://localhost:$port',
            'https@example.test',
            'test passphrase only',
          ),
          throwsA(isA<AccountError>()),
        );
        expect(
          () => AccountApi.validateCertificate('-----BEGIN PRIVATE KEY-----'),
          throwsA(isA<AccountError>()),
        );
        final issued = await Process.run('python3', [
          '-c',
          'import sys; sys.path.insert(0, "server"); from notefile_server import Api; '
              'print(Api(sys.argv[1]).issue_password_reset(sys.argv[2]))',
          '${temp.path}/https.sqlite3',
          'https@example.test',
        ]);
        expect(issued.exitCode, 0);
        await trusted.resetPassword(
          server, 'https@example.test', (issued.stdout as String).trim(),
          'new recovery test passphrase',
        );
        await expectLater(trusted.sync(session, []), throwsA(isA<AccountError>()));
        final recovered = await trusted.signIn(
          server, 'https@example.test', 'new recovery test passphrase',
        );
        expect(recovered.userId, session.userId);
        final recoveredNotes = await trusted.sync(recovered, []);
        expect((recoveredNotes['notes'] as List).single['text'], 'Encrypted sync fixture');
      }, RealHttpOverrides());
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
