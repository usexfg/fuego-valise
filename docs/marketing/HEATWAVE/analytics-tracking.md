# Heatwave Analytics Tracking — Measurement Rules

## Bottom line

Measure attention and misunderstanding, not revenue. Do not instrument financial conversions that do not exist.

## UTM taxonomy

| Parameter | Convention | Example |
|---|---|---|
| `utm_source` | lowercase platform | `x`, `linkedin`, `instagram`, `newsletter` |
| `utm_medium` | traffic type | `social`, `email`, `owned` |
| `utm_campaign` | campaign slug | `heatwave-teaser` |
| `utm_content` | creative variant | `identity-a`, `honesty-b`, `close-c` |

Never tag organic/direct traffic with UTMs outside the campaign.

## Event taxonomy

| Event | Meaning | Key event? |
|---|---|---|
| `teaser_viewed` | Campaign hub viewed | Yes |
| `teaser_disclaimer_viewed` | Disclaimer block viewed | No |
| `email_opened` | Teaser email opened | No |
| `email_clicked` | Teaser email CTA clicked | Yes |
| `social_clicked` | Social teaser link clicked | Yes |
| `misunderstanding_reported` | Banking/release/yield confusion reply tagged | No |

Use `object_action` snake-case naming. Include `campaign=heatwave-teaser` and `content=<variant>` where supported.

## Implementation notes

- No GA4 measurement ID, pixel ID, or secrets belong in this repo.
- If paid tracking is approved later, test conversion tracking with a real test conversion before launch.
- Respect consent rules for the targeted region.
- Keep misunderstanding replies as a qualitative metric; do not optimize creative toward confusion.
