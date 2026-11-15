import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/app_services.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/server_configuration.dart';

import 'support/account_fakes.dart';

class MigrationApi extends AccountApi {
  bool offline = false;
  final destinations = <String>[];
  @override
  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) async {
    destinations.add(session.server);
    expect(changes, isEmpty); // Verify access before sending any pending edits.
    if (offline) throw const AccountError('Offline');
    return {'notes': [], 'acknowledged': []};
  }
}

class MigrationVault extends MemorySessionVault {
  bool failWrites = false;
  @override
  Future<void> write(AccountSession? value) async {
    if (failWrites) throw StateError('Keychain unavailable');
    await super.write(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['none', 'offline', 'keychain']) {
    test('Server migration preserves pending edits and stale caches ($failure)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'qjotter-migration-',
      );
      final store = await NotesStore.open(directory);
      final old = AccountSession(
        server: retiredServerAddress,
        userId: 'alice',
        email: 'alice@example.test',
        token: 'preserved-session',
      );
      final next = AccountSession(
        server: appServerAddress,
        userId: old.userId,
        email: old.email,
        token: old.token,
      );
      store.useProfile(next.profile);
      await store.save(store.initialSnapshot.editSelected('Stale mini cache'));
      store.useProfile(old.profile, server: old.server);
      await store.save(
        store.initialSnapshot.editSelected('Pending phone edit'),
      );
      final frozen = store.prepareSyncChanges();
      await store.save(
        store.initialSnapshot.editSelected('Typed after upload started'),
      );
      final selection = store.initialSnapshot.selectedId;
      final api = MigrationApi()..offline = failure == 'offline';
      final vault = MigrationVault()..session = old;
      vault.failWrites = failure == 'keychain';
      final services = AppServices(
        store: store,
        vault: vault,
        startup: FakeStartupManager(),
        api: api,
        automaticSync: false,
        defaultServer: appServerAddress,
        defaultCertificate: appServerCertificate,
        migrateFromServer: retiredServerAddress,
      );
      addTearDown(() async {
        services.dispose();
        store.close();
        await directory.delete(recursive: true);
      });
      await services.initialize();
      if (failure != 'none') {
        expect(vault.session!.server, old.server);
        expect(store.profile, old.profile);
        expect(store.setting('server'), old.server);
        // A failed attempt must not freeze a stale cache for the retry.
        await store.save(
          store.initialSnapshot.editSelected('Typed after failed migration'),
        );
        api.offline = false;
        vault.failWrites = false;
        await services.initialize();
      }
      expect(vault.session!.server, next.server);
      expect(vault.session!.token, old.token);
      expect(store.profile, next.profile);
      expect(store.setting('server'), next.server);
      expect(store.initialSnapshot.selectedId, selection);
      expect(
        store.initialSnapshot.selected.text,
        failure == 'none'
            ? 'Typed after upload started'
            : 'Typed after failed migration',
      );
      expect(store.prepareSyncChanges(), frozen);
      final archives = store.database.select(
        'SELECT id FROM profiles WHERE id LIKE ?',
        ['${next.profile}:before-migration:%'],
      );
      expect(archives, hasLength(1));
      final archive = archives.single['id'] as String;
      store.useProfile(archive);
      expect(store.initialSnapshot.selected.text, 'Stale mini cache');
      store.useProfile(old.profile);
      expect(store.initialSnapshot.selectedId, selection);
      store.useProfile(next.profile);
      // Repeating the migration must not replace edits made at the destination.
      await store.save(
        store.initialSnapshot.editSelected('After successful migration'),
      );
      store.migrateServerProfile(old.profile, next.profile);
      expect(store.initialSnapshot.selected.text, 'After successful migration');
    });
  }
}
