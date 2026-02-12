# ASO Data Sources (Codex)

Last updated: 2026-01-03

## Overview

Use the following sources in priority order. Prefer official APIs for accuracy and legality. Use browsing only when APIs do not provide needed fields. Ask the user for inputs when neither API nor browsing is practical.

## 1) iTunes Search API (Apple App Store)

- Provider: Apple
- Access: Free, no auth required
- Coverage: App metadata, ratings, screenshots, category, price
- Limits: No official rate limit; use reasonable pacing

Useful endpoints:
- Search by keyword: https://itunes.apple.com/search?term=todoist&entity=software&limit=5
- Lookup by ID: https://itunes.apple.com/search?id=572688855&entity=software

Python helper:
- `scripts/itunes_api.py` provides a small wrapper to search, fetch, and normalize metadata.

## 2) Web browsing for page extraction (App Store / Play Store)

Use Codex browsing to extract fields that are not available via the iTunes Search API (for example, subtitle, what is new, or visible review text). Keep requests light and validate extracted data.

Recommended flow:
- Use App Store or Play Store search pages to find app URLs.
- Open the app page and extract metadata, ratings, and visible reviews.
- Cache results in the response so repeated lookups are not needed.

Prompt templates:
- `scripts/scraper.py` includes prompt templates for app search and app page extraction.

## 3) User-provided data

Ask the user for any of the following if needed:
- Search volume estimates or keyword rankings
- Conversion rates (impression to install)
- A/B test baselines and results
- App Store Connect / Play Console metrics

## Notes

- Store policies and field limits can change. Verify current limits before final deliverables.
- Do not scrape at scale or bypass access controls.
