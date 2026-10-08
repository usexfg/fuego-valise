//! Hearth pool arithmetic, ported from `src/CryptoNoteCore/AmmPool.cpp`, and
//! the wallet quoting policy from `CryptoNoteConfig.h`. Consensus validates
//! every declared amount with the same integer math, so a quote built here is
//! accepted exactly when the C++ wallet's would be.

/// CryptoNoteConfig.h COIN (XFG and HEAT share it).
pub const COIN: u64 = 10_000_000;
/// HEARTH_FEE_BPS: the 1% taker fee.
pub const HEARTH_FEE_BPS: u64 = 100;
pub const HEARTH_FEE_DIVISOR: u64 = 10_000;
/// WALLET_SWAP_SLIPPAGE_BPS: swaps, LP adds and removals are declared this
/// far under the curve, so reserves that move before inclusion do not
/// invalidate them. Wallet policy, not consensus.
pub const WALLET_SWAP_SLIPPAGE_BPS: u64 = 50;
/// WALLET_MINT_TWAP_MARGIN_BPS: HEAT mints are built this far under the TWAP.
pub const WALLET_MINT_TWAP_MARGIN_BPS: u64 = 50;
/// ORDER_PRICE_TICK: limit prices are multiples of COIN / 100.
pub const ORDER_PRICE_TICK: u64 = COIN / 100;
/// LP deposits must sit within 1% of the pool ratio (validateSettlement).
pub const LP_DEPOSIT_RATIO_TOLERANCE_BPS: u32 = 100;
/// HEAT_MINT_MIN_HEAT / TESTNET_HEAT_MINT_MIN_HEAT.
pub const HEAT_MINT_MIN_HEAT: u64 = 1_000_000;
pub const TESTNET_HEAT_MINT_MIN_HEAT: u64 = 100_000;

fn isqrt128(n: u128) -> u64 {
    if n <= 1 {
        return n as u64;
    }
    let mut x = n;
    let mut y = (x + 1) >> 1;
    while y < x {
        x = y;
        y = (x + n / x) >> 1;
    }
    x as u64
}

/// ammGetOutputAmount: constant-product output for `input` at `fee_bps`.
pub fn get_output_amount(input: u64, reserve_in: u64, reserve_out: u64, fee_bps: u64) -> u64 {
    if reserve_in == 0 || reserve_out == 0 || input == 0 {
        return 0;
    }
    let fee_adj = (HEARTH_FEE_DIVISOR - fee_bps) as u128;
    let num = reserve_out as u128 * input as u128 * fee_adj;
    let den = reserve_in as u128 * HEARTH_FEE_DIVISOR as u128 + input as u128 * fee_adj;
    (num / den) as u64
}

/// ammGetSpotPrice: HEAT atomics per XFG atomic × COIN.
pub fn spot_price(reserve_xfg: u64, reserve_heat: u64) -> u64 {
    if reserve_xfg == 0 {
        return 0;
    }
    (reserve_heat as u128 * COIN as u128 / reserve_xfg as u128) as u64
}

/// ammSwapNetOutput: the curve's output less the 1% taker fee — the most a
/// swap may declare.
pub fn swap_net_output(input: u64, reserve_in: u64, reserve_out: u64) -> u64 {
    let gross = get_output_amount(input, reserve_in, reserve_out, 0);
    (gross as u128 * (HEARTH_FEE_DIVISOR - HEARTH_FEE_BPS) as u128 / HEARTH_FEE_DIVISOR as u128) as u64
}

/// ammMintLpShares: shares a balanced deposit earns (none single-sided).
pub fn mint_lp_shares(
    amount_xfg: u64,
    amount_heat: u64,
    total_shares: u64,
    reserve_xfg: u64,
    reserve_heat: u64,
) -> u64 {
    if amount_xfg == 0 || amount_heat == 0 {
        return 0;
    }
    if total_shares == 0 {
        let shares = isqrt128(amount_xfg as u128 * amount_heat as u128);
        const MIN_LIQUIDITY: u64 = 1000;
        return shares.saturating_sub(MIN_LIQUIDITY);
    }
    if reserve_xfg == 0 || reserve_heat == 0 {
        return 0;
    }
    let a = amount_xfg as u128 * total_shares as u128 / reserve_xfg as u128;
    let b = amount_heat as u128 * total_shares as u128 / reserve_heat as u128;
    a.min(b) as u64
}

/// ammGetWithdrawalAmounts: the shares' pro-rata claim on both reserves.
pub fn withdrawal_amounts(
    shares: u64,
    total_shares: u64,
    reserve_xfg: u64,
    reserve_heat: u64,
) -> (u64, u64) {
    if total_shares == 0 {
        return (0, 0);
    }
    (
        (shares as u128 * reserve_xfg as u128 / total_shares as u128) as u64,
        (shares as u128 * reserve_heat as u128 / total_shares as u128) as u64,
    )
}

/// ammValidateDepositRatio: the deposit within `tolerance_bps` of the pool.
pub fn deposit_ratio_ok(
    amount_xfg: u64,
    amount_heat: u64,
    reserve_xfg: u64,
    reserve_heat: u64,
    tolerance_bps: u32,
) -> bool {
    if reserve_xfg == 0 || reserve_heat == 0 {
        return false;
    }
    let expected = amount_xfg as u128 * reserve_heat as u128;
    let actual = amount_heat as u128 * reserve_xfg as u128;
    let delta = expected.abs_diff(actual);
    delta <= expected * tolerance_bps as u128 / HEARTH_FEE_DIVISOR as u128
}

fn under(amount: u64, bps: u64) -> u64 {
    (amount as u128 * (10_000 - bps) as u128 / 10_000) as u64
}

/// The HEAT a mint of `xfg_burned` declares: the burn at the 8-block TWAP,
/// WALLET_MINT_TWAP_MARGIN_BPS under it (SimpleWallet's mint quote).
pub fn quote_mint(xfg_burned: u64, twap: u64) -> u64 {
    let at_twap = xfg_burned as u128 * twap as u128 / COIN as u128;
    (at_twap * (10_000 - WALLET_MINT_TWAP_MARGIN_BPS) as u128 / 10_000) as u64
}

/// The output a swap declares: the curve's net output, slippage under it.
/// `direction` 0 sells XFG for HEAT, 1 sells HEAT for XFG.
pub fn quote_swap(direction: u8, input: u64, reserve_xfg: u64, reserve_heat: u64) -> u64 {
    let net = if direction == 0 {
        swap_net_output(input, reserve_xfg, reserve_heat)
    } else {
        swap_net_output(input, reserve_heat, reserve_xfg)
    };
    under(net, WALLET_SWAP_SLIPPAGE_BPS)
}

/// The shares an LP add declares: what the deposit earns, slippage under it.
pub fn quote_lp_add(
    amount_xfg: u64,
    amount_heat: u64,
    total_shares: u64,
    reserve_xfg: u64,
    reserve_heat: u64,
) -> u64 {
    under(
        mint_lp_shares(amount_xfg, amount_heat, total_shares, reserve_xfg, reserve_heat),
        WALLET_SWAP_SLIPPAGE_BPS,
    )
}

/// The payouts an LP removal declares: the shares' pro-rata claim, slippage
/// under it. The pool pays exactly what is declared.
pub fn quote_lp_remove(
    shares: u64,
    total_shares: u64,
    reserve_xfg: u64,
    reserve_heat: u64,
) -> (u64, u64) {
    let (xfg, heat) = withdrawal_amounts(shares, total_shares, reserve_xfg, reserve_heat);
    (under(xfg, WALLET_SWAP_SLIPPAGE_BPS), under(heat, WALLET_SWAP_SLIPPAGE_BPS))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Values from the C++ functions (AmmPool.cpp) at the genesis seed:
    // 10,000 XFG / 1,000 HEAT, shares = isqrt(xfg * heat).
    const RX: u64 = 10_000 * COIN;
    const RH: u64 = 1_000 * COIN;

    #[test]
    fn seed_spot_and_shares() {
        assert_eq!(spot_price(RX, RH), COIN / 10);
        let seed = isqrt128(RX as u128 * RH as u128);
        assert_eq!(seed, 31_622_776_601);
        // 1% of both reserves earns 1% of the shares.
        assert_eq!(mint_lp_shares(RX / 100, RH / 100, seed, RX, RH), seed / 100);
    }

    #[test]
    fn swap_quote_stays_under_the_curve() {
        let input = 100 * COIN;
        let net = swap_net_output(input, RX, RH);
        let quote = quote_swap(0, input, RX, RH);
        assert!(quote < net && quote > 0);
        // Linear spot pricing would have declared more than the curve allows.
        let linear = (input as u128 * spot_price(RX, RH) as u128 / COIN as u128 * 99 / 100) as u64;
        assert!(linear > net);
    }

    #[test]
    fn deposit_ratio_tolerance() {
        assert!(deposit_ratio_ok(RX / 100, RH / 100, RX, RH, 100));
        assert!(!deposit_ratio_ok(RX / 100, RH / 100 * 102 / 100, RX, RH, 100));
    }

    #[test]
    fn mint_quote_is_under_the_twap() {
        let twap = COIN / 10;
        assert_eq!(quote_mint(100 * COIN, twap), 10 * COIN * 9_950 / 10_000);
    }
}
