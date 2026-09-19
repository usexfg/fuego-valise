//! `SwapPair` / `ChainType` against fuego-suite `src/SwapDaemon/SwapTypes.h`
//! and `SwapTypes.cpp`.

use fuego_sdk::chain::ChainType;
use fuego_sdk::types::SwapPair;

#[test]
fn covers_ids_0_through_28_with_no_gaps() {
    assert_eq!(SwapPair::all().len(), 29);
    for id in 0u8..29 {
        assert!(SwapPair::from_id(id).is_some(), "no pair for id {id}");
    }
    assert!(SwapPair::from_id(29).is_none());
    assert!(SwapPair::from_id(255).is_none());
}

#[test]
fn ids_match_the_cpp_enum() {
    for (id, ticker) in [
        (0u8, "SOL"), (1, "ETH"), (2, "XMR"), (3, "BCH"), (4, "ARB"), (5, "BASE"),
        (6, "KMD"), (7, "BNB"), (8, "DCR"), (9, "BTC"), (10, "LTC"), (11, "POLY"),
        (12, "GLEEC"), (13, "RHC"), (14, "AVAX"), (15, "CRO"), (16, "BOB"),
        (17, "SIA"), (18, "UNI"), (19, "XPL"), (20, "DOGE"), (21, "DASH"),
        (22, "ZEC"), (23, "PLS"), (24, "ZANO"), (25, "MON"), (26, "OP"),
        (27, "TON"), (28, "DOT"),
    ] {
        assert_eq!(SwapPair::from_id(id).unwrap().ticker(), ticker, "id {id}");
    }
}

#[test]
fn daemon_names_are_what_swap_pair_from_string_accepts() {
    // The six that diverge from the display ticker. Sending the ticker for
    // these is rejected as "Unknown swap pair".
    for (ticker, daemon) in [
        ("KMD", "KMD_SPV"),
        ("POLY", "POLYGON"),
        ("RHC", "ROBINHOOD"),
        ("UNI", "UNICHAIN"),
        ("XPL", "PLASMA"),
        ("PLS", "PULSEX"),
        ("MON", "MONAD"),
        ("OP", "OPTIMISM"),
    ] {
        let p = SwapPair::from_name(ticker).unwrap();
        assert_eq!(p.daemon_name(), daemon, "{ticker}");
    }
    // The rest round-trip.
    for p in SwapPair::all() {
        assert_eq!(SwapPair::from_name(p.daemon_name()), Some(*p));
        assert_eq!(SwapPair::from_name(p.ticker()), Some(*p));
    }
    assert!(SwapPair::from_name("NOPE").is_none());
}

#[test]
fn staged_pairs_are_the_four_without_a_registered_client() {
    let staged: Vec<&str> = SwapPair::all()
        .iter()
        .filter(|p| p.is_staged())
        .map(|p| p.ticker())
        .collect();
    assert_eq!(staged, vec!["SIA", "ZANO", "TON", "DOT"]);
    assert_eq!(SwapPair::registered().len(), 25);
}

#[test]
fn every_pair_maps_to_a_chain_type() {
    for p in SwapPair::all() {
        let c = p.chain_type();
        assert_eq!(c.symbol(), p.ticker(), "{:?} symbol mismatch", p);
    }
}

#[test]
fn evm_chains_all_have_a_chain_id() {
    for c in ChainType::all() {
        if c.is_evm() {
            assert!(c.evm_chain_id().is_some(), "{:?} has no chain id", c);
        } else {
            assert!(c.evm_chain_id().is_none(), "{:?} should not have one", c);
        }
    }
    assert_eq!(ChainType::Ethereum.evm_chain_id(), Some(1));
    assert_eq!(ChainType::Optimism.evm_chain_id(), Some(10));
    assert_eq!(ChainType::Avalanche.evm_chain_id(), Some(43114));
}

#[test]
fn decimals_are_set_for_every_chain() {
    assert_eq!(ChainType::Fuego.decimals(), 7);
    assert_eq!(ChainType::Bitcoin.decimals(), 8);
    assert_eq!(ChainType::Ethereum.decimals(), 18);
    assert_eq!(ChainType::Solana.decimals(), 9);
    assert_eq!(ChainType::Monero.decimals(), 12);
    for c in ChainType::all() {
        assert!(c.decimals() > 0 && c.decimals() <= 24, "{:?}", c);
    }
}

#[test]
fn from_symbol_accepts_the_daemon_aliases() {
    assert_eq!(ChainType::from_symbol("BSC"), Some(ChainType::Bnb));
    assert_eq!(ChainType::from_symbol("POLYGON"), Some(ChainType::Polygon));
    assert_eq!(ChainType::from_symbol("poly"), Some(ChainType::Polygon));
    assert_eq!(ChainType::from_symbol("KMD_SPV"), Some(ChainType::Komodo));
    assert_eq!(ChainType::from_symbol("POLKADOT"), Some(ChainType::Polkadot));
    assert_eq!(ChainType::from_symbol("XFG"), Some(ChainType::Fuego));
    assert_eq!(ChainType::from_symbol("nope"), None);
}

#[test]
fn evm_and_btc_families_are_disjoint() {
    for c in ChainType::all() {
        assert!(!(c.is_evm() && c.is_bitcoin_family()), "{:?}", c);
    }
    assert_eq!(ChainType::all().iter().filter(|c| c.is_evm()).count(), 15);
    assert_eq!(
        ChainType::all().iter().filter(|c| c.is_bitcoin_family()).count(),
        8
    );
}
