---
# status: one of proposed | accepted | deprecated | superseded (enum enforced by /sdd:status)
status: proposed
date: 2026-10-23
decision-makers: [Jon Stump]
extends: [ADR-0006]
related: [ADR-0001, ADR-0005, ADR-0004]
---

# ADR-0026: RomM as a lookup source for scraping unlinked games

## Context and Problem Statement

ADR-0006 made every scrape action try RomM first, but only "when the game is linked": the RomM step resolved the game's `app_romm_rom_map` row and answered "not linked" without a request when there was none. Testing the result on a device showed the rule is close to empty.

Linking already does the work. Confirming a link in the picker or the RomM browser fills the game's metadata, a download replaces it, and any link starts save sync. So a linked game is already handled before anyone scrapes it. The games a user actually scrapes are the ones they copied over by hand and never linked, and for those the step did nothing: it logged "not linked" and ScreenScraper took every game, even when RomM had it under the same name.

The user's expectation, stated plainly, is that RomM should work as a metadata source the way ScreenScraper does: look the game up. A game does not need to be linked to RomM to be scraped from it. Linking, and a tool that auto-links, is a separate feature and stays out of the scrape.

A second finding: the bulk run's workers are sized by the ScreenScraper account's `maxthreads` (often 1), and the RomM step ran on those same workers, so RomM games were also processed one at a time even though the shared network gate allows three requests in flight.

## Decision Drivers

* RomM must be useful for games that are *not* linked; that is the case the feature exists for.
* No link may be required, and none is written by a scrape: linking stays its own feature with its own triggers.
* A wrong match is worse than no match. A mismatch would put another game's description and artwork on a ROM, so only an unambiguous match is accepted and everything else falls through to ScreenScraper.
* The matching rule stays in one place (`RommLocalMatcher`); a second, different idea of "the same game" must not appear.
* The load on the user's RomM server stays bounded: the shared gate, the server guard, and the early abort from ADR-0006's follow-up all keep applying, and the lookup's own requests count toward them.
* ScreenScraper's thread count must not cap RomM, and RomM must not raise ScreenScraper's.

## Considered Options

* Look unlinked games up in a per-system RomM catalog index (bulk) or by RomM search (single game), match unambiguously, and write the metadata without writing a link
* Run the library-wide link pass before every scrape, so every matchable game is linked and the existing step finds it
* Keep the step linked-only

## Decision Outcome

Chosen option: "Look unlinked games up in a per-system RomM catalog index (bulk) or by RomM search (single game), match unambiguously, and write the metadata without writing a link", because it is the only option that makes RomM useful for the games a user scrapes, it needs no link, and it reuses the writer, the matcher and the network gate that already exist. Concretely:

1. **The step resolves in two tiers.** A game with a link row is handled exactly as before (the link index is read once per bulk run). A game without one is looked up in RomM; a lookup miss or an ambiguous lookup is a "not found" result and falls through to ScreenScraper.
2. **Matching, in order, unique matches only.** (a) The game's file name equals one of a RomM ROM's `RommLocalMatcher.candidateNames` under `RommLocalMatcher.normalizeName`. (b) Otherwise the game's normalized title equals the normalized title of exactly one RomM ROM on the same system, where the title drops the extension and any parenthesised or bracketed tags, folds case, diacritics, `&`/"and" and a trailing ", The", and treats other punctuation as a space. Two or more candidates at either tier is "ambiguous" and counts as no match. Hash matching is a later change; it needs hash fields from RomM's list and local fingerprints and exists only on the fork today.
3. **Bulk uses one catalog walk per system.** The first game of a system loads every ROM of the RomM platforms that map to it (the same paged walk and page size the link pass uses), builds the index once, and every worker shares it; a failed walk is remembered for the run and not retried. Page requests go through the shared network gate and are counted.
4. **A single game uses RomM search.** One `search_term` request scoped to the system's platforms, matched in memory by the same rule.
5. **No link is written.** The matched ROM's metadata is written through the ADR-0005 writer keyed by the local file name, with provenance `romm`. `app_romm_rom_map` is untouched.
6. **The server guard and the early abort apply unchanged.** A failed catalog page or search is transport-class like a failed detail request: it counts toward the guard's streak, a rate limit pauses, and a RomM-only run still stops with the "server could not be reached" error.
7. **RomM's concurrency is the shared gate's, not ScreenScraper's.** Workers still come from ScreenScraper's thread setting, but every RomM request, detail, media and catalog page alike, is bounded by the gate (3), and a RomM-only run is no longer sized by an account setting it does not use. (Running the RomM work as its own phase ahead of ScreenScraper is a follow-up.)

This replaces ADR-0006's "when the game is linked" with "when RomM can supply the game", and its "not linked → no request" with "not linked → look it up".

### Consequences

* Good, because games copied over by hand, the case the scrape exists for, can now be scraped from RomM.
* Good, because nothing links, so the scrape has no side effect on save sync or the library link state.
* Good, because the matcher, writer, gate, guard and abort are all reused; the new code is the index, the catalog walk, and the lookup tier in the step.
* Bad, because a bulk run costs a catalog walk per system (a few requests of 500 for a typical platform) before it fetches anything, and a single-game scrape costs one extra search request.
* Bad, because title matching can miss games whose RomM name differs (alternate titles, translations) and refuses games with several regional variants; those fall to ScreenScraper, which is the safe direction.
* Neutral, because linked games are unchanged, and hash matching and an optional "remember this match as a link" are open follow-ups.

### Confirmation

* Pure tests of the matcher: exact file name, title fallback, case, tags, "&", ", The", unicode folding, ambiguous at each tier, a different system, empty titles.
* Lookup tests with a scripted RomM: one catalog walk per system however many workers ask; a failed walk remembered and classified as transport; pages counted and held to the gate.
* Step and bulk tests: an unlinked game matched by name is scraped from RomM with `app_romm_rom_map` unchanged; an ambiguous or missing game falls through; linked games take the old path; failures and 429s reach the guard; a RomM-only dead server aborts.
* Mutation table for every one of those behaviours.

## Pros and Cons of the Options

### Look unlinked games up (chosen)

* Good, because it answers the actual use case and writes no link.
* Bad, because it adds a matching path that can be wrong, which the unique-match rule and the fall-through to ScreenScraper contain.

### Run the link pass before every scrape

* Good, because it adds no matching code.
* Bad, because it makes every scrape a link operation: it writes `app_romm_rom_map`, starts save sync for every matched game, and is filename-only, so it still misses titles that differ.
* Bad, because it is the feature the user said is out of scope for a scrape.

### Keep the step linked-only

* Good, because it is what is built.
* Bad, because a linked game already has its metadata, so the step re-fetches what is there and does nothing for unlinked games.

## More Information

* Amends ADR-0006 (its linked-only rule); SPEC-0006 is updated alongside. Extends ADR-0005's writer and the shared `RommMetadataNetwork` gate.
* Key code: `lib/utils/romm_local_matcher.dart`, `lib/services/romm/romm_server_guard.dart`, `lib/providers/romm_provider.dart` (`scrapeStep`, `bulkScrapeStep`, `platformIdsForSystemName`), `lib/services/romm_service.dart` (`getRomsPage`).
* This fork does not open upstream pull requests; the maintainer opens them by hand.
