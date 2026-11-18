---
name: trading-ui-design
description: Trading-app UI for the Valise surfaces that are allowed to look like fintech — the portfolio slide-out and DeXFG. Dark, dense, green/red with arrows, timeframe chips on the chart, one-tap actions, stale history labeled. Do not use on Hearth or the Fuego-only home; those stay maison. Use when designing or restyling portfolio, DeXFG, charts, order books, quote strips, or any trading-terminal surface.
---

# Trading UI Design

Design law for the Valise surfaces that are **supposed** to feel like a trading app. It is the exception to Maison. It does not replace `fuego-maison-brand`.

Source: David Pham, “Trading App Design: The Complete Guide to UI, UX & System Architecture” (Medium, 2 Jun 2026). The rules below are the parts that apply to this wallet. Lollypop’s sales copy, gamification, and AI-search pitch are not part of the system.

## Where this skill applies

| Surface | Language | Why |
|---|---|---|
| Home, Fuego mode | Maison | XFG dial + ΗΞΔŦ only. The house. |
| Portfolio slide-out | **This skill** | Holdings, quote, chart. The fintech exception. |
| DeXFG | **This skill** | Book, ticket, chart. Mainstream terminal. |
| Hearth | Maison | Floor, not a retail broker. Do not restyle it. |
| CDs, Settings, auth | Maison / existing | Out of scope. |

A control on the maison home may **open** the portfolio. It must not turn the home itself into a broker dashboard.

## When to use

- Building or restyling the portfolio sheet, DeXFG, a quote strip, a candle chart, an order book, or a position row.
- The user asks for trading UI, fintech density, Robinhood/Coinbase/Binance familiarity, or “use the space better” on those surfaces.

## When not to use

- Hearth, the Fuego-only home, mint copy, or anything the maison skill owns.
- Inventing prices, P&L, or live candles the app does not have.
- Gamification that rewards frequent trading (streaks, badges, confetti on a fill). The source article flags this as harmful. Do not add it.

## Five rules

### 1. Hierarchy, then density

One number leads. Everything else is smaller and quieter.

- Portfolio: total USD (XFG + ΗΞΔŦ only) is the lead figure. Spot, peg, and window change sit under it.
- DeXFG: the pair and the last price lead. The book is the next layer, not a second hero.
- Secondary metrics (volume, lock type, chain family) stay caption-sized. They do not compete with the price.

Density is rows and a chart, not stacked luxury plates. A position row is one line: mark, ticker, name, amount, value or an em dash. No bezel, no guilloché, no Cormorant.

### 2. Green up, red down — never color alone

| Token | Hex | Use |
|---|---|---|
| Gain | `#16C784` | Up candle, positive change |
| Loss | `#EA3943` | Down candle, negative change |
| Flat | `#8B95A1` | Unchanged, unknown |
| Background | `#0B0E11` | Terminal ground |
| Panel | `#12161C` | Chart, bar, sheet |
| Hairline | `#1E2630` | Row rules |
| Text | `#E8EDF2` | Figures and tickers |
| Muted | `#8B95A1` | Captions |
| Accent | `#4C8DFF` | Selection, timeframe chip, focus. Not champagne. |

Every gain/loss also carries an arrow and a sign: `▲ +1.2%`, `▼ -0.4%`, `– 0.0%`. About 8% of men cannot separate red from green. Color is reinforcement, not the signal.

Do not use maison sage (`#7A9B7E`) or burgundy (`#7A1C1C`) for direction on these surfaces. Do not use champagne as the up-color.

Contrast: text and the gain/loss colors above clear WCAG 2.1 AA (4.5:1) on `#0B0E11`. Do not drop either below that on the terminal ground.

### 3. The chart is the decision surface

- Timeframe chips sit **on** the quote row, beside the price: `1M · 3M · 1Y · ALL`. Not in settings.
- The window’s open-to-close change is labeled with that window (`1Y`), never implied to be “today”.
- History that is not a live feed is marked `HISTORY`. `assets/data/xfg_historical_prices.json` is XFG USD history. It is not the selected DeXFG pair and it is not a live candle stream. Do not label it `XFG/ETH`.
- A missing or loading series is a labeled empty state, not a blank 35% slab.
- The chart collapses to the quote row. Default open, one tap shut, so the book or the position list can take the screen.
- Crosshair / press readout may replace the last price while the finger is down. It must release back to the window close.
- No flicker treated as polish. A stale series stays on screen with its label; do not swap in a zero.

### 4. One tap to act, a deliberate step to commit

From the portfolio sheet, Send, Receive, and Mint are on a sticky bar. They are not inside a menu.

The irreversible step stays on the existing ticket (Send, Mint, DeXFG accept). Do not add a second confirmation style, and do not remove the one the screen already has. Swipe-to-confirm is not required if the ticket already forces a review before broadcast.

Advanced order fields stay behind the existing ticket. Do not surface limit, slippage, and counterparty key on the portfolio sheet.

### 5. Say what you do not know

- Unpriced chains render `—`, not `$0.00`.
- An unreadable RPC renders `—` and a count, not a zero balance.
- A walletd that omits HEAT keys renders `—` and “balance not reported”, not an empty reserve.
- SOL has no key on device. Say that. Do not draw a SOL balance row.
- The portfolio total prices XFG and ΗΞΔŦ only, and the caption says so.

## Space budget

Phone, portrait. If a block is taller than this, it is wasting the book or the position list.

| Block | Budget |
|---|---|
| Home mode row (Fuego / Portfolio) | 32px. Text, not a pill banner. |
| Quote row + timeframe chips | 44px, one line if it fits |
| Open chart | 156–188px. Not 30–35% of the screen. |
| Collapsed chart | the quote row only |
| Position row | 40px |
| Sheet action bar | 48px + safe area |
| DeXFG pair bar | one horizontal line, 44px. Overflow scrolls; it does not wrap into a second hero. |

The maison home keeps the XFG dial and the ΗΞΔŦ plate. It does not also carry a portfolio header and a 33-chain drawer. Those live in the sheet.

## Motion

- Sheet enters from the trailing edge, ~280ms, `easeOutCubic`. A sliver of the maison home stays visible on wide phones so the sheet reads as a layer, not a new house.
- Barrier tap and the `Fuego` control both close it.
- Live-connection pulse, if any, is a 6px dot. No looping shimmer behind prices.
- Collapse of the chart is an `AnimatedSize`, not a route change.

## Type

- Words: the app sans (`AppTheme.fontFamily`). Not Cormorant. Not letterspaced small-caps as the primary voice.
- Figures: `AppTheme.numberFontFamily` with tabular figures.
- Tickers: 12–13px, semibold, `#E8EDF2`.
- Captions: 10–11px, `#8B95A1`.
- One lead figure per surface, 22–28px. A second 28px number is a hierarchy failure.

## Components to reuse

| Widget | Path | Job |
|---|---|---|
| `TradingStyle` | `lib/widgets/trading/trading_style.dart` | Tokens, figure/caption styles |
| `TradingSeries` | `lib/widgets/trading/trading_series.dart` | Window slice, downsample, move, price format |
| `TradingChart` | `lib/widgets/trading/trading_chart.dart` | Quote, chips, collapsible candles |
| `PortfolioSheet` | `lib/widgets/trading/portfolio_sheet.dart` | The slide-out |
| `HomeModeBar` | `lib/widgets/trading/home_mode_bar.dart` | Fuego (stay) / Portfolio (open) |

Do not restyle these with maison gold, plates, or guilloché. Do not point DeXFG or the sheet at `FuegoChart` / `MaisonCandleChart` — those belong to Hearth and the house quotation board.

## Building a new trading block

1. Name the lead figure and the one action. If you cannot, the block is not ready.
2. Use `TradingStyle` tokens. No new green, no champagne up-color.
3. Put timeframe chips on the quote row if there is a chart.
4. Label any series that is not live.
5. Render unknown as `—`.
6. Check the row at 360px wide. Ticker and amount must both be visible; the name ellipsizes.
7. Add an arrow or a word beside any red/green signal.
8. Leave Hearth and the Fuego dial alone.

## Anti-patterns

- A portfolio total that includes unpriced chain balances as zero.
- `XFG/ETH` (or any pair) on a chart whose data is XFG USD history.
- Champagne candles, hollow-gold down candles, or maison plates inside the sheet or DeXFG.
- A chart that always consumes a third of the screen.
- Color as the only up/down signal.
- Streaks, badges, or “you’re on a roll” after a swap.
- A trade button that broadcasts without the existing review step.
- Hiding the Fuego-only home behind the portfolio. The sheet closes; the dial is still there.
