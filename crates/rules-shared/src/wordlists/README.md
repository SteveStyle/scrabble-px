# Two word lists, with different subjects

The bundled dictionaries contain slurs — `HONKY` and `WOP` are both in
`sowpods.txt`, so it predates the 2020 Collins purge. These two files are how
that is dealt with, and they exist as files rather than as edits to the
dictionaries so the change stays auditable, reviewable, and re-appliable if a
dictionary is ever re-sourced.

| | applies to | contains | effect |
| --- | --- | --- | --- |
| `denylist.txt` | everyone, human and bot | slurs and hate speech only | removed from the dictionaries — the word is not valid, and no engine can enumerate it |
| `greylist.txt` | engines only | profanities and vulgar slang | dictionaries unchanged; a person may play these, an engine never chooses one |

**The difference is the subject, not the severity.** A person choosing to play a
rude word is expressing themselves; a machine doing it reads as the game
insulting you. So humans keep the vocabulary they enjoy and the computer stays a
clean opponent.

**Keeping the denylist narrow is a requirement, not a compromise.** Widen it
towards "rude" generally and it starts refusing words with ordinary meanings —
`BITCH` is a female dog, `ASS` is a donkey — and a player blocked from a
legitimate high-scoring word gets angry at the game rather than reflecting on
their vocabulary. The narrow line is also the one that can be defended by
pointing at what the game's own governing bodies did in 2020, rather than at our
taste.

## Why this file is uncomfortable, and why it exists anyway

A list of slurs, in a public repository, is not a pleasant thing to commit. The
alternative is an unexplained deletion of several hundred lines from a
267,000-line word file, which is worse for review and worse for anybody later
asking what happened. Plain text, with this note beside it.

## Format

One word per line, uppercase. Blank lines and `#` comments are ignored.

**Matched exactly, never as a substring.** Filtering a word list for anything
*containing* a banned word removes `SCUNTHORPE`, `ASSASSIN` and `BASEMENT`. That
is the classic way this goes wrong, it goes wrong silently, and it is guarded by
a test.

Words are normalised — trimmed and uppercased — on both sides before comparing,
so an entry's case here does not matter.

## Filling these in

Both files are empty. The mechanism is built and tested; the contents are
deliberately not invented, because a list assembled from memory would be both
wrong and unaccountable.

**`rustrict` is the most promising generator.** It is a Rust crate that
classifies a word by *type* (offensive, profane, sexual, mean) and *severity*
(mild, moderate, severe) — which is the two-tier split already, from somebody
else's judgement rather than ours:

- denylist ≈ `Type::OFFENSIVE` at `Level::Severe` — slurs and hate speech
- greylist ≈ anything `Censor::from_str(word).is_clean()` rejects

Generate both by running every word in each dictionary through it and keeping
the matches, then **commit the result as plain text**. That keeps the
auditability these files exist for while the judgement comes from a maintained,
published source. Record the crate version here when you do — a regenerated list
that silently differs is worse than no list.

Two cautions if you take that route. Its matching is deliberately
evasion-resistant (leetspeak, padding), which is the opposite of what a word
list wants: check what it does to `SCUNTHORPE`, `ASSASSIN` and `BASEMENT`
before trusting the output. And its line is not Collins' line, so the denylist
would no longer be defensible by pointing at the governing bodies — which was
the original argument for the narrow scope.

Alternatives, if it does not suit:

- **`denylist.txt`** — the 2020 Collins/NASPA removals. Those bodies drew this
  line already, at slurs rather than at profanity, and adopting their line beats
  inventing one.
- **`greylist.txt`** — LDNOOBW ("the big list of naughty words") is open source
  and categorised by language and severity, so the profanity tier can be taken
  without the slur tier. Expect to trim it: its entries include phrases and
  variants, and only single words playable on a board matter. Trimming *down* is
  safe here in a way it would not be for a validity list.

Record where a list came from, in this file, when it is filled in. A word list
with no provenance is a word list nobody can argue with later.

## Say "not a word", never "that word is offensive"

A player told their word was *banned* has learned where the boundary is and can
probe it; a player told it is not in the dictionary has learned nothing and
moves on. This falls out of the design rather than needing care: denylisted
words are removed from the dictionaries, so they fail the ordinary
not-in-the-dictionary path and produce the message every other invalid word
produces. Nothing anywhere should special-case them to say more.

## Not English

German (590k words) and Spanish (635k) are out of scope for a first pass, and
saying so explicitly beats leaving them looking done. The shape differs: the
German denylist tier is dominated by historical, political and xenophobic slurs
and is legally regulated there in a way it is not in English; the Spanish tier
targets nationality, race and sexual orientation, and its greylist varies so
much by region that a single global list will be wrong at the edges whatever it
contains.

Neither can be reviewed by somebody who does not speak the language, which is
the real blocker rather than the sourcing.
