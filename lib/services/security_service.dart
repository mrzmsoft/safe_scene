import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../widgets/pin_dialog.dart';

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown when a Master PIN operation cannot proceed because [pin] is empty,
/// not exactly four digits, contains non-numeric characters, etc.
class InvalidPinException implements Exception {
  const InvalidPinException([this.message = 'PIN must be exactly 4 digits.']);
  final String message;

  @override
  String toString() => 'InvalidPinException: $message';
}

// ---------------------------------------------------------------------------
// Credential backend abstraction (testable)
// ---------------------------------------------------------------------------

/// Thin interface that [SecurityService] uses to persist the PIN verifier.
abstract class SecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Real implementation backed by [FlutterSecureStorage] (Windows Credential
/// Manager, macOS Keychain, etc.).
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
// ---------------------------------------------------------------------------
// SecurityService
// ---------------------------------------------------------------------------

const String _kMasterPinKey = 'safe_scene.master_pin.v1';

/// Master PIN controller for Safe Scene.
///
/// Stores a salted, iterated HMAC-SHA256 digest of a 4-digit PIN via
/// [flutter_secure_storage] and provides runtime verification.
///
/// The hashing scheme uses 10 000 iterations of XOR-folded HMAC-SHA256
/// (PBKDF2-HMAC-SHA256 with dkLen = 32) so that the PIN is never stored
/// in plain text even inside the secure storage backend.
class SecurityService {
  SecurityService({SecretStore? store, int hashIterations = 10000})
      : _store = store ?? SecureSecretStore(),
        _hashIterations = hashIterations;

  /// The number of HMAC iterations used when creating / updating the PIN.
  static const int defaultHashIterations = 10000;

  final SecretStore _store;
  final int _hashIterations;
  final Random _random = Random.secure();

  // -----------------------------------------------------------------------
  // Query / update
  // -----------------------------------------------------------------------

  /// Whether a Master PIN has been stored.
  Future<bool> hasPin() async => (await _store.read(_kMasterPinKey)) != null;

  /// Sets (or resets) the Master PIN to [pin].
  ///
  /// Throws [InvalidPinException] when the PIN does not match the 4-digit
  /// numeric constraint.
  Future<void> setPin(String pin) async {
    if (!isValidMasterPin(pin)) {
      throw const InvalidPinException();
    }
    final salt = _generateSalt();
    final hash = _pbkdf2(pin, salt, _hashIterations);
    final record = jsonEncode({
      's': _bytesToHex(salt),
      'h': hash,
      'i': _hashIterations,
    });
    await _store.write(_kMasterPinKey, record);
  }

  /// Verifies [pin] against the stored Master PIN.
  ///
  /// Returns `false` when no PIN is set, the format is invalid, or the
  /// comparison fails.
  Future<bool> verifyPin(String pin) async {
    if (!isValidMasterPin(pin)) return false;
    final raw = await _store.read(_kMasterPinKey);
    if (raw == null) return false;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final salt = _hexToBytes(data['s'] as String);
      final storedHash = data['h'] as String;
      final iterations = data['i'] as int? ?? _hashIterations;
      final computed = _pbkdf2(pin, salt, iterations);
      return _constantTimeEqual(storedHash, computed);
    } catch (_) {
      return false;
    }
  }

  /// Changes the PIN from [currentPin] to [newPin].
  ///
  /// Returns `true` on success. Returns `false` when [currentPin] is wrong
  /// or no PIN is set.
  Future<bool> changePin(String currentPin, String newPin) async {
    if (!await verifyPin(currentPin)) return false;
    await setPin(newPin);
    return true;
  }

  /// Removes the stored Master PIN entirely.
  Future<void> clearPin() async => _store.delete(_kMasterPinKey);
// -----------------------------------------------------------------------
  // Guard helpers (UI)
  // -----------------------------------------------------------------------

  /// Shows a PIN dialog and only resolves `true` when the correct Master PIN
  /// has been entered.
  ///
  /// If no PIN has been set, the dialog switches to a creation flow that
  /// stores the PIN before returning `true`.
  ///
  /// Use this to gate any action that should be protected by Parent Controls
  /// (e.g. opening the Scene Editor, adjusting filter sensitivities, or
  /// disabling Safe Mode).
  Future<bool> requirePin(
    BuildContext context, {
    String? title,
    String? message,
  }) async {
    if (!await hasPin()) {
      if (!context.mounted) return false;
      final pin = await PinDialog.create(
        context,
        title: title ?? 'Create Master PIN',
        message:
            message ?? 'A Master PIN is required for this action. '
                'Choose a 4-digit PIN.',
      );
      if (pin == null) return false;
      await setPin(pin);
      return true;
    }

    if (!context.mounted) return false;
    final entered = await PinDialog.verify(
      context,
      title: title ?? 'Enter Master PIN',
      message: message,
      validator: (pin) async =>
          (await verifyPin(pin)) ? null : 'Incorrect PIN. Please try again.',
    );
    return entered != null;
  }
// -----------------------------------------------------------------------
  // Cryptography
  // -----------------------------------------------------------------------

  List<int> _generateSalt() =>
      List<int>.generate(16, (_) => _random.nextInt(256));

  /// PBKDF2-HMAC-SHA256 with dkLen = 32 (single block).
  String _pbkdf2(String password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(password));

    // U1 = HMAC(P, S || INT(1))
    final u1Input = [...salt, 0x00, 0x00, 0x00, 0x01];
    var u = hmac.convert(u1Input).bytes;
    var result = List<int>.from(u);

    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return _bytesToHex(result);
  }

  /// Constant-time string comparison to avoid timing side-channels.
  static bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) {
      var diff = 0;
      final min = a.length < b.length ? a.length : b.length;
      for (var i = 0; i < min; i++) {
        diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
      }
      diff |= a.length ^ b.length;
      return diff == 0;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Whether [pin] is exactly four decimal digits.
bool isValidMasterPin(String pin) => RegExp(r'^\d{4}$').hasMatch(pin);
