# Heatwave Paid Ads — Teaser-Only, Default Paused

## Bottom line

Do not launch broad paid reach for a fictional banking-named teaser without explicit founder/legal approval. If any test is approved, keep it small, owned-audience-only, and disclaimer-first.

## Approved posture

- Default state: **paused**.
- Permitted test only: retargeting/owned-audience teaser-hub visits.
- Forbidden: broad prospecting, “bank” headlines, deposit/insurance/yield language, app-store/conversion claims.

## Campaign architecture if approved

```
HEATWAVE_TEASER_RETARGETING
├── Ad set: teaser-hub visitors, 30 days
│   ├── Ad A: identity angle
│   ├── Ad B: operational-honesty angle
│   └── Ad C: close/observer angle
└── Exclusions: converters, support/careers visitors, underage/irrelevant geos
```

## Targeting brief

- Primary: existing community/owned-audience only.
- No lookalikes until naming fallback and tracking consent are settled.
- Exclude anyone likely to interpret “bank” literally without disclaimer context.

## Prelaunch checklist

- [ ] Disclaimer present in ad, landing hub, and destination footer
- [ ] Conversion tracking tested with a real test conversion
- [ ] UTM taxonomy applied
- [ ] Landing page loads fast and matches ad promise
- [ ] Budget cap set; no aggressive scaling during learning
- [ ] Reply/complaint monitoring assigned

## Budget

TBD. Do not set a budget in-repo. Record approved spend only in the campaign tracker and finance system.
