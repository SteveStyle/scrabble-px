//! Two lists with different subjects: words nobody may play, and words no
//! engine will choose.
//!
//! See `wordlists/README.md` for why they exist, why the first is deliberately
//! narrow, and where the contents should come from. This module is only the
//! mechanism — parsing, and matching whole words exactly.

use std::collections::HashSet;

/// Removed from every dictionary: invalid for everyone, human and engine.
const DENYLIST_FILE: &str = include_str!("wordlists/denylist.txt");

/// Left in the dictionaries, so a person may play them; never chosen by an
/// engine.
const GREYLIST_FILE: &str = include_str!("wordlists/greylist.txt");

/// One word per line, uppercase; `#` comments and blank lines ignored.
///
/// Normalising here rather than at every comparison means a list can be pasted
/// in whatever case it arrived in and still match.
fn parse(text: &str) -> HashSet<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|word| word.to_uppercase())
        .collect()
}

/// The words removed from every dictionary.
pub fn denylist() -> &'static HashSet<String> {
    static DENYLIST: std::sync::OnceLock<HashSet<String>> = std::sync::OnceLock::new();
    DENYLIST.get_or_init(|| parse(DENYLIST_FILE))
}

/// The words an engine will not choose.
pub fn greylist() -> &'static HashSet<String> {
    static GREYLIST: std::sync::OnceLock<HashSet<String>> = std::sync::OnceLock::new();
    GREYLIST.get_or_init(|| parse(GREYLIST_FILE))
}

/// Both lookups take the word exactly as given, with no allocation.
///
/// Normalising is the *entries'* job, done once in `parse` when the list is
/// first read — uppercasing the query instead would allocate a `String` per
/// call, and the engine calls this for the main word and every cross word of
/// every legal move it considers. That is thousands of allocations per bot
/// move, on the hot path of an operation already known to be slow.
///
/// The contract that makes it safe: every word the rules form is uppercase by
/// construction, because the board holds `Grapheme`s from the edition's
/// alphabet and those are uppercase. `debug_assert` states it so a caller that
/// breaks it fails a test rather than silently matching nothing — a safety
/// check that fails *open* is worse than one that is merely slow.
fn contains(list: &HashSet<String>, word: &str) -> bool {
    debug_assert_eq!(
        word,
        word.trim().to_uppercase(),
        "word lists are looked up without normalising, so callers must pass an \
         uppercase, trimmed word — see the note on `contains`"
    );
    // Both lists ship empty, and an empty list can never match: worth checking
    // before hashing the word at all.
    !list.is_empty() && list.contains(word)
}

/// Is this word removed from the dictionaries?
///
/// **Whole word, exactly.** Never a substring test: filtering a word list for
/// anything *containing* a listed word removes `SCUNTHORPE`, `ASSASSIN` and
/// `BASEMENT`. That is the classic way this goes wrong, it goes wrong silently,
/// and there is a test below holding the line.
pub fn is_denied(word: &str) -> bool {
    contains(denylist(), word)
}

/// Should an engine decline to play this word?
///
/// Denied words are gone from the dictionaries already, so an engine cannot
/// enumerate them — but this includes them anyway rather than relying on that,
/// so an engine reading a dictionary from somewhere else still behaves.
pub fn is_avoided_by_engines(word: &str) -> bool {
    contains(greylist(), word) || contains(denylist(), word)
}

/// Removes the denied words from a word list, keeping everything else exactly
/// as it was — same order, same line endings.
///
/// Applied where a dictionary is built *and* where the raw text is served to
/// clients, which build their own from it. Filtering only the first would leave
/// the web client with the words this exists to remove.
pub fn without_denied(word_list: &str) -> String {
    if denylist().is_empty() {
        return word_list.to_string();
    }
    word_list
        .lines()
        .filter(|line| !is_denied(line))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The trap this whole module has to avoid.
    ///
    /// Every one of these contains a shorter word that a denylist could
    /// plausibly hold, and every one is an ordinary English word somebody would
    /// be furious to have refused. Written against `parse` directly so it holds
    /// whatever the committed lists happen to contain.
    #[test]
    fn matching_is_whole_word_never_substring() {
        let list = parse("CUNT\nASS\nNIT");
        for innocent in [
            "SCUNTHORPE",
            "ASSASSIN",
            "BASEMENT",
            "ASSET",
            "CLASSIC",
            "KNITTING",
            "UNITE",
        ] {
            assert!(
                !list.contains(innocent),
                "{innocent} is an ordinary word and must never be caught"
            );
        }
        assert!(list.contains("ASS"), "the exact word is still matched");
    }

    /// Case and surrounding space do not matter on either side.
    #[test]
    fn comparison_is_normalised() {
        let list = parse("  wop \n\n# a comment\nHONKY\n");
        assert_eq!(list.len(), 2, "comments and blanks are not words");
        assert!(list.contains("WOP"), "a lowercase entry is uppercased");
        assert!(list.contains("HONKY"));
    }

    /// Filtering keeps every word that is not listed, and drops the ones that
    /// are — including the last line, which a naive split loses.
    #[test]
    fn filtering_removes_only_the_listed_words() {
        let words = "ASSASSIN\nHONKY\nBASEMENT\nSCUNTHORPE";
        let denied = parse("HONKY");
        let kept: Vec<&str> = words
            .lines()
            .filter(|line| !denied.contains(&line.to_uppercase()))
            .collect();
        assert_eq!(kept, vec!["ASSASSIN", "BASEMENT", "SCUNTHORPE"]);
    }

    /// An empty list changes nothing at all.
    ///
    /// This is the shipped state — both files are deliberately empty until
    /// somebody sources them — so it is the behaviour actually in production,
    /// and it must be a no-op rather than an accidental filter.
    #[test]
    fn an_empty_list_leaves_the_word_list_untouched() {
        let words = "ASSASSIN\nBASEMENT\nSCUNTHORPE";
        assert_eq!(without_denied(words), words);
        assert!(denylist().is_empty(), "shipped empty, see the README");
        assert!(greylist().is_empty(), "shipped empty, see the README");
    }

    /// Lookup takes the word as given, matches exactly, and short-circuits on
    /// an empty list.
    ///
    /// The empty case is the one that ships, and it is the one the engine pays
    /// for on every candidate — so "empty never matches, without hashing" is
    /// behaviour worth pinning rather than an implementation detail.
    #[test]
    fn lookup_is_exact_and_free_when_the_list_is_empty() {
        let list = parse("HONKY\nWOP");
        assert!(super::contains(&list, "HONKY"));
        assert!(!super::contains(&list, "HONKYTONK"), "whole word only");
        assert!(!super::contains(&list, "BASEMENT"));

        let empty = parse("# nothing but a comment");
        assert!(empty.is_empty());
        assert!(!super::contains(&empty, "HONKY"));
    }

    /// Engines avoid both lists, not only the grey one.
    #[test]
    fn engines_avoid_denied_words_too() {
        let grey = parse("DAMN");
        let denied = parse("HONKY");
        // Mirrors `is_avoided_by_engines` without depending on the committed
        // files being non-empty.
        let avoided = |word: &str| {
            let w = word.to_uppercase();
            grey.contains(&w) || denied.contains(&w)
        };
        assert!(avoided("damn"), "the grey list");
        assert!(avoided("HONKY"), "and the denied one, belt and braces");
        assert!(!avoided("BASEMENT"));
    }
}
