import 'package:qjotter/app_services.dart';

class MemorySessionVault implements SessionVault {
  AccountSession? session;
  @override
  Future<AccountSession?> read() async => session;
  @override
  Future<void> write(AccountSession? value) async => session = value;
}

class FakeStartupManager implements StartupManager {
  StartupStatus current = const StartupStatus(supported: true);
  final changes = <bool>[];
  bool fail = false;
  @override
  Future<StartupStatus> status() async => current;
  @override
  Future<StartupStatus> setEnabled(bool enabled) async {
    changes.add(enabled);
    if (fail) throw StateError('Registration failed');
    return current = StartupStatus(supported: true, enabled: enabled);
  }
}
