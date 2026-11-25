// GENERATED FILE — tool/gen_networks.dart. DO NOT EDIT.
// Included from types.rs. Discriminants are the suite SwapPair uint8.
// as_str() is the display label (XFG/TICKER). wire_name() is what
// swapPairToString returns. Do not send a display ticker to the daemon.

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[repr(u8)]
pub enum SwapPair {
    XfgSol = 0,
    XfgEth = 1,
    XfgXmr = 2,
    XfgBch = 3,
    XfgArb = 4,
    XfgBase = 5,
    XfgKmd = 6,
    XfgBnb = 7,
    XfgDcr = 8,
    XfgBtc = 9,
    XfgLtc = 10,
    XfgPoly = 11,
    XfgGleec = 12,
    XfgRobinhood = 13,
    XfgAvax = 14,
    XfgCro = 15,
    XfgBob = 16,
    XfgSia = 17,
    XfgUnichain = 18,
    XfgPlasma = 19,
    XfgDoge = 20,
    XfgDash = 21,
    XfgZec = 22,
    XfgPulsechain = 23,
    XfgZano = 24,
    XfgMonad = 25,
    XfgOptimism = 26,
    XfgTon = 27,
    XfgDot = 28,
}

impl SwapPair {
    pub fn wire_name(&self) -> &'static str {
        match self {
            Self::XfgSol => "SOL",
            Self::XfgEth => "ETH",
            Self::XfgXmr => "XMR",
            Self::XfgBch => "BCH",
            Self::XfgArb => "ARB",
            Self::XfgBase => "BASE",
            Self::XfgKmd => "KMD_SPV",
            Self::XfgBnb => "BNB",
            Self::XfgDcr => "DCR",
            Self::XfgBtc => "BTC",
            Self::XfgLtc => "LTC",
            Self::XfgPoly => "POLYGON",
            Self::XfgGleec => "GLEEC",
            Self::XfgRobinhood => "ROBINHOOD",
            Self::XfgAvax => "AVAX",
            Self::XfgCro => "CRO",
            Self::XfgBob => "BOB",
            Self::XfgSia => "SIA",
            Self::XfgUnichain => "UNICHAIN",
            Self::XfgPlasma => "PLASMA",
            Self::XfgDoge => "DOGE",
            Self::XfgDash => "DASH",
            Self::XfgZec => "ZEC",
            Self::XfgPulsechain => "PULSECHAIN",
            Self::XfgZano => "ZANO",
            Self::XfgMonad => "MONAD",
            Self::XfgOptimism => "OPTIMISM",
            Self::XfgTon => "TON",
            Self::XfgDot => "DOT",
        }
    }

    pub fn ticker(&self) -> &'static str {
        match self {
            Self::XfgSol => "SOL",
            Self::XfgEth => "ETH",
            Self::XfgXmr => "XMR",
            Self::XfgBch => "BCH",
            Self::XfgArb => "ARB",
            Self::XfgBase => "BASE",
            Self::XfgKmd => "KMD",
            Self::XfgBnb => "BNB",
            Self::XfgDcr => "DCR",
            Self::XfgBtc => "BTC",
            Self::XfgLtc => "LTC",
            Self::XfgPoly => "POLY",
            Self::XfgGleec => "GLEEC",
            Self::XfgRobinhood => "RHC",
            Self::XfgAvax => "AVAX",
            Self::XfgCro => "CRO",
            Self::XfgBob => "BOB",
            Self::XfgSia => "SIA",
            Self::XfgUnichain => "UNI",
            Self::XfgPlasma => "XPL",
            Self::XfgDoge => "DOGE",
            Self::XfgDash => "DASH",
            Self::XfgZec => "ZEC",
            Self::XfgPulsechain => "PLS",
            Self::XfgZano => "ZANO",
            Self::XfgMonad => "MON",
            Self::XfgOptimism => "OP",
            Self::XfgTon => "TON",
            Self::XfgDot => "DOT",
        }
    }

    /// Display label. Not the wire string.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::XfgSol => "XFG/SOL",
            Self::XfgEth => "XFG/ETH",
            Self::XfgXmr => "XFG/XMR",
            Self::XfgBch => "XFG/BCH",
            Self::XfgArb => "XFG/ARB",
            Self::XfgBase => "XFG/BASE",
            Self::XfgKmd => "XFG/KMD",
            Self::XfgBnb => "XFG/BNB",
            Self::XfgDcr => "XFG/DCR",
            Self::XfgBtc => "XFG/BTC",
            Self::XfgLtc => "XFG/LTC",
            Self::XfgPoly => "XFG/POLY",
            Self::XfgGleec => "XFG/GLEEC",
            Self::XfgRobinhood => "XFG/RHC",
            Self::XfgAvax => "XFG/AVAX",
            Self::XfgCro => "XFG/CRO",
            Self::XfgBob => "XFG/BOB",
            Self::XfgSia => "XFG/SIA",
            Self::XfgUnichain => "XFG/UNI",
            Self::XfgPlasma => "XFG/XPL",
            Self::XfgDoge => "XFG/DOGE",
            Self::XfgDash => "XFG/DASH",
            Self::XfgZec => "XFG/ZEC",
            Self::XfgPulsechain => "XFG/PLS",
            Self::XfgZano => "XFG/ZANO",
            Self::XfgMonad => "XFG/MON",
            Self::XfgOptimism => "XFG/OP",
            Self::XfgTon => "XFG/TON",
            Self::XfgDot => "XFG/DOT",
        }
    }

    pub fn from_id(id: u8) -> Option<Self> {
        match id {
            0 => Some(Self::XfgSol),
            1 => Some(Self::XfgEth),
            2 => Some(Self::XfgXmr),
            3 => Some(Self::XfgBch),
            4 => Some(Self::XfgArb),
            5 => Some(Self::XfgBase),
            6 => Some(Self::XfgKmd),
            7 => Some(Self::XfgBnb),
            8 => Some(Self::XfgDcr),
            9 => Some(Self::XfgBtc),
            10 => Some(Self::XfgLtc),
            11 => Some(Self::XfgPoly),
            12 => Some(Self::XfgGleec),
            13 => Some(Self::XfgRobinhood),
            14 => Some(Self::XfgAvax),
            15 => Some(Self::XfgCro),
            16 => Some(Self::XfgBob),
            17 => Some(Self::XfgSia),
            18 => Some(Self::XfgUnichain),
            19 => Some(Self::XfgPlasma),
            20 => Some(Self::XfgDoge),
            21 => Some(Self::XfgDash),
            22 => Some(Self::XfgZec),
            23 => Some(Self::XfgPulsechain),
            24 => Some(Self::XfgZano),
            25 => Some(Self::XfgMonad),
            26 => Some(Self::XfgOptimism),
            27 => Some(Self::XfgTon),
            28 => Some(Self::XfgDot),
            _ => None,
        }
    }

    pub fn from_id_str(ticker: &str) -> Option<Self> {
        match ticker.to_uppercase().as_str() {
            "SOL" => Some(Self::XfgSol),
            "ETH" => Some(Self::XfgEth),
            "XMR" => Some(Self::XfgXmr),
            "BCH" => Some(Self::XfgBch),
            "ARB" => Some(Self::XfgArb),
            "BASE" => Some(Self::XfgBase),
            "KMD" | "KMD_SPV" => Some(Self::XfgKmd),
            "BNB" => Some(Self::XfgBnb),
            "DCR" => Some(Self::XfgDcr),
            "BTC" => Some(Self::XfgBtc),
            "LTC" => Some(Self::XfgLtc),
            "POLY" | "POLYGON" => Some(Self::XfgPoly),
            "GLEEC" => Some(Self::XfgGleec),
            "RHC" | "ROBINHOOD" => Some(Self::XfgRobinhood),
            "AVAX" => Some(Self::XfgAvax),
            "CRO" => Some(Self::XfgCro),
            "BOB" => Some(Self::XfgBob),
            "SIA" | "SC" => Some(Self::XfgSia),
            "UNI" | "UNICHAIN" => Some(Self::XfgUnichain),
            "XPL" | "PLASMA" => Some(Self::XfgPlasma),
            "DOGE" => Some(Self::XfgDoge),
            "DASH" => Some(Self::XfgDash),
            "ZEC" => Some(Self::XfgZec),
            "PLS" | "PULSECHAIN" => Some(Self::XfgPulsechain),
            "ZANO" => Some(Self::XfgZano),
            "MON" | "MONAD" => Some(Self::XfgMonad),
            "OP" | "OPTIMISM" => Some(Self::XfgOptimism),
            "TON" => Some(Self::XfgTon),
            "DOT" | "POLKADOT" => Some(Self::XfgDot),
            _ => None,
        }
    }

    /// SPV ChainType, only where that enum already has an arm.
    /// None is not a new chain id. Do not extend ChainType here.
    pub fn chain_type(&self) -> Option<crate::chain::ChainType> {
        match self {
            Self::XfgSol => Some(crate::chain::ChainType::Solana),
            Self::XfgEth => Some(crate::chain::ChainType::Ethereum),
            Self::XfgXmr => Some(crate::chain::ChainType::Monero),
            Self::XfgBch => Some(crate::chain::ChainType::BitcoinCash),
            Self::XfgArb => Some(crate::chain::ChainType::Arbitrum),
            Self::XfgBase => Some(crate::chain::ChainType::Base),
            Self::XfgKmd => Some(crate::chain::ChainType::Komodo),
            Self::XfgBnb => Some(crate::chain::ChainType::Bnb),
            Self::XfgDcr => Some(crate::chain::ChainType::Decred),
            Self::XfgBtc => Some(crate::chain::ChainType::Bitcoin),
            Self::XfgLtc => Some(crate::chain::ChainType::Litecoin),
            Self::XfgPoly => Some(crate::chain::ChainType::Polygon),
            _ => None,
        }
    }

    pub fn all() -> &'static [SwapPair] {
        &[
            Self::XfgSol,
            Self::XfgEth,
            Self::XfgXmr,
            Self::XfgBch,
            Self::XfgArb,
            Self::XfgBase,
            Self::XfgKmd,
            Self::XfgBnb,
            Self::XfgDcr,
            Self::XfgBtc,
            Self::XfgLtc,
            Self::XfgPoly,
            Self::XfgGleec,
            Self::XfgRobinhood,
            Self::XfgAvax,
            Self::XfgCro,
            Self::XfgBob,
            Self::XfgSia,
            Self::XfgUnichain,
            Self::XfgPlasma,
            Self::XfgDoge,
            Self::XfgDash,
            Self::XfgZec,
            Self::XfgPulsechain,
            Self::XfgZano,
            Self::XfgMonad,
            Self::XfgOptimism,
            Self::XfgTon,
            Self::XfgDot,
        ]
    }
}

impl std::fmt::Display for SwapPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

#[cfg(test)]
mod swap_pair_generated_tests {
    use super::SwapPair;

    #[test]
    fn swap_pair_ids_round_trip() {
        let ids: Vec<u8> = SwapPair::all()
            .iter()
            .map(|p| *p as u8)
            .collect();
        for id in ids {
            let pair = SwapPair::from_id(id).expect("pin id");
            assert_eq!(pair as u8, id);
            assert!(SwapPair::from_id_str(pair.ticker()).is_some());
            assert!(SwapPair::from_id_str(pair.wire_name()).is_some());
        }
        // The next id after the pin max must not resolve — a new
        // member simply extends the set.
        let max = SwapPair::all().iter().map(|p| *p as u8).max().expect("pin");
        assert!(SwapPair::from_id(max + 1).is_none());
    }
}
