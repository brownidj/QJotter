import 'dart:io';
import 'dart:convert';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qjotter/app_services.dart';
import 'package:qjotter/main.dart';
import 'package:qjotter/notes_store.dart';
import 'package:qjotter/sqlite_notes_store.dart';
import 'package:qjotter/settings_page.dart';

import 'support/account_fakes.dart';

class CertificatePicker extends FileSelectorPlatform {
  XFile? file;
  List<XTypeGroup>? types;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    types = acceptedTypeGroups;
    return file;
  }
}

class FakeAccountApi extends AccountApi {
  String? submittedEmail;
  List<String>? recovery;
  bool invalidRecovery = false;
  bool offline = false;
  @override
  Future<void> checkConnection(String server) async {}
  @override
  Future<void> resetPassword(String server, String email, String code, String password) async {
    if (invalidRecovery) throw const AccountError('Invalid or expired recovery code.');
    recovery = [server, email, code, password];
  }
  @override
  Future<AccountSession> signIn(
    String server,
    String email,
    String password, {
    bool create = false,
  }) async {
    submittedEmail = email;
    return AccountSession(
      server: server,
      userId: 'alice',
      email: email,
      token: 'test-token',
    );
  }

  @override
  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) async {
    if (offline) throw const AccountError('Cannot reach the server.');
    return {
      'notes': [
        for (final change in changes) {...change, 'version': 1},
      ],
      'acknowledged': [for (final change in changes) change['mutationId']],
    };
  }

  @override
  Future<void> logout(AccountSession session) async {}
}

void main() {
  late String certificate;
  setUpAll(() async {
    final fixture = await Directory.systemTemp.createTemp(
      'notefile-certificate-fixture-',
    );
    try {
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=notefile.test',
        '-keyout',
        '${fixture.path}/key.pem',
        '-out',
        '${fixture.path}/public.pem',
      ]);
      expect(result.exitCode, 0);
      certificate = await File('${fixture.path}/public.pem').readAsString();
    } finally {
      await fixture.delete(recursive: true);
    }
  });
  late Directory directory;
  late SqliteNotesStore store;
  late AppServices services;
  late FakeStartupManager startup;
  late FakeAccountApi api;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'notefile-settings-test-',
    );
    store = await NotesStore.open(directory);
    startup = FakeStartupManager();
    api = FakeAccountApi();
    services = AppServices(
      store: store,
      vault: MemorySessionVault(),
      startup: startup,
      api: api,
      automaticSync: false,
    );
    await services.initialize();
  });
  tearDown(() async {
    services.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> importCertificate(
    WidgetTester tester,
    CertificatePicker picker,
  ) async {
    final previous = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = picker;
    addTearDown(() => FileSelectorPlatform.instance = previous);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: services)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Server address'),
      'https://notefile.test:8766',
    );
    await tester.ensureVisible(find.text('Import server certificate…'));
    await tester.tap(find.text('Import server certificate…'));
    await tester.pumpAndSettle();
  }

  test(
    'Private build defaults add server trust without replacing user settings',
    () async {
      services.dispose();
      services = AppServices(
        store: store,
        vault: MemorySessionVault(),
        startup: startup,
        api: api,
        automaticSync: false,
        defaultServer: 'https://notefile.test:8766/',
        defaultCertificateBase64: base64Url.encode(utf8.encode(certificate)),
      );
      await services.initialize();
      expect(store.setting('server'), 'https://notefile.test:8766');
      expect(
        store.setting('certificate:https://notefile.test:8766'),
        certificate,
      );
      expect(store.setting('certificate:https://other.test'), isNull);
      store.setSetting('server', 'https://other.test');
      store.setSetting(
        'certificate:https://notefile.test:8766',
        'user supplied certificate',
      );
      await services.initialize();
      expect(store.setting('server'), 'https://other.test');
      expect(
        store.setting('certificate:https://notefile.test:8766'),
        'user supplied certificate',
      );
    },
  );

  test(
    'iOS conversion produces independently readable DER certificates',
    () async {
      final certificates = AccountApi.certificateData(
        '$certificate\n$certificate',
        ios: true,
      );
      expect(certificates, hasLength(2));
      expect(certificates[0], certificates[1]);
      final der = File('${directory.path}/certificate.der');
      await der.writeAsBytes(certificates.first);
      final result = await Process.run('openssl', [
        'x509',
        '-inform',
        'DER',
        '-in',
        der.path,
        '-noout',
        '-subject',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('notefile.test'));
      expect(
        AccountApi.certificateData(certificate, ios: false).single,
        utf8.encode(certificate),
      );
    },
  );

  testWidgets(
    'iOS imports and stores the selected public certificate using supported file types',
    (tester) async {
      final picker = CertificatePicker()
        ..file = XFile.fromData(utf8.encode(certificate), name: 'server.pem');
      await importCertificate(tester, picker);
      expect(
        picker.types!.single.uniformTypeIdentifiers,
        contains('public.data'),
      );
      expect(
        store.setting('certificate:https://notefile.test:8766'),
        certificate,
      );
      expect(
        find.text('Private server certificate installed for this address.'),
        findsOneWidget,
      );
      expect(find.text('Server certificate imported.'), findsOneWidget);
      expect(api.submittedEmail, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Cancelling certificate selection leaves trust unchanged', (
    tester,
  ) async {
    await importCertificate(tester, CertificatePicker());
    expect(store.setting('certificate:https://notefile.test:8766'), isNull);
    expect(find.text('Server certificate imported.'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Picking an unrelated file never trusts it as a certificate', (
    tester,
  ) async {
    final picker = CertificatePicker()
      ..file = XFile.fromData(
        utf8.encode('Not a certificate'),
        name: 'notes.txt',
      );
    await importCertificate(tester, picker);
    expect(store.setting('certificate:https://notefile.test:8766'), isNull);
    expect(
      find.text('Choose the public server certificate, not a private key.'),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Settings opens from the note and persists the startup opt-out', (
    tester,
  ) async {
    await services.signIn(
      'https://notes.example.test',
      'alice@example.test',
      'test passphrase only',
    );
    await tester.pumpWidget(QJotterApp(store: store, services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Account'), findsOneWidget);
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(startup.changes, [true, false]);
    expect(store.setting('autoload'), 'false');
  });

  testWidgets(
    'Account setup gates editing, imports old notes, and sign-out returns to setup',
    (tester) async {
      await store.save(
        store.initialSnapshot.editSelected('Only on this device'),
      );
      await tester.binding.setSurfaceSize(const Size(560, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(QJotterApp(store: store, services: services));
      await tester.pumpAndSettle();
      expect(find.text('Set up QJotter'), findsOneWidget);
      expect(find.byTooltip('New note'), findsNothing);
      expect(find.text('Only on this device'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Server address'),
        'https://notes.example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'alice@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'test passphrase only',
      );
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(api.submittedEmail, 'alice@example.test');
      expect(find.text('Only on this device'), findsWidgets);
      expect(find.text('Saved to server'), findsOneWidget);
      expect(store.pendingChanges(), isEmpty);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Signed in as alice@example.test'), findsOneWidget);
      expect(store.initialSnapshot.selected.text, 'Only on this device');
      await tester.ensureVisible(find.text('Sign out'));
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(store.profile, 'device');
      expect(store.initialSnapshot.selected.text, 'Only on this device');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Set up QJotter'), findsOneWidget);
      expect(find.byTooltip('New note'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'Offline edits stay queued and only claim server storage after acknowledgement',
    (tester) async {
      final automatic = AppServices(
        store: store,
        vault: MemorySessionVault(),
        startup: startup,
        api: api,
      );
      try {
        await automatic.initialize();
        await automatic.signIn(
          'https://notes.example.test',
          'alice@example.test',
          'test passphrase only',
        );
        api.offline = true;
        await tester.pumpWidget(QJotterApp(store: store, services: automatic));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'An offline edit');
        await tester.pumpAndSettle();
        expect(
          find.textContaining('waiting to save to server'),
          findsOneWidget,
        );
        expect(store.pendingChanges(), hasLength(1));
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.text('Cannot reach the server.'), findsOneWidget);
        expect(find.text('An offline edit'), findsWidgets);
        api.offline = false;
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(find.text('Saved to server'), findsOneWidget);
        expect(store.pendingChanges(), isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        automatic.dispose();
      }
    },
  );

  testWidgets('The server address can be saved before signing in', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: services)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Server address'),
      '\u200bhttps://notefile.example.test:8766\u200b',
    );
    await tester.ensureVisible(find.text('Save server address'));
    await tester.tap(find.text('Save server address'));
    await tester.pumpAndSettle();
    expect(store.setting('server'), 'https://notefile.example.test:8766');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Server address'))
          .controller!
          .text,
      'https://notefile.example.test:8766',
    );
    expect(services.session, isNull);
  });

  testWidgets('Recovery validates confirmation, handles invalid codes and returns to sign in', (tester) async {
    services.saveServerAddress('https://notes.example.test');
    await tester.pumpWidget(MaterialApp(home: SettingsPage(services: services)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Forgot password?'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    Future<void> enter(String label, String value) async {
      final field = find.widgetWithText(TextField, label);
      if (field.evaluate().isEmpty) {
        await tester.scrollUntilVisible(field, 160,
            scrollable: find.byType(Scrollable).first);
      }
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, value);
      await tester.pumpAndSettle();
    }
    Future<void> submit() async {
      await tester.ensureVisible(find.text('Reset password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
    }
    await enter('Email', 'alice@example.test');
    await enter('Recovery code', 'fixture-recovery-code');
    await enter('New password', 'new test passphrase only');
    await enter('Confirm new password', 'mismatched test passphrase');
    await submit();
    expect(find.text('The passwords do not match.'), findsOneWidget);
    expect(api.recovery, isNull);
    await enter('Confirm new password', 'new test passphrase only');
    api.invalidRecovery = true;
    await submit();
    expect(find.text('Invalid or expired recovery code.'), findsOneWidget);
    api.invalidRecovery = false;
    await submit();
    expect(api.recovery, ['https://notes.example.test', 'alice@example.test', 'fixture-recovery-code', 'new test passphrase only']);
    expect(find.textContaining('Password reset. Sign in with your new password.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Recovery code'), findsNothing);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Password')).controller!.text, isEmpty);
    expect(services.session, isNull);
    expect(services.busy, isFalse);
  });

  test('An interrupted first upload survives restart without duplicating legacy notes', () async {
    await store.save(store.initialSnapshot.editSelected('Legacy note'));
    final original = store.initialSnapshot.selected;
    final vault = MemorySessionVault();
    AppServices makeService() => AppServices(
      store: store,
      vault: vault,
      startup: startup,
      api: api,
      automaticSync: false,
    );
    services.dispose();
    services = makeService();
    api.offline = true;
    await services.initialize();
    await services.signIn(
      'https://notes.example.test',
      'alice@example.test',
      'test passphrase only',
    );
    expect(store.pendingChanges(), hasLength(1));
    expect(store.initialSnapshot.selected.id, original.id);
    expect(store.initialSnapshot.selected.createdAt, original.createdAt);
    services.dispose();
    services = makeService();
    await services.initialize();
    expect(services.session, isNotNull);
    expect(store.initialSnapshot.notes, hasLength(1));
    expect(store.initialSnapshot.selected.text, 'Legacy note');
    expect(store.pendingChanges(), hasLength(1));
    api.offline = false;
    await services.sync();
    expect(store.pendingChanges(), isEmpty);
    expect(services.syncStatus, 'Saved to server');
  });

  test(
    'Server migration reuses notes already copied by the earlier app',
    () async {
      await store.save(
        store.initialSnapshot.editSelected('Already copied note'),
      );
      const account = 'account:["https://notes.example.test","alice"]';
      store.useProfile(account);
      store.copyDeviceNotes();
      final copiedId = store.initialSnapshot.selected.id;
      store.useProfile('device');
      await services.signIn(
        'https://notes.example.test',
        'alice@example.test',
        'test passphrase only',
      );
      expect(store.initialSnapshot.notes, hasLength(1));
      expect(store.initialSnapshot.selected.id, copiedId);
      expect(store.pendingChanges(), isEmpty);
    },
  );

  testWidgets('iOS explains that reboot autoload is unavailable', (
    tester,
  ) async {
    startup.current = const StartupStatus(
      supported: false,
      message: 'iOS manages app launches. Automatic launch after a reboot is not available.',
    );
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: services)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Automatic launch after a reboot is not available'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(SwitchListTile), findsNothing);
    expect(
      find.textContaining('Automatic launch after a reboot is not available'),
      findsOneWidget,
    );
  });
}
