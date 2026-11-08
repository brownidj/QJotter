import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'app_services.dart';
import 'app_identity.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.accountRequired = false,
  });
  final AppServices services;
  final bool accountRequired;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _recoveryCode = TextEditingController();
  final _confirmPassword = TextEditingController();
  late final TextEditingController _server;
  bool _create = false;
  bool _reset = false;
  bool _startupBusy = false;
  String? _error;
  String? _message;
  AppServices get services => widget.services;
  bool get _hasServerCertificate {
    try {
      final server = AccountApi.validateServer(_server.text);
      return services.store.setting('certificate:$server') != null;
    } on AccountError {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(
      text: services.session?.server ?? services.store.setting('server') ?? '',
    );
    services.addListener(_changed);
    services.refreshStartup();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _saveServerAddress() {
    try {
      final server = AccountApi.validateServer(_server.text);
      services.saveServerAddress(server);
      _server.text = server;
      setState(() => _error = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Server address saved.')));
    } catch (error) {
      setState(
        () => _error = error is AccountError
            ? error.message
            : 'Could not save the server address.',
      );
    }
  }

  Future<void> _importCertificate() async {
    var suspended = false;
    const channel = MethodChannel('notefile/quick_capture');
    try {
      AccountApi.validateServer(_server.text);
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await channel.invokeMethod<void>('beginExternalAction');
        suspended = true;
      }
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'PEM certificate',
            extensions: ['pem', 'crt', 'cer'],
            // iOS requires UTIs; PEM files may be classified as generic data.
            // Validate the certificate contents after the file is selected.
            uniformTypeIdentifiers: ['public.data'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 65536) {
        throw const AccountError('The certificate file is too large.');
      }
      services.setServerCertificate(_server.text, await file.readAsString());
      if (mounted) {
        setState(() => _error = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server certificate imported.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error) {
            AccountError() => error.message,
            FileSystemException() => 'Could not read this file. Save the certificate in Files, then select it again.',
            FormatException() =>
              'Choose the public PEM certificate supplied with your server.',
            PlatformException() =>
              'Could not open the certificate file picker. Please try again.',
            _ => 'Could not import the server certificate. Please select the public PEM file again.',
          };
        });
      }
    } finally {
      if (suspended) {
        try {
          await channel.invokeMethod<void>('endExternalAction');
        } on PlatformException {
          /* The app may be closing. */
        }
      }
    }
  }

  Future<void> _authenticate() async {
    setState(() => _error = null);
    try {
      if (_email.text.trim().isEmpty || _password.text.isEmpty) {
        throw const AccountError('Enter your email and password.');
      }
      final server = AccountApi.validateServer(_server.text);
      _server.text = server;
      await services.signIn(
        server,
        _email.text,
        _password.text,
        create: _create,
      );
      if (mounted) _password.clear();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AccountError
              ? error.message
              : 'Could not sign in. Please try again.',
        );
      }
    }
  }

  Future<void> _recoverPassword() async {
    setState(() {
      _error = null;
      _message = null;
    });
    try {
      if (_email.text.trim().isEmpty || _recoveryCode.text.trim().isEmpty) {
        throw const AccountError('Enter your email and the code supplied by your server administrator.');
      }
      if (_password.text.length < 12 || _password.text.length > 1024) {
        throw const AccountError('Use a password of 12 to 1,024 characters.');
      }
      if (_password.text != _confirmPassword.text) {
        throw const AccountError('The passwords do not match.');
      }
      await services.resetPassword(
        _server.text, _email.text, _recoveryCode.text, _password.text,
      );
      if (!mounted) return;
      _password.clear();
      _confirmPassword.clear();
      _recoveryCode.clear();
      setState(() {
        _reset = false;
        _message = 'Password reset. Sign in with your new password. Other devices must sign in again.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is AccountError
            ? error.message : 'Could not reset the password. Please try again.');
      }
    }
  }

  @override
  void dispose() {
    services.removeListener(_changed);
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _recoveryCode.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.accountRequired ? 'Set up $appName' : 'Settings'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(appName, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(appStrapline),
        const SizedBox(height: 24),
        Text('Account', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (services.session == null) ...[
          Text(services.syncStatus),
          const Text(
            'Notes are saved to your server account. Sign in or create an account to start. A local copy keeps your notes available offline.',
          ),
          if (services.store.setting('deviceNotesAccount') == null) ...[
            const SizedBox(height: 8),
            const Text(
              'Existing notes on this device will be added to the first account you sign in to.',
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _server,
            enabled: !services.busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            smartDashesType: SmartDashesType.disabled,
            smartQuotesType: SmartQuotesType.disabled,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'https://notes.example.com',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: services.busy ? null : _saveServerAddress,
              child: const Text('Save server address'),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: services.busy ? null : _importCertificate,
              child: const Text('Import server certificate…'),
            ),
          ),
          Text(
            _hasServerCertificate
                ? 'Private server certificate installed for this address.'
                : 'For a private server, import the public certificate supplied with it. This trusts that certificate only inside $appName.',
          ),
          TextField(
            controller: _email,
            enabled: !services.busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          if (_reset) ...[
            const SizedBox(height: 12),
            const Text(
              'Ask your server administrator for a recovery code. It expires after 30 minutes and works once. Enter it below and choose a new password.',
            ),
            TextField(
              controller: _recoveryCode,
              enabled: !services.busy,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Recovery code'),
            ),
          ],
          TextField(
            controller: _password,
            enabled: !services.busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: _reset ? 'New password' : 'Password',
              helperText: _create || _reset ? 'Use at least 12 characters.' : null,
            ),
            onSubmitted: services.busy || _reset ? null : (_) => _authenticate(),
          ),
          if (_reset)
            TextField(
              controller: _confirmPassword,
              enabled: !services.busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Confirm new password'),
              onSubmitted: services.busy ? null : (_) => _recoverPassword(),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: services.busy ? null : _reset ? _recoverPassword : _authenticate,
            child: Text(
              services.busy
                  ? 'Please wait…'
                  : _reset
                  ? 'Reset password'
                  : _create
                  ? 'Create account'
                  : 'Sign in',
            ),
          ),
          TextButton(
            onPressed: services.busy
                ? null
                : () => setState(() {
                    if (_reset) {
                      _reset = false;
                    } else {
                      _create = !_create;
                    }
                    _password.clear();
                    _recoveryCode.clear();
                    _confirmPassword.clear();
                    _error = null;
                    _message = null;
                  }),
            child: Text(
              _reset
                  ? 'Back to sign in'
                  : _create
                  ? 'Already have an account? Sign in'
                  : 'Create an account',
            ),
          ),
          if (!_reset && !_create)
            TextButton(
              onPressed: services.busy ? null : () => setState(() {
                _reset = true;
                _password.clear();
                _error = null;
                _message = null;
              }),
              child: const Text('Forgot password?'),
            ),
        ] else ...[
          Text('Signed in as ${services.session!.email}'),
          Text(services.session!.server),
          const SizedBox(height: 8),
          Text(services.syncStatus),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: services.busy || services.syncing ? null : services.sync,
            child: Text(services.syncing ? 'Syncing…' : 'Sync now'),
          ),
          const Text(
            'Notes save to this server automatically. Offline edits are queued on this device and uploaded when connected. Signing out returns to account setup.',
          ),
          TextButton(
            onPressed: services.busy
                ? null
                : () async {
                    setState(() => _error = null);
                    try {
                      await services.signOut();
                    } catch (_) {
                      if (mounted) {
                        setState(
                          () => _error =
                              'Could not securely sign out. Please try again.',
                        );
                      }
                    }
                  },
            child: const Text('Sign out'),
          ),
        ],
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_message != null) Text(_message!),
        const SizedBox(height: 24),
        Text('Startup', style: Theme.of(context).textTheme.titleLarge),
        if (services.startupStatus.supported)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Launch when I sign in to this computer'),
            subtitle: const Text(
              'Start $appName automatically after a startup or reboot.',
            ),
            value:
                services.startupStatus.enabled ||
                services.startupStatus.requiresApproval,
            onChanged: _startupBusy
                ? null
                : (value) async {
                    setState(() => _startupBusy = true);
                    await services.setAutoload(value);
                    if (mounted) setState(() => _startupBusy = false);
                  },
          )
        else
          Text(
            services.startupStatus.message ??
                'Automatic startup is unavailable on this device.',
          ),
        if (services.startupStatus.requiresApproval)
          const Text(
            'Allow $appName in System Settings → General → Login Items to finish enabling startup.',
          ),
        if (services.startupError != null) Text(services.startupError!),
        const SizedBox(height: 24),
      ],
    ),
  );
}
