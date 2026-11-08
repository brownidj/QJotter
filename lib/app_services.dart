import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'sqlite_notes_store.dart';

class AccountSession {
  const AccountSession({
    required this.server,
    required this.userId,
    required this.email,
    required this.token,
  });
  final String server, userId, email, token;
  String get profile => 'account:${jsonEncode([server, userId])}';
  Map<String, dynamic> toJson() => {
    'server': server,
    'userId': userId,
    'email': email,
    'token': token,
  };
  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
    server: json['server'] as String,
    userId: json['userId'] as String,
    email: json['email'] as String,
    token: json['token'] as String,
  );
}

abstract class SessionVault {
  Future<AccountSession?> read();
  Future<void> write(AccountSession? session);
}

class SecureSessionVault implements SessionVault {
  // No shared Keychain access or provisioning profile is needed on macOS.
  final _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  @override
  Future<AccountSession?> read() async {
    final value = await _storage.read(key: 'notefile.session.v1');
    return value == null
        ? null
        : AccountSession.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  @override
  Future<void> write(AccountSession? session) => session == null
      ? _storage.delete(key: 'notefile.session.v1')
      : _storage.write(
          key: 'notefile.session.v1',
          value: jsonEncode(session.toJson()),
        );
}

class AccountError implements Exception {
  const AccountError(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountApi {
  AccountApi({http.Client? client, this.certificateForServer})
    : client = client ?? http.Client();
  final http.Client client;
  final String? Function(String server)? certificateForServer;
  final _trustedClients = <String, http.Client>{};

  static List<List<int>> certificateData(String pem, {required bool ios}) {
    if (!ios) return [utf8.encode(pem)];
    final certificates = RegExp(
      r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
    ).allMatches(pem).toList();
    if (certificates.isEmpty) {
      throw const FormatException('Missing certificate');
    }
    return [
      for (final match in certificates)
        base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
    ];
  }

  static void _trustCertificate(SecurityContext context, String pem) {
    try {
      // Current Flutter runtimes accept PEM on iOS as on desktop.
      context.setTrustedCertificatesBytes(utf8.encode(pem));
    } on TlsException {
      if (!Platform.isIOS) rethrow;
      // Older iOS runtimes require one DER certificate per call.
      for (final bytes in certificateData(pem, ios: true)) {
        context.setTrustedCertificatesBytes(bytes);
      }
    }
  }

  static void validateCertificate(String pem) {
    if (!pem.contains('-----BEGIN CERTIFICATE-----') ||
        pem.contains('PRIVATE KEY')) {
      throw const AccountError(
        'Choose the public server certificate, not a private key.',
      );
    }
    try {
      _trustCertificate(SecurityContext(withTrustedRoots: false), pem);
    } catch (_) {
      throw const AccountError('This file is not a valid PEM certificate.');
    }
  }

  http.Client _clientFor(String server) {
    final pem = certificateForServer?.call(server);
    if (pem == null) return client;
    return _trustedClients.putIfAbsent('$server\n$pem', () {
      final context = SecurityContext(withTrustedRoots: true);
      _trustCertificate(context, pem);
      // Normal TLS chain, expiry and hostname checks still apply. This trust
      // is limited to this app and requests to this configured server address.
      return IOClient(HttpClient(context: context));
    });
  }

  static String validateServer(String input) {
    // Copied links can carry invisible formatting that trim() does not remove.
    final address = input.replaceAll(RegExp('[\u200B\u2060\uFEFF]'), '').trim();
    final uri = Uri.tryParse(address);
    if (uri == null || uri.host.isEmpty) {
      throw const AccountError(
        'Check the server address. Include https:// and the port, for example https://davids-mac-mini.local:8766.',
      );
    }
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            const ['localhost', '127.0.0.1', '::1'].contains(uri.host))) {
      throw const AccountError(
        'Enter an HTTPS server address. HTTP is allowed only for localhost development.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const AccountError(
        'Use the server address only, without a username, password, query or fragment.',
      );
    }
    if (uri.host.contains('%') || uri.port < 1 || uri.port > 65535) {
      throw const AccountError(
        'Check the server hostname and port. The hostname must not contain spaces or smart punctuation.',
      );
    }
    return uri.toString().replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> checkConnection(String server) async {
    try {
      final response = await _clientFor(server)
          .get(Uri.parse('$server/health'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 4096 ||
          (jsonDecode(response.body) as Map<String, dynamic>)['ok'] != true) {
        throw const AccountError(
          'The server did not respond correctly. Check its address.',
        );
      }
    } on AccountError {
      rethrow;
    } on HandshakeException {
      throw const AccountError(
        'Could not verify the server’s HTTPS certificate. Check its certificate and address.',
      );
    } catch (_) {
      throw const AccountError(
        'Cannot reach the server. Check your local network connection and that the Mac is awake.',
      );
    }
  }

  Future<Map<String, dynamic>> request(
    String server,
    String path,
    Map<String, dynamic> data, {
    String? token,
  }) async {
    final request = http.Request('POST', Uri.parse('$server/v1/$path'))
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(data);
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    try {
      final response = await _clientFor(server)
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (response.bodyBytes.length > 20 * 1024 * 1024) {
        throw const AccountError('The server response is too large.');
      }
      if (response.statusCode == 401) {
        throw const AccountError(
          'Sign-in expired or the email/password is incorrect. Sign in again.',
        );
      }
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AccountError(
          json['error'] as String? ??
              'The server could not complete this request.',
        );
      }
      return json;
    } on AccountError {
      rethrow;
    } on HandshakeException {
      throw const AccountError(
        'Could not verify the server’s HTTPS certificate. Import its public certificate in Settings and check the server address.',
      );
    } catch (_) {
      throw const AccountError(
        'Cannot reach the server. Check its address and your connection. Your notes remain on this device.',
      );
    }
  }

  Future<AccountSession> signIn(
    String server,
    String email,
    String password, {
    bool create = false,
  }) async {
    server = validateServer(server);
    final json = await request(server, create ? 'register' : 'login', {
      'email': email.trim(),
      'password': password,
    });
    return AccountSession(
      server: server,
      userId: json['userId'] as String,
      email: json['email'] as String,
      token: json['token'] as String,
    );
  }

  Future<Map<String, dynamic>> sync(
    AccountSession session,
    List<Map<String, dynamic>> changes,
  ) => request(session.server, 'sync', {
    'changes': changes,
  }, token: session.token);

  Future<void> resetPassword(
    String server,
    String email,
    String code,
    String password,
  ) async {
    await request(validateServer(server), 'reset-password', {
      'email': email.trim(),
      'code': code.trim(),
      'password': password,
    });
  }
  Future<void> logout(AccountSession session) async {
    await request(session.server, 'logout', {}, token: session.token);
  }

  void close() {
    client.close();
    for (final trusted in _trustedClients.values) {
      trusted.close();
    }
    _trustedClients.clear();
  }
}

class StartupStatus {
  const StartupStatus({
    required this.supported,
    this.enabled = false,
    this.requiresApproval = false,
    this.message,
  });
  final bool supported, enabled, requiresApproval;
  final String? message;
}

abstract class StartupManager {
  Future<StartupStatus> status();
  Future<StartupStatus> setEnabled(bool enabled);
}

class PlatformStartupManager implements StartupManager {
  static const channel = MethodChannel('notefile/settings');
  bool get _supported =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
  Future<StartupStatus> _call(String method, [bool? value]) async {
    if (!_supported) {
      return const StartupStatus(
        supported: false,
        message: 'iOS manages app launches. Automatic launch after a reboot is not available.',
      );
    }
    final result = await channel.invokeMapMethod<String, dynamic>(
      method,
      value,
    );
    return StartupStatus(
      supported: result?['supported'] == true,
      enabled: result?['enabled'] == true,
      requiresApproval: result?['requiresApproval'] == true,
      message: result?['message'] as String?,
    );
  }

  @override
  Future<StartupStatus> status() => _call('getStartupStatus');
  @override
  Future<StartupStatus> setEnabled(bool enabled) =>
      _call('setStartupEnabled', enabled);
}

class AppServices extends ChangeNotifier {
  AppServices({
    required this.store,
    required this.vault,
    required this.startup,
    AccountApi? api,
    this.automaticSync = true,
    this.defaultServer = const String.fromEnvironment('NOTEFILE_SERVER'),
    this.defaultCertificate = '',
    this.defaultCertificateBase64 = const String.fromEnvironment(
      'NOTEFILE_SERVER_CERTIFICATE_BASE64',
    ),
  }) : api =
           api ??
           AccountApi(
             certificateForServer: (server) =>
                 store.setting('certificate:$server'),
           );
  final SqliteNotesStore store;
  final SessionVault vault;
  final StartupManager startup;
  final AccountApi api;
  final bool automaticSync;
  final String defaultServer, defaultCertificate, defaultCertificateBase64;
  AccountSession? session;
  StartupStatus startupStatus = const StartupStatus(supported: false);
  String? startupError;
  String syncStatus = 'Sign in to save notes to your server.';
  bool busy = false;
  bool syncing = false;
  int notebookRevision = 0;
  Timer? _debounce, _poll;
  Future<void>? _syncFuture;
  bool _disposed = false;

  void saveServerAddress(String input) {
    store.setSetting('server', AccountApi.validateServer(input));
    _notify();
  }

  void setServerCertificate(String input, String pem) {
    final server = AccountApi.validateServer(input);
    if (!server.startsWith('https://')) {
      throw const AccountError('Certificates require an HTTPS server address.');
    }
    AccountApi.validateCertificate(pem);
    store.transaction(() {
      store.setSetting('server', server);
      store.setSetting('certificate:$server', pem);
    });
    _notify();
  }

  Future<void> initialize() async {
    String? configuredServer;
    if (defaultServer.isNotEmpty) {
      try {
        final server = AccountApi.validateServer(defaultServer);
        final certificate = defaultCertificate.isNotEmpty
            ? defaultCertificate
            : utf8.decode(base64Decode(defaultCertificateBase64));
        if (certificate.isNotEmpty) {
          if (!server.startsWith('https://')) {
            throw const AccountError('Certificates require HTTPS.');
          }
          AccountApi.validateCertificate(certificate);
        }
        store.transaction(() {
          if (store.setting('server') == null) {
            store.setSetting('server', server);
          }
          if (certificate.isNotEmpty &&
              store.setting('certificate:$server') == null) {
            store.setSetting('certificate:$server', certificate);
          }
        });
        configuredServer = server;
      } catch (error) {
        if (error is! AccountError && error is! FormatException) rethrow;
        syncStatus = 'Could not apply the supplied server setup. Enter the server address and import its public certificate in Settings.';
      }
    }
    try {
      session = await vault.read();
      if (session != null) {
        store.useProfile(session!.profile, importDeviceNotes: true);
      }
    } catch (_) {
      session = null;
      syncStatus =
          'Could not restore sign-in. Sign in again to access your notes.';
    }
    await refreshStartup();
    if (startupStatus.supported && store.setting('startupConfigured') == null) {
      await setAutoload(true);
      // Successful registration records this preference. Failed development
      // builds may retry after installation at a stable path.
    }
    store.onSaved = _scheduleSync;
    if (session == null &&
        configuredServer != null &&
        store.setting('server') == configuredServer) {
      unawaited(checkServerConnection());
    }
    if (automaticSync) {
      _poll = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(sync()),
      );
      unawaited(sync());
    }
  }

  Future<void> checkServerConnection() async {
    final server = store.setting('server');
    if (server == null) return;
    try {
      await api.checkConnection(server);
      if (_disposed || store.setting('server') != server) return;
      store.setSetting(
        'serverVerified:$server',
        DateTime.now().toUtc().toIso8601String(),
      );
      if (session == null && !busy) {
        syncStatus = 'Server connected. Sign in to access your notes.';
      }
    } on AccountError catch (error) {
      if (_disposed) return;
      if (session == null && !busy) syncStatus = error.message;
    }
    _notify();
  }

  Future<void> refreshStartup() async {
    try {
      startupStatus = await startup.status();
      if (startupStatus.enabled || startupStatus.requiresApproval) {
        startupError = null;
      }
    } catch (_) {
      startupError = 'Could not check automatic startup. Stop and rebuild the app if it was updated.';
    }
    _notify();
  }

  Future<void> setAutoload(bool enabled) async {
    try {
      startupStatus = await startup.setEnabled(enabled);
      store.setSetting('startupConfigured', 'true');
      store.setSetting('autoload', enabled.toString());
      startupError = null;
    } catch (_) {
      startupError = 'Could not change automatic startup. On macOS, install the app in Applications and check System Settings → General → Login Items.';
      await refreshStartupAfterFailure();
    }
    _notify();
  }

  Future<void> refreshStartupAfterFailure() async {
    try {
      startupStatus = await startup.status();
    } catch (_) {
      /* Keep the last known state. */
    }
  }

  Future<void> signIn(
    String server,
    String email,
    String password, {
    bool create = false,
  }) async {
    if (busy) return;
    busy = true;
    _debounce?.cancel();
    _notify();
    try {
      await _syncFuture;
      final next = await api.signIn(server, email, password, create: create);
      try {
        await vault.write(next);
      } catch (_) {
        try {
          await api.logout(next);
        } catch (_) {
          /* The unused session expires on the server. */
        }
        throw const AccountError(
          'Could not securely save sign-in on this device.',
        );
      }
      try {
        store.useProfile(
          next.profile,
          server: next.server,
          importDeviceNotes: true,
        );
      } catch (_) {
        await vault.write(session);
        try {
          await api.logout(next);
        } catch (_) {
          /* The unused session expires. */
        }
        rethrow;
      }
      session = next;
      notebookRevision++;
      await _syncNow();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    _debounce?.cancel();
    _notify();
    try {
      await _syncFuture;
      final previous = session;
      // If deleting credentials fails, do not pretend sign-out succeeded.
      await vault.write(null);
      try {
        store.useProfile('device');
      } catch (_) {
        await vault.write(previous);
        rethrow;
      }
      session = null;
      notebookRevision++;
      syncStatus = 'Signed out. Sign in to access your server notes.';
      _notify();
      if (previous != null) {
        try {
          await api.logout(previous);
        } catch (_) {
          /* Local sign-out works offline; server sessions expire. */
        }
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> resetPassword(
    String server,
    String email,
    String code,
    String password,
  ) async {
    if (busy) return;
    if (session != null) {
      throw const AccountError('Sign out before recovering an account.');
    }
    busy = true;
    _notify();
    try {
      await api.resetPassword(server, email, code, password);
    } finally {
      busy = false;
      _notify();
    }
  }

  void _scheduleSync() {
    if (session == null || busy) return;
    if (store.pendingChanges().isNotEmpty) {
      syncStatus = 'Saved on this device · waiting to save to server…';
      _notify();
    }
    if (!automaticSync) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => unawaited(sync()));
  }

  Future<void> sync() {
    if (busy) return Future.value();
    return _syncNow();
  }

  Future<void> _syncNow() {
    if (session == null || _disposed) return Future.value();
    return _syncFuture ??= _synchronize().whenComplete(
      () => _syncFuture = null,
    );
  }

  Future<void> _synchronize() async {
    final account = session!;
    syncing = true;
    syncStatus = 'Syncing…';
    _notify();
    try {
      final sent = store.pendingChanges();
      final response = await api.sync(account, sent);
      if (_disposed || session != account) return;
      store.applySync(response, sent);
      notebookRevision++;
      if (store.pendingChanges().isEmpty) {
        syncStatus = 'Saved to server';
      } else {
        _scheduleSync();
        syncStatus = 'Saved on this device · waiting to save to server…';
      }
    } catch (error) {
      syncStatus = error is AccountError ? error.message : 'Sync failed. Your notes remain on this device; retry when connected.';
    } finally {
      syncing = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _debounce?.cancel();
    store.onSaved = null;
    api.close();
    super.dispose();
  }
}
