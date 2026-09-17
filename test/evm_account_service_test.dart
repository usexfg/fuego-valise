import 'package:flutter_test/flutter_test.dart';

import 'package:fuego/services/evm_account_service.dart';

void main() {
  test('normalizes a valid EVM private key and derives its address', () {
    final key = '0x${'1'.padLeft(64, '0')}';

    expect(EvmAccountService.normalizePrivateKey(key), '1'.padLeft(64, '0'));
    expect(
      EvmAccountService.deriveAddress(key),
      '0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf',
    );
  });

  test('rejects malformed or out-of-range private keys', () {
    expect(
      () => EvmAccountService.normalizePrivateKey('not-a-key'),
      throwsArgumentError,
    );
    expect(
      () => EvmAccountService.normalizePrivateKey('0x${'0'.padLeft(64, '0')}'),
      throwsArgumentError,
    );
  });
}
