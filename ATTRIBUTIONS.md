# Attributions

Third-party data bundled into this repository, and where it came from.

The project's own code is dual-licensed under [MIT](LICENSE-MIT) and
[Apache 2.0](LICENSE-APACHE). Nothing below is the project's own work.

## Word lists

Each edition compiles its word list straight into the binary from
`crates/rules-shared/src/`, and the server serves it verbatim at
`GET /dictionaries/{name}`. All four were normalised on import to one
uppercase word per line, at most 15 letters, restricted to that edition's
alphabet — so none of them is byte-identical to its upstream file.

### `enable2k.txt` — 169,266 words

- **Upstream:** <https://github.com/BartMassey/wordlists> (`enable2k.txt.gz`)
- **Licence:** ENABLE2K was placed in the public domain by its creators; the
  hosting repository is MIT. See `README-enable2k.txt` upstream for the
  original distribution's own statement.
- **Notes:** ENABLE ("Enhanced North American Benchmark LExicon"), compiled
  by Alan Beale, used here in place of the North American tournament list
  (TWL/NWL), which is copyright Merriam-Webster/Hasbro and not freely
  redistributable. Imported at 173,528 words.

### `german.txt` — 590,511 words

- **Upstream:** <https://github.com/enz/german-wordlist> (the `words` file)
- **Licence:** CC0 (public domain dedication)
- **Notes:** Built for word games, so proper nouns, abbreviations and
  archaic spellings are already excluded. Uppercased with ß → SS, since
  German Scrabble sets have no ß tile and such words are physically played
  as two S tiles. Loanwords using letters outside the German Scrabble
  alphabet (é, ç, å, …) were dropped. Imported at 675,522 words.

### `spanish.txt` — 635,090 words

- **Upstream:** <https://github.com/words/an-array-of-spanish-words>
  (`index.json`)
- **Licence:** MIT
- **Notes:** The upstream README states the list is derived from the
  Letterpress word list; that further derivation has not been verified
  here. Filtered to `A–Z` plus `Ñ`. Imported at roughly 636,000 words.

### `sowpods.txt` — 267,753 words

- **Upstream:** unrecorded
- **Licence:** unrecorded
- **Notes:** This file predates the rest of the project. It arrived with the
  original `scrabble` crate (commit `6be7eb6`, 19 September 2025) and has
  been carried forward byte-identically ever since; no record survives of
  where it was obtained. SOWPODS is the informal name for the international
  tournament word list, which in its current form is published as Collins
  Scrabble Words and is copyright HarperCollins. Widely-mirrored copies
  circulate freely, but that is not a licence, and this one's provenance
  cannot be established. Replacing it with a list of known origin is an
  open question, not a settled decision.

## Rules and board

The premium-square layout (`house_premiums()` in
`crates/rules-shared/src/model.rs`) is the project's own design, not any
existing game's board.

Letter values and tile distributions for the `official`, `north_american`
and `german` editions are the standard published sets for those games;
`spanish` follows the traditional Castilian set including its CH/LL/RR
digraph tiles. These are functional game data rather than creative work.

Scrabble is a trademark of Hasbro in the United States and Canada and of
Mattel elsewhere. This project is not affiliated with, endorsed by, or
derived from either.
