# 日本語辞典 — Japanese Study App

A personal Japanese study tool built around proper nouns, stations, prefectures and names — with WaniKani integration planned for Phase 2.

## Features
- **Dictionary** — Browse, search and filter all items by category, subcategory and level
- **Review Quiz** — Practice unlocked items with configurable filters
- **New Quiz** — Unlock new items by answering correctly
- **Progress tracking** — 6-level confidence system (Locked → Review → Apprentice → Guru → Master → Enlightened)
- **Memory hooks** — Study notes and mnemonics per item

## Confidence Levels
| Level | Name | Description |
|-------|------|-------------|
| 0 | Locked | Not yet encountered |
| 1 | Review | Slipping — needs attention |
| 2 | Apprentice | First unlocked OR dropped from higher |
| 3 | Guru | Building consistency |
| 4 | Master | Strong knowledge |
| 5 | Enlightened | Fully cemented |

Items start at their current study level. Getting an answer wrong drops by 1 (min 1). Getting it right raises by 1 (max 5). New items unlock at level 2 on first correct answer.

## Files
- `index.html` — The app
- `data.json` — All study data (updated as new items are learned)
- `README.md` — This file

## Usage
Open `index.html` in a browser, or host on GitHub Pages.
Progress is saved automatically to browser localStorage.

## Data Coverage
- 47 Prefectures
- 191 Stations (target: 300)
- 35 Difficult names, historical places and expressions

## Roadmap
- [ ] Stations: 200 → 300
- [ ] Top 1000 surnames
- [ ] Given names
- [ ] WaniKani API import (Phase 2)
