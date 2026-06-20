# 日本語辞典 — Japanese Study App

A personal Japanese study tool built for serious learners. Covers kanji, vocabulary, proper nouns and writing practice with spaced repetition, stroke order animation and a fully offline-capable dictionary.

Built by Hayden — WaniKani level 60 graduate, moving to Osaka.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Single-file `index.html` — HTML, CSS, vanilla JS |
| Auth | Supabase email/password |
| Database | Supabase Postgres |
| Storage | Supabase Storage (`study-data` bucket) |
| Hosting | GitHub Pages (`haydenmquaill/japanese-study`, main branch) |
| IME | WanaKana.js (romaji → kana conversion) |
| Stroke data | KanjiVG (pre-processed, hosted in Supabase Storage) |

---

## Files

| File | Location | Description |
|---|---|---|
| `index.html` | GitHub Pages | The entire app |
| `data.json` | Supabase Storage | All study data (~15MB, 32,389 items) |
| `kanjivg.json` | Supabase Storage | Stroke order data for 3,376 kanji (~3MB) |

---

## Data

### Total Items — 32,389

#### Kanji

| Category | Count | Batches | Source |
|---|---|---|---|
| Joyo | 2,136 | 11 × 200 | Kanshudo |
| Jinmeiyo | 862 | 5 × 200 | Kanshudo |
| Kanji Extended | 490 | 3 × 200 | Manual / JMdict |

#### Vocabulary — 26,048 items

Sourced from JMdict (common word flag). Subcategories:

- Nouns (incl. Noun/Suru Verb)
- Verbs (Godan, Ichidan, Irregular, Suru)
- Adjectives (い, な, の, たる)
- Adverbs
- Expressions
- Particles & Grammar
- Onomatopoeia
- Other

Each vocab item has a `pos` (part of speech) tag from JMdict for fine-grained filtering.

#### Proper Nouns

| Category | Count |
|---|---|
| Surname | 1,066 |
| Given Name | 1,009 (M: 453, F: 481, U: 75) |
| Station | 373 |
| Prefecture | 47 |
| City | 50 |
| Town | 78 |
| Landmark | 100 |
| Historical | 29 |
| Idiom | 99 |
| Poetic | 2 |

---

## Item Structure

### Kanji (Joyo / Jinmeiyo / Kanji Extended)

```json
{
  "id": "joyo_0001",
  "kanji": "人",
  "readings": { "on": ["じん", "にん"], "kun": ["ひと"] },
  "meanings": ["person"],
  "category": "Joyo",
  "subcategory": "Joyo 1-200",
  "tags": ["Kanji"],
  "level": 0
}
```

### Vocabulary

```json
{
  "id": "jmd_00001",
  "kanji": "食べる",
  "reading": "たべる",
  "meaning": "to eat",
  "meanings": ["to eat", "to live on"],
  "category": "Vocab",
  "subcategory": "Verbs",
  "pos": "Ichidan Verb",
  "tags": ["Food & Drink"],
  "level": 0
}
```

### Proper Nouns

```json
{
  "id": "sur_001",
  "kanji": "田中",
  "reading": "たなか",
  "meaning": "Tanaka",
  "meanings": ["Tanaka"],
  "category": "Surname",
  "subcategory": "Common",
  "level": 0
}
```

---

## Database Schema

```sql
-- Reading progress
progress (user_id, item_id, level, last_quizzed, updated_at)

-- Writing progress (separate from reading)
write_progress (user_id, item_id, level, last_quizzed, updated_at)

-- User synonyms
synonyms (user_id, item_id, synonym)

-- Notes and descriptions
notes (user_id, item_id, description, notes, updated_at)

-- Settings and streak
user_settings (user_id, streak, last_study_date, unlocked_levels jsonb)
```

### Key Functions

```sql
upsert_progress(p_user_id, p_item_id, p_level, p_last_quizzed)
upsert_write_progress(p_user_id, p_item_id, p_level, p_last_quizzed)
upsert_note(p_user_id, p_item_id, p_description, p_notes)
upsert_user_settings(p_user_id, p_streak, p_last_study_date, p_unlocked_levels)
```

---

## Reading Levels

| Level | Name | Description |
|---|---|---|
| 0 | Locked | Not yet studied |
| 1 | Review | Needs attention |
| 2 | Apprentice | Early stage |
| 3 | Guru | Building consistency |
| 4 | Master | Strong knowledge |
| 5 | Enlightened | Fully cemented |

**Review grading:** ✕ drops 1 level (min 1) · △ stays · ○ raises 1 level (max 5)

**Study grading:** Items unlock at level 2 on correct first attempt, level 1 if wrong at any point

---

## Writing Levels

| Level | Name | Description |
|---|---|---|
| 0 | Unwritten | Not yet practised |
| 1 | Needs practice | Missed in review round |
| 2 | Shaky | Recalled with effort |
| 3 | Confident | Recalled correctly first try |
| 4 | Strong | Consistently correct |
| 5 | Mastered | Fully cemented |

**Study round grading:** ✕ → level 1 · △ → level 2 · ○ → level 3

**Review grading:** ✕ drops 1 (min 1) · △ stays · ○ raises 1 (max 5)

---

## Unlock Logic

### Kanji
Three independent chains: Joyo, Jinmeiyo, Kanji Extended.
- Batch 1 of each always accessible
- Next batch unlocks when any item in the current batch is studied (level > 0)
- Stored as strings in `unlocked_levels` jsonb: `["Joyo:2", "Jinmeiyo:2", ...]`

### Vocabulary
Unlocks when any component kanji (across any kanji category) has been studied.

---

## Navigation

Four tabs: **Home · Dict · Read · Write** (Settings via top-right dropdown)

### Home (Dashboard)

**Reading Progress**
- Stats: streak, needs review, mastered
- Level bars across all items
- Weak Items tile → Read tab, review mode, level 1 filter
- Stale Items tile → Read tab, review mode, stale filter

**Writing Progress**
- Level breakdown per kanji category (Joyo / Jinmeiyo / Kanji Extended)
- Level bars for writing levels
- Weak Writers tile → Write tab, review mode, level 1 filter
- Stale Writing tile → Write tab, review mode, stale filter

Stale = levels 2-4 not reviewed in 14+ days, level 5 not reviewed in 60+ days

---

### Dictionary

Browse and search all 32,389 items. Filters:
- Category → Subcategory → Part of Speech (Vocab only) → Tag (Vocab only) → Level

Kanji items show stroke order diagram in the modal with animated playback (Stop/Play loop toggle, Fast/Slow speed toggle).

---

### Read Tab

Two modes toggled at the top: **Review** and **Study**. Mode persists when switching tabs.

**Review mode config:**
- Category · Subcategory · Min Level · Max Level · Last Reviewed · Items

Last Reviewed options: Anytime · Stale · Recently reviewed (Today/3/7/14/30 days) · Not reviewed recently (7/14/30/60 days · Never)

**Study mode config:**
- Category · Subcategory · Items

Study flow: learning phase (full card) → review round (typed answer) → results

Results show: score %, per-item breakdown with new level and ○/△/✕ icon.

Again pulls fresh items from same config (disabled with message if pool empty). Config returns to config panel.

---

### Write Tab

Writing practice alongside physical whiteboard + grid book.

Two modes toggled at the top: **Review** and **Study**. Mode persists when switching tabs.
Session state is preserved when switching to other tabs and returning.

**Review mode config:**
- Category · Subcategory · Min Level · Max Level · Last Reviewed · Items

**Study mode config:**
- Category · Subcategory · Items (select: 5/10/20)

**Study flow:**
1. Learning phase — full card: kanji large, readings, meanings, stroke order animation (slow speed, looping)
2. Review round — meaning + reading shown → tap Reveal → full card with stroke order → self-grade
3. Results screen

**Review flow:**
- Meaning + reading shown → tap Reveal → full card with stroke order → self-grade → results

Grade buttons: ✕ red · △ orange · ○ green

Results show per-item breakdown with new write level and icon. Again reshuffles same pool (disabled with message if pool empty). Config returns to config panel.

---

## Stroke Order

- Source: KanjiVG, pre-processed to JSON and hosted in Supabase Storage
- Coverage: 3,376 of 3,488 kanji (96.8%)
- Loaded once at app init, cached in memory for the session
- Shown in dictionary modal for all kanji items (Fast/Slow + Stop/Play toggles)
- Shown in Write tab learn and reveal phases (always slow speed, Stop/Play toggle only)

---

## Users

| User | ID | Notes |
|---|---|---|
| Hayden | `c75fe6d1-b3ea-489a-963b-64885eddde43` | WK60, all Joyo unlocked, all Joyo at reading level 3 |
| Brother | — | Starts from scratch |

---

## Key SQL Migrations

| File | Purpose |
|---|---|
| `migration_write_progress.sql` | Creates `write_progress` table with RLS, indexes and upsert function |
| `migration_reset_progress.sql` | Resets reading progress for old WaniKani item IDs |

### Useful one-liners

```sql
-- Reset Hayden's writing progress
DELETE FROM write_progress
WHERE user_id = 'c75fe6d1-b3ea-489a-963b-64885eddde43';

-- Reset all writing progress (all users)
DELETE FROM write_progress;

-- Set all Joyo to read level 3 for Hayden (see migration file for full ID list)
-- Use migration_reset_progress.sql

-- Check write progress breakdown for Hayden
SELECT level, COUNT(*) FROM write_progress
WHERE user_id = 'c75fe6d1-b3ea-489a-963b-64885eddde43'
GROUP BY level ORDER BY level;
```

---

## Version History

| Version | Notes |
|---|---|
| 1.x | Initial build — prefectures, stations, surnames |
| 5.x | Supabase migration, full quiz engine |
| 10.x | WaniKani kanji + kanshudo vocab import |
| 12.0 | JMdict vocab rebuild (22,490 common words) |
| 12.5 | Kanji Extended readings completed |
| 12.7 | Tagging system, fixed animal/bird/fish tags |
| 12.8 | 15 missing place-name kanji added |
| current | Write tab, stroke order, Read/Write tab consolidation, consistent UI |
