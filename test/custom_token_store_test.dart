import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fuego/models/erc20_token.dart';
import 'package:fuego/services/custom_token_store.dart';

/// A contract the user pasted in has not been checked against an issuer, so
/// it must never land in the stable list — not even when it claims to be
/// USDC and not even when it collides with a registry address.
void main() {
  const vvv = '0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf';
  const usdcBase = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
  const fake = '0x00000000000000000000000000000000DEADBEEF';

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'erc20_custom_tokens_v1': jsonEncode([
        // Claims a stable ticker. Still a user token.
        {
          'address': fake,
          'symbol': 'USDC',
          'name': 'Definitely Real USDC',
          'decimals': 6,
          'chain': 'base',
        },
        // Duplicates a registry entry by address.
        {
          'address': usdcBase,
          'symbol': 'USDC',
          'name': 'Shadow of the registry entry',
          'decimals': 6,
          'chain': 'base',
        },
      ]),
    });
    CustomTokenStore.instance.resetForTest();
  });

  test('stored entries load as Erc20Kind.token whatever they call themselves',
      () async {
    final customs = await CustomTokenStore.instance.customsFor('base');
    expect(customs, isNotEmpty);
    for (final t in customs) {
      expect(t.kind, Erc20Kind.token);
      expect(t.isStable, isFalse);
    }
  });

  test('the stable slice is registry-only', () async {
    final stables = await CustomTokenStore.instance
        .forChain('base', filter: Erc20Filter.stables);
    expect(stables.every((t) => t.isStable), isTrue);
    expect(stables.map((t) => t.lcAddress), isNot(contains(fake.toLowerCase())));
    // The three curated Base dollars, and nothing the user added.
    expect(stables.length, 3);
  });

  test('a custom entry never shadows a registry entry at the same address',
      () async {
    final all = await CustomTokenStore.instance.forChain('base');
    final atUsdc =
        all.where((t) => t.lcAddress == usdcBase.toLowerCase()).toList();
    expect(atUsdc.length, 1, reason: 'registry + custom both present');
    expect(atUsdc.single.name, 'USD Coin (Base)');
    expect(atUsdc.single.kind, Erc20Kind.nativeStable);
  });

  test('the token slice carries registry non-stables and user entries',
      () async {
    final tokens = await CustomTokenStore.instance
        .forChain('base', filter: Erc20Filter.tokens);
    final addrs = tokens.map((t) => t.lcAddress).toList();
    expect(addrs, contains(vvv.toLowerCase())); // registry, not a stable
    expect(addrs, contains(fake.toLowerCase())); // user-added
    expect(addrs, isNot(contains(usdcBase.toLowerCase())));
    expect(tokens.every((t) => !t.isStable), isTrue);
  });

  test('slices partition the merged list', () async {
    final store = CustomTokenStore.instance;
    final all = await store.forChain('base');
    final st = await store.forChain('base', filter: Erc20Filter.stables);
    final tk = await store.forChain('base', filter: Erc20Filter.tokens);
    expect(st.length + tk.length, all.length);
  });

  test('exists() sees both registry and custom entries', () async {
    expect(await CustomTokenStore.instance.exists('base', usdcBase), isTrue);
    expect(await CustomTokenStore.instance.exists('base', fake), isTrue);
    expect(
      await CustomTokenStore.instance
          .exists('base', '0x1111111111111111111111111111111111111111'),
      isFalse,
    );
  });
}
