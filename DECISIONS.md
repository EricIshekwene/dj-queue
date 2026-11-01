# DJ Queue — Decisions

Round 1 decision page: `DECISIONS.html` (https://claude.ai/artifact/Sj9c4h8pr2NueCRiB8g21K). Answered 2026-11-01.

Raw answer line: `1A 2A 3A 4A 5A 6A 7A 8B 9A 10A 11B 12C 13B 14B 15A 16A 17A 18A 19A 20A 21A 22A 23A 24A 25A 26A 27A 28A`

## Binding answers

| # | Question | Answer |
|---|---|---|
| 1 | Platforms at launch | All six (TikTok, Instagram, Facebook, YouTube Shorts, Threads, X) |
| 2 | Post times | Spread: FB 12:30, Threads 1:30, YT 3:00, X 5:00, IG 6:00, TikTok 7:00 pm (NY) |
| 3 | Post before slot (manual) | Yes, any time that day |
| 4 | Posting from | Mac browser (drag file + caption copied are primary) |
| 5 | Week / reminder | Mon–Sun, reminder Sunday 6 pm |
| 6 | Runway alerts | Approve < 3 days, record-a-set < 14 days |
| 7 | Notifications | One per slot; silent if already posted |
| 8 | Posted renders | **Keep forever** (cleanup policy setting defaults to keep) |
| 9 | Kinds | **Only two kinds: `dj vid` and `talking`** (replaces transition/talking/medley/other). Default `dj vid`; all existing clips start as `dj vid` |
| 10 | Scoring | Score mode (big player, type number, Enter → next unscored) |
| 11 | Text style | White box, black text. Text must be **draggable** on the preview |
| 12 | Text position | **Centre** by default, draggable |
| 13 | Text size | Medium |
| 14 | Prefill | From the tag, tidied: **use "x", never an arrow; no emoji by default**. Short names → one line `Yayo x Johnny`; long names → three lines `Song One` / `x` / `Song Two`. Prefill rules must be readable/inspectable by agents (documented config + CLI preview) |
| 15 | Caption | Template A with "x" not arrows. Provide **several caption template presets** (different text styles) and **auto-generated hashtags per video** from the hashtag sets |
| 16 | Hashtags | The three sets (Amapiano, Afrobeats, DJ) are **primary categories**; many more sets can sit under each. Eric will supply more later |
| 17 | YouTube title | `{text} \| DJ Lovd` |
| 18 | Text on cover | Yes |
| 19 | Safe zones | On while editing text |
| 20 | Navigation | Sidebar |
| 21 | Queue | Ordered list + inspector |
| 22 | Week | Calendar grid |
| 23 | Editor | Full window |
| 24 | Inspector | Right |
| 25 | Menu-bar number | Approved days left |
| 26 | Colour | Follow the Mac accent colour |
| 27 | Build | Start with Command Line Tools (SwiftPM); Eric is installing Xcode after an OS update — keep the project openable in Xcode (Package.swift) |
| 28 | Menu bar at login | Yes |

## Next

Milestone 2: data model, intake of Afroween (62 short + 1 long), Library, scoring.
Open item for milestone 6: Doctor skill location (`~/.claude/skills` per spec vs `~/.claude-technical/skills`) — ask Eric.
