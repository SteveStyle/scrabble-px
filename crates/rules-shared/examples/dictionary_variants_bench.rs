//! Dev-only: candidate dictionary storage layouts, measured head to head.
//!
//! Usage: `cargo run --release -p rules-shared --example dictionary_variants_bench`
//!
//! These live in an example rather than in the crate on purpose — they are
//! candidates, not decisions. Whichever wins can graduate into
//! `dictionary.rs`; the rest should leave no trace.
//!
//! The measured workload deliberately mirrors what production does:
//! `is_word` is what the wasm client calls, and the prefix walk is what
//! move generation leans on. Prior measurement showed this workload is
//! memory-bound rather than compute-bound — the same binary's prefix walk
//! is 6.6x slower on the 2-core deployment VM than on a laptop, while
//! `is_word` (a two-touch hash lookup) is not slower at all. So each
//! variant reports its resident footprint alongside its timings: a layout
//! that trades bytes for instructions is usually winning here, and one
//! that trades the other way usually is not.
//!
//! Candidates
//! ----------
//! - **baseline** — today's `HashSet<&str>` + `Vec<Vec<char>>`.
//! - **slices** — `Vec<&'static str>`, no owned copies at all. Smallest
//!   possible storage, but the cursor has to reach the *n*th character of
//!   a UTF-8 string, which is a walk from the start rather than an index.
//!   Included precisely to find out how much that costs.
//! - **arena** — each word stored as `Letter` indices, one byte each, in a
//!   single contiguous allocation with an offset table. O(1) indexing by
//!   depth like the baseline, at a quarter of its bytes.
//! - **tiered** — `arena` plus a dense first-two-letters index, replacing
//!   the widest binary-search probes with array lookups.

use std::collections::HashSet;
use std::time::Instant;

use rules_shared::{
    Alphabet, Letter, VariantRules, enable2k_word_list, german_word_list, sowpods_word_list,
    spanish_word_list,
};

const CONSTRUCTION_RUNS: usize = 5;
const LOOKUP_SAMPLE: usize = 20_000;

/// What every candidate must provide. Deliberately narrower than the real
/// `Dictionary` trait: this is only what the benchmark exercises, so a
/// candidate can be written without committing to the full production
/// interface before it has earned it.
trait Candidate: Sized {
    const NAME: &'static str;
    fn build(text: &'static str, alphabet: &Alphabet) -> Self;
    /// Bytes held beyond the compiled-in text, which every variant shares
    /// and none of them pays for again.
    fn resident_bytes(&self) -> usize;

    /// Walks `word` one letter at a time from the root, returning how many
    /// steps succeeded — the same shape of work `expand_lane` does while
    /// extending a play, and the reason a prefix structure exists at all.
    fn walk(&self, letters: &[Letter], alphabet: &Alphabet) -> usize;
}

// ---------------------------------------------------------------------------
// baseline: HashSet<&str> + Vec<Vec<char>>
// ---------------------------------------------------------------------------

struct Baseline {
    words: HashSet<&'static str>,
    sorted: Vec<Vec<char>>,
}

impl Candidate for Baseline {
    const NAME: &'static str = "baseline";

    fn build(text: &'static str, _alphabet: &Alphabet) -> Self {
        let words: HashSet<&'static str> = text.split_whitespace().collect();
        let mut sorted: Vec<Vec<char>> = words.iter().map(|w| w.chars().collect()).collect();
        sorted.sort_unstable();
        Self { words, sorted }
    }

    fn resident_bytes(&self) -> usize {
        // Vec header per word, plus 4 bytes per char, plus the hash table's
        // fat pointers at hashbrown's ~87.5% load factor.
        let chars: usize = self.sorted.iter().map(|w| w.len()).sum();
        self.sorted.len() * std::mem::size_of::<Vec<char>>()
            + chars * 4
            + (self.words.len() * 17 * 8) / 7
    }

    fn walk(&self, letters: &[Letter], alphabet: &Alphabet) -> usize {
        let mut lo = 0usize;
        let mut hi = self.sorted.len();
        let mut depth = 0usize;
        for letter in letters {
            let Some(grapheme) = alphabet.to_grapheme(*letter) else {
                return depth;
            };
            for ch in grapheme.chars() {
                let slice = &self.sorted[lo..hi];
                let start = slice.partition_point(|w| w.get(depth).is_some_and(|c| *c < ch));
                let end = slice.partition_point(|w| w.get(depth).is_none_or(|c| *c <= ch));
                if start == end {
                    return depth;
                }
                lo += start;
                hi = lo + (end - start);
                depth += 1;
            }
        }
        depth
    }
}

// ---------------------------------------------------------------------------
// slices: Vec<&'static str>, nothing owned
// ---------------------------------------------------------------------------

struct Slices {
    sorted: Vec<&'static str>,
}

impl Candidate for Slices {
    const NAME: &'static str = "slices";

    fn build(text: &'static str, _alphabet: &Alphabet) -> Self {
        let mut sorted: Vec<&'static str> = text.split_whitespace().collect();
        sorted.sort_unstable();
        sorted.dedup();
        Self { sorted }
    }

    fn resident_bytes(&self) -> usize {
        self.sorted.len() * std::mem::size_of::<&str>()
    }

    fn walk(&self, letters: &[Letter], alphabet: &Alphabet) -> usize {
        let mut lo = 0usize;
        let mut hi = self.sorted.len();
        let mut depth = 0usize;
        for letter in letters {
            let Some(grapheme) = alphabet.to_grapheme(*letter) else {
                return depth;
            };
            for ch in grapheme.chars() {
                let slice = &self.sorted[lo..hi];
                // The cost this variant exists to measure: reaching the
                // depth-th *character* of a UTF-8 string is a walk from the
                // start, not an index, and it happens on every probe of
                // every binary search.
                let start = slice.partition_point(|w| w.chars().nth(depth).is_some_and(|c| c < ch));
                let end = slice.partition_point(|w| w.chars().nth(depth).is_none_or(|c| c <= ch));
                if start == end {
                    return depth;
                }
                lo += start;
                hi = lo + (end - start);
                depth += 1;
            }
        }
        depth
    }
}

// ---------------------------------------------------------------------------
// arena: one contiguous Box<[u8]> of Letter indices + offsets
// ---------------------------------------------------------------------------

struct Arena {
    /// Every word's letters, end to end. One byte per letter, because no
    /// alphabet here exceeds 29 graphemes.
    letters: Box<[u8]>,
    /// `word i` occupies `letters[offsets[i]..offsets[i + 1]]`, so this has
    /// one more entry than there are words.
    offsets: Box<[u32]>,
}

impl Arena {
    #[inline]
    fn word(&self, index: usize) -> &[u8] {
        let start = self.offsets[index] as usize;
        let end = self.offsets[index + 1] as usize;
        &self.letters[start..end]
    }

    fn len(&self) -> usize {
        self.offsets.len() - 1
    }
}

impl Candidate for Arena {
    const NAME: &'static str = "arena";

    fn build(text: &'static str, alphabet: &Alphabet) -> Self {
        // Encode first, then sort by the *letter* sequence — not by the
        // string. An alphabet's order is its own, and need not match code
        // point order: Spanish files Ñ between N and O (index 13), while
        // U+00D1 sorts after Z. Sorting by string and searching by letter
        // index would binary-search a differently-ordered array and quietly
        // miss words. German happens to agree with code points; Spanish
        // does not, which is exactly the kind of difference that only shows
        // up in one edition.
        let mut encoded: Vec<Vec<u8>> = text
            .split_whitespace()
            .map(|word| {
                word.chars()
                    .map(|ch| {
                        let mut buffer = [0u8; 4];
                        alphabet
                            .to_letter(ch.encode_utf8(&mut buffer))
                            .expect("word list should only contain alphabet graphemes")
                            .0
                    })
                    .collect()
            })
            .collect();
        encoded.sort_unstable();
        encoded.dedup();

        let mut letters: Vec<u8> = Vec::with_capacity(text.len());
        let mut offsets: Vec<u32> = Vec::with_capacity(encoded.len() + 1);
        offsets.push(0);
        for word in &encoded {
            letters.extend_from_slice(word);
            offsets.push(letters.len() as u32);
        }
        Self {
            letters: letters.into_boxed_slice(),
            offsets: offsets.into_boxed_slice(),
        }
    }

    fn resident_bytes(&self) -> usize {
        self.letters.len() + self.offsets.len() * 4
    }

    fn walk(&self, letters: &[Letter], _alphabet: &Alphabet) -> usize {
        let mut lo = 0usize;
        let mut hi = self.len();
        for (depth, letter) in letters.iter().enumerate() {
            let target = letter.0;
            // One byte per letter and O(1) indexing, so a probe touches a
            // single cache line rather than chasing a Vec header to its
            // separately-allocated char buffer.
            let start = partition_point(lo, hi, |i| {
                self.word(i).get(depth).is_some_and(|c| *c < target)
            });
            let end = partition_point(lo, hi, |i| {
                self.word(i).get(depth).is_none_or(|c| *c <= target)
            });
            if start == end {
                return depth;
            }
            lo = start;
            hi = end;
        }
        letters.len()
    }
}

/// `slice::partition_point` over an index range rather than a slice, so the
/// arena variants can probe without materialising sub-slices.
fn partition_point(mut lo: usize, mut hi: usize, pred: impl Fn(usize) -> bool) -> usize {
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if pred(mid) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

// ---------------------------------------------------------------------------
// tiered: arena + a dense index over the first two letters
// ---------------------------------------------------------------------------

/// `arena` plus a dense index over the first two letters, and a size
/// threshold below which the remaining search scans instead of bisecting.
///
/// `CUTOFF` is a const parameter so the sweep in `main` compares real
/// monomorphised code rather than a branch on a runtime field — the whole
/// question is what the compiler and the prefetcher do with each choice.
struct Tiered<const CUTOFF: usize> {
    arena: Arena,
    alphabet_len: usize,
    /// `[lo, hi)` into the arena for each first-two-letter pair, laid out
    /// densely so a lookup is arithmetic rather than a search. For a
    /// 26-letter alphabet this is 676 ranges — about 5KB, small enough to
    /// stay resident indefinitely, which is the entire point.
    pairs: Box<[(u32, u32)]>,
    /// Whether each two-letter prefix is itself a word. Two-letter words
    /// are the most-consulted entries on a board, and this answers them
    /// without touching the arena at all.
    pair_is_word: Box<[bool]>,
}

impl<const CUTOFF: usize> Tiered<CUTOFF> {
    /// Narrows `[lo, hi)` to the words whose letter at `depth` is `target`.
    /// Below `CUTOFF` entries this scans forward instead of bisecting:
    /// consecutive words sit adjacent in the arena, so a short scan is
    /// sequential and prefetchable where a binary search jumps.
    #[inline]
    fn narrow(&self, lo: usize, hi: usize, depth: usize, target: u8) -> (usize, usize) {
        // A word that ends before `depth` sorts *before* every word that
        // continues past it ("AB" precedes "ABC"), so "no letter here" has
        // to count as sorting before the target, not after. Treating it as
        // after stops the scan dead on the shorter word — which is what the
        // agreement check caught.
        if hi - lo <= CUTOFF {
            let mut start = lo;
            while start < hi
                && self
                    .arena
                    .word(start)
                    .get(depth)
                    .is_none_or(|c| *c < target)
            {
                start += 1;
            }
            let mut end = start;
            while end < hi && self.arena.word(end).get(depth) == Some(&target) {
                end += 1;
            }
            (start, end)
        } else {
            let start = partition_point(lo, hi, |i| {
                self.arena.word(i).get(depth).is_none_or(|c| *c < target)
            });
            let end = partition_point(start, hi, |i| {
                self.arena.word(i).get(depth).is_none_or(|c| *c <= target)
            });
            (start, end)
        }
    }

    /// Membership without the HashSet: the tier answers the first two
    /// letters, so what remains is a search over a few hundred entries
    /// rather than the whole list. That is a different question from the
    /// one measured earlier, where binary search over the full range lost
    /// badly to hashing.
    fn contains(&self, letters: &[u8]) -> bool {
        match letters.len() {
            0 => false,
            1 => {
                let (lo, hi) = (0, self.arena.len());
                let (s, e) = self.narrow(lo, hi, 0, letters[0]);
                (s..e).any(|i| self.arena.word(i).len() == 1)
            }
            _ => {
                let slot = letters[0] as usize * self.alphabet_len + letters[1] as usize;
                if letters.len() == 2 {
                    return self.pair_is_word[slot];
                }
                let (lo, hi) = self.pairs[slot];
                let (mut lo, mut hi) = (lo as usize, hi as usize);
                if lo == hi {
                    return false;
                }
                for (offset, target) in letters[2..].iter().enumerate() {
                    let (s, e) = self.narrow(lo, hi, offset + 2, *target);
                    if s == e {
                        return false;
                    }
                    lo = s;
                    hi = e;
                }
                (lo..hi).any(|i| self.arena.word(i).len() == letters.len())
            }
        }
    }
}

impl<const CUTOFF: usize> Candidate for Tiered<CUTOFF> {
    const NAME: &'static str = "tiered";

    fn build(text: &'static str, alphabet: &Alphabet) -> Self {
        let arena = Arena::build(text, alphabet);
        let n = alphabet.len();
        let mut pairs = vec![(0u32, 0u32); n * n];
        let mut pair_is_word = vec![false; n * n];
        for index in 0..arena.len() {
            let word = arena.word(index);
            if word.len() < 2 {
                continue;
            }
            let slot = word[0] as usize * n + word[1] as usize;
            if word.len() == 2 {
                pair_is_word[slot] = true;
            }
            let entry = &mut pairs[slot];
            if entry.0 == entry.1 {
                *entry = (index as u32, index as u32 + 1);
            } else {
                entry.1 = index as u32 + 1;
            }
        }
        Self {
            arena,
            alphabet_len: n,
            pairs: pairs.into_boxed_slice(),
            pair_is_word: pair_is_word.into_boxed_slice(),
        }
    }

    fn resident_bytes(&self) -> usize {
        self.arena.resident_bytes() + self.pairs.len() * 8 + self.pair_is_word.len()
    }

    fn walk(&self, letters: &[Letter], alphabet: &Alphabet) -> usize {
        if letters.len() < 2 {
            return self.arena.walk(letters, alphabet);
        }
        let slot = letters[0].0 as usize * self.alphabet_len + letters[1].0 as usize;
        let (lo, hi) = self.pairs[slot];
        if lo == hi {
            // The dense index answered outright: nothing starts with this
            // pair, and no search happened at all.
            return 0;
        }
        let (mut lo, mut hi) = (lo as usize, hi as usize);
        for (offset, letter) in letters[2..].iter().enumerate() {
            let depth = offset + 2;
            let (s, e) = self.narrow(lo, hi, depth, letter.0);
            if s == e {
                return depth;
            }
            lo = s;
            hi = e;
        }
        letters.len()
    }
}

// ---------------------------------------------------------------------------

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs"));
    values[values.len() / 2]
}

fn spread<'a>(words: &[&'a str], count: usize) -> Vec<&'a str> {
    if words.len() <= count {
        return words.to_vec();
    }
    let stride = words.len() / count;
    (0..count).map(|i| words[i * stride]).collect()
}

/// Builds one variant, checks it against the baseline's answers, and drops
/// it again — see the call site for why they are never all alive at once.
fn check<C: Candidate>(
    list: &str,
    text: &'static str,
    alphabet: &Alphabet,
    encoded: &[Vec<Letter>],
    expected: &[usize],
) {
    let built = C::build(text, alphabet);
    for (letters, want) in encoded.iter().zip(expected) {
        let got = built.walk(letters, alphabet);
        assert_eq!(
            got,
            *want,
            "{list}/{}: disagreed with baseline on a real word (walked {got} of {want} letters)",
            C::NAME
        );
    }
}

fn measure_labelled<C: Candidate>(
    label: &str,
    text: &'static str,
    alphabet: &Alphabet,
    encoded: &[Vec<Letter>],
) {
    let built = C::build(text, alphabet);
    let resident_mb = built.resident_bytes() as f64 / (1024.0 * 1024.0);
    let start = Instant::now();
    let mut steps = 0usize;
    for letters in encoded {
        steps += built.walk(letters, alphabet);
    }
    let walk_ns = start.elapsed().as_secs_f64() * 1e9 / steps.max(1) as f64;
    println!("  {label:<15} {resident_mb:>9.1} MB {walk_ns:>9.0} ns/step");
}

fn measure<C: Candidate>(text: &'static str, alphabet: &Alphabet, encoded: &[Vec<Letter>]) {
    let construct_ms = median(
        (0..CONSTRUCTION_RUNS)
            .map(|_| {
                let start = Instant::now();
                let built = C::build(text, alphabet);
                let elapsed = start.elapsed().as_secs_f64() * 1000.0;
                std::hint::black_box(built.resident_bytes());
                elapsed
            })
            .collect(),
    );

    let built = C::build(text, alphabet);
    let resident_mb = built.resident_bytes() as f64 / (1024.0 * 1024.0);

    let start = Instant::now();
    let mut steps = 0usize;
    for letters in encoded {
        steps += built.walk(letters, alphabet);
    }
    let walk_ns = start.elapsed().as_secs_f64() * 1e9 / steps.max(1) as f64;

    println!(
        "  {:<10} {construct_ms:>9.1} ms {resident_mb:>9.1} MB {walk_ns:>9.0} ns/step",
        C::NAME
    );
}

fn main() {
    for (name, text, rules) in [
        ("sowpods", sowpods_word_list(), VariantRules::official()),
        (
            "enable2k",
            enable2k_word_list(),
            VariantRules::north_american(),
        ),
        ("german", german_word_list(), VariantRules::german()),
        ("spanish", spanish_word_list(), VariantRules::spanish()),
    ] {
        let alphabet = &rules.alphabet;
        let all: Vec<&str> = text.split_whitespace().collect();
        // Words of <= 8 letters, matching the earlier bench, so walk costs
        // describe typical play rather than 15-letter outliers.
        let sample = spread(&all, LOOKUP_SAMPLE);
        let encoded: Vec<Vec<Letter>> = sample
            .iter()
            .filter(|w| w.chars().count() <= 8)
            .filter_map(|w| {
                w.chars()
                    .map(|ch| {
                        let mut buffer = [0u8; 4];
                        alphabet.to_letter(ch.encode_utf8(&mut buffer))
                    })
                    .collect::<Option<Vec<Letter>>>()
            })
            .collect();

        // Agreement check, before any timing. A benchmark will happily
        // report excellent numbers for a variant that returns wrong
        // answers: the first `arena` sorted by string while searching by
        // letter index, which is correct for every list whose alphabet
        // happens to follow code point order and silently wrong for
        // spanish, where Ñ is filed between N and O. Nothing in the
        // timings could have shown that. Every variant must reach the
        // same depth on the same word as the baseline does.
        //
        // Each variant is built, checked and dropped before the next is
        // built. Holding all four at once costs ~73MB for german, which on
        // the 954MB deployment VM perturbs the very thing being measured —
        // an earlier version of this check made a hash lookup there appear
        // to take 2738ns, fifteen times its real cost, purely from page
        // pressure the harness itself created.
        {
            let expected: Vec<usize> = {
                let baseline = Baseline::build(text, alphabet);
                encoded
                    .iter()
                    .map(|letters| {
                        let depth = baseline.walk(letters, alphabet);
                        assert_eq!(
                            depth,
                            letters.len(),
                            "{name}: a word from the list should walk to its full length"
                        );
                        depth
                    })
                    .collect()
            };
            check::<Slices>(name, text, alphabet, &encoded, &expected);
            check::<Arena>(name, text, alphabet, &encoded, &expected);
            check::<Tiered<0>>(name, text, alphabet, &encoded, &expected);
            check::<Tiered<16>>(name, text, alphabet, &encoded, &expected);
            check::<Tiered<64>>(name, text, alphabet, &encoded, &expected);
            check::<Tiered<256>>(name, text, alphabet, &encoded, &expected);
        }

        println!("{name} ({} words, {} walks)", all.len(), encoded.len());
        measure::<Baseline>(text, alphabet, &encoded);
        measure::<Slices>(text, alphabet, &encoded);
        measure::<Arena>(text, alphabet, &encoded);
        // Cutoff sweep. 0 is pure binary search; larger values scan a
        // wider tail. The crossover is a cache-behaviour question, so it
        // has to be found rather than reasoned about.
        measure_labelled::<Tiered<0>>("tiered/bsearch", text, alphabet, &encoded);
        measure_labelled::<Tiered<16>>("tiered/scan16", text, alphabet, &encoded);
        measure_labelled::<Tiered<64>>("tiered/scan64", text, alphabet, &encoded);
        measure_labelled::<Tiered<256>>("tiered/scan256", text, alphabet, &encoded);

        // Does the tier make the HashSet redundant? Earlier this lost
        // badly, but that measured binary search over the *whole* list;
        // with the first two letters answered by the tier, what is left is
        // a few hundred entries.
        {
            let tiered = Tiered::<64>::build(text, alphabet);
            let encoded_sample: Vec<Vec<u8>> = encoded
                .iter()
                .map(|w| w.iter().map(|l| l.0).collect())
                .collect();
            let start = Instant::now();
            let mut found = 0usize;
            for word in &encoded_sample {
                if tiered.contains(word) {
                    found += 1;
                }
            }
            let tier_ns = start.elapsed().as_secs_f64() * 1e9 / encoded_sample.len() as f64;
            assert_eq!(
                found,
                encoded_sample.len(),
                "{name}: tiered membership should find every real word"
            );
            println!("  is_word    tiered {tier_ns:>6.0} ns  (vs hash/bsearch below)");
        }

        // Settles the open question of whether the HashSet can simply be
        // dropped: a hash lookup is O(1) but touches the bucket and then
        // the string it points at, while a binary search is ~18 probes
        // scattered across the sorted array. Which wins is a memory
        // question, not a complexity one, so it has to be measured.
        let hashed: HashSet<&str> = all.iter().copied().collect();
        let mut sorted: Vec<&str> = all.clone();
        sorted.sort_unstable();
        let start = Instant::now();
        let mut hits = 0usize;
        for word in &sample {
            if hashed.contains(word) {
                hits += 1;
            }
        }
        let hash_ns = start.elapsed().as_secs_f64() * 1e9 / sample.len() as f64;
        let start = Instant::now();
        for word in &sample {
            if sorted.binary_search(word).is_ok() {
                hits += 1;
            }
        }
        let bsearch_ns = start.elapsed().as_secs_f64() * 1e9 / sample.len() as f64;
        std::hint::black_box(hits);
        println!("  is_word    hash {hash_ns:>6.0} ns   vs   binary search {bsearch_ns:>6.0} ns");
        println!();
    }

    println!("resident = bytes held beyond the compiled-in text all variants share");
    println!("ns/step  = per cursor advance, the operation move generation repeats");
}
