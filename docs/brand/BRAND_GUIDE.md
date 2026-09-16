# Obsidian Reserve — Brand System — The Obsidian Case

> Single source: `assets/brand/design-tokens.json`
> Doctrine: `~/.opencode/skills/fuego-luxury-brand/references/brand-doctrine.md`

## What Pro Designers Do (Why It Was Clashing)

Clashing happened because 4 palettes competed:
- Fire orange `D84315/FF5722` (old Fuego) vs Champagne Gold `C5A059` (house) vs Cyan `00ACC1` (Hearth bids) vs Neon semantic `4CAF50/F44336/2196F3`
- Pros never do that. They do:

1. **Single source of truth** — one `design-tokens.json`, not scattered `Color(0xFF…)` per file. Every `Color` in code references `AppTheme`/`HearthTheme` which references tokens.
2. **60-30-10** — 60% neutral base (Obsidian family), 30% primary (Champagne Gold), 10% accent (Midnight Blue). No fourth saturated color. Fire gold IS champagne gold — not a separate orange.
3. **Muted semantics** — success/warning/error/info are desaturated sage/burgundy/slate at low opacity (`0.12` bg), not neon. They whisper.
4. **Warm vs cold alignment** — all neutrals warm obsidian (`0D0B08/12100C/181512`) — never blue-gray `1A1F26/30363D` mixing warm + cold.
5. **Limit to 3 hues** — Obsidian, Champagne, Midnight Blue. Everything else is tint/opacity of those.

## The Coherent System (Now Applied)

```
60%  Obsidian neutrals  #0D0B08 #12100C #181512 #25221A #1E1B14 — background/surface/card
30%  Champagne Gold     #C5A059 #D4B896 #8C734B #6B5637 — primary, progress, headlines, ask side
10%  Midnight Blue      #3D5A80 #5A7A9C — accent, provenance, bid side
—    Parchment text     #F5F1E8 #C2B8A3 #8A8278 — cream on dark, not cold white
—    Muted semantic     Sage 7A9B7E / Burgundy 7A1C1C / Slate 5A7A9C at 0.12 bg
```

**Fire gold = Champagne gold.** There is no separate fire orange. The balance glyph gradient `C5A059→D4B896→8C734B` IS the fire gradient — muted, luminous, not peachy `FF8A5C`.

## How to Repeat (Brand Assets)

- **Tokens**: `assets/brand/design-tokens.json` — edit here, then mirror to `lib/utils/theme.dart` + `lib/utils/hearth_theme.dart`. Never hardcode `Color(0xFF…)` outside those two files.
- **Typography**: `Cormorant Garamond` headlines / `Inter` body / `IBM Plex Mono` + `NotoSans` numbers — max 2 per surface. Defined in tokens.
- **Material**: Card `12px` radius, `1px Muted Gold @0.18` border, `0-1px` shadow, `3-4px` progress, `400ms ease`.
- **Audit**: `~/.opencode/skills/fuego-luxury-brand/scripts/audit-brand.sh --theatre` must PASS before commit. Full audit flags legacy `Seed Phrase` etc. for next pass.

## What Changed This Pass

- `theme.dart:14-22` orange/neon → gold scale + sage/burgundy/slate muted
- `theme.dart:32-34` cold white `FFFFFF/B3B3B3` → parchment `F5F1E8/C2B8A3/8A8278`
- `theme.dart:182,233` divider/track blue-gray → warm brushed platinum
- `hearth_theme.dart:6-43` bgPure `000000→0D0B08`, bid cyan `00ACC1→3D5A80` midnight, asks already champagne, text→parchment, borders→warm
- `home_screen.dart:19` peachy `FF8A5C→C5A059`, `screenH` fireStops → champagne scale, balance `ShaderMask` gradient added
- `chain_info.dart:266` XFG `D84315→C5A059`

## Next (If You Want Even Tighter)

- Add `assets/brand/logo/` + `assets/brand/textures/` (brushed metal macro, yacht teak) and reference only those
- Replace remaining semantic uses in `lib/widgets/` with tokens (no `Colors.orange` etc.)
- Run visual Loupe Test at 200% per `fuego-luxury-brand:brand-audit.md`

## The Answer

Pros don't "find a better orange." They remove the orange. One gold, one blue, one black — everything else is opacity and warmth.
