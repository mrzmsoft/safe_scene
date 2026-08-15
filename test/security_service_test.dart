import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safe_scene/services/security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Isolate each test from the previous one's stored PIN.
    FlutterSecureStorage.setMockInitialValues({});
  });

  SecurityService service() => SecurityService(hashIterations: 250);

  group('isValidMasterPin', () {
    test('accepts exactly four digits', () {
      expect(isValidMasterPin('1234'), isTrue);
    });

    test('rejects wrong length and non-digits', () {
      expect(isValidMasterPin('123'), isFalse);
      expect(isValidMasterPin('12345'), isFalse);
      expect(isValidMasterPin('12a4'), isFalse);
      expect(isValidMasterPin(''), isFalse);
    });
  });

  group('SecurityService', () {
    test('hasPin is false before a PIN is set and true after', () async {
      final s = service();
      expect(await s.hasPin(), isFalse);
      await s.setPin('1234');
      expect(await s.hasPin(), isTrue);
    });

    test('setPin throws for an invalid PIN', () async {
      final s = service();
      expect(() => s.setPin('12'), throwsA(isA<InvalidPinException>()));
      expect(() => s.setPin('abcd'), throwsA(isA<InvalidPinException>()));
      expect(await s.hasPin(), isFalse);
    });

    test('verifyPin accepts the correct PIN and rejects wrong ones', () async {
      final s = service();
      await s.setPin('2468');

      expect(await s.verifyPin('2468'), isTrue);
      expect(await s.verifyPin('0000'), isFalse);
      expect(await s.verifyPin('xxxx'), isFalse);
    });

    test('verifyPin is false when no PIN is stored', () async {
      final s = service();
      expect(await s.verifyPin('1234'), isFalse);
    });

    test('created PIN survives a fresh service instance (persisted hash)',
        () async {
      await service().setPin('1357');
      final fresh = service();
      expect(await fresh.verifyPin('1357'), isTrue);
      expect(await fresh.verifyPin('2468'), isFalse);
    });

    test('changePin updates the stored PIN', () async {
      final s = service();
      await s.setPin('1111');

      expect(await s.changePin('9999', '2222'), isFalse);
      expect(await s.changePin('1111', '2222'), isTrue);

      expect(await s.verifyPin('1111'), isFalse);
      expect(await s.verifyPin('2222'), isTrue);
    });

    test('clearPin removes the stored PIN', () async {
      final s = service();
      await s.setPin('0000');
      await s.clearPin();
      expect(await s.hasPin(), isFalse);
      expect(await s.verifyPin('0000'), isFalse);
    });

    test('stored record is never the plain PIN', () async {
      await service().setPin('0000');
      // Read the backing store directly to assert the PIN is salted/hashed.
      final raw = await const FlutterSecureStorage()
          .read(key: 'safe_scene.master_pin.v1');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('0000')));
      expect(raw, contains('"h"'));
    });
  });
}