# Heatwave Brand Audit

*Date: 2026-09-14*
*Scope: `lib/utils/theme.dart`, `lib/widgets/swap`, `docs/marketing`*

## Automated result

`audit-brand.sh --theatre`: **PASS**

- Banned old orange: pass.
- Theatre lexicon: pass.
- Theme tokens: pass.
- Campaign inversion present: pass.

## Manual house review

- [x] Timeless stability — obsidian/champagne/midnight system; no neon or trend styling.
- [x] Intellectual capital — declarative copy; technical limits stated.
- [x] Understated elegance — teaser-only scope; paid reach paused by default.
- [x] Pillar present — stealth wealth/sound money/restraint throughout.
- [x] Cultural institution — house language, not fintech slang.
- [x] Inversion — “No insurance on deposits. We carry sound money.”
- [x] Lexicon — original teaser corrected from “atomic swap” to “private exchange.”
- [x] Palette — no banned orange/cyan/neon codes found in campaign docs.
- [x] Typography/material — docs do not introduce new UI type or surfaces.
- [ ] External visual Loupe Test — pending; actual luxury imagery still requires approval.

## Accepted internal-doc exceptions

- Status markers such as ✅/⏳/⚠️ appear in working docs only, not customer ad copy.
- “Maison de XFG” and “Sound Money Reserve” appear only as future alternatives, not parallel brands.

## Required fixes applied

- Removed stale release-commit implication from teaser header.
- Fixed “obsidean” and “#heatswave” typos.
- Removed “first private atomic swap” overclaim.
- Scoped SPV language as chain-dependent.
- Retired “Bank of XFG”; standardized on Obsidian Reserve.
- Removed repeated full disclaimers; legal background lives in `naming-legal-review.md` only.
