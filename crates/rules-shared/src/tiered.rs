//! Data types for the tiered arena dictionary.
//!
//! This is the storage layout `WordListDictionary` is being replaced by,
//! landing in pieces: the types and their packing first, construction and
//! lookup after. Nothing here is wired into `Dictionary` yet, so the
//! existing implementation remains the one in use.
//!
//! Shape, from the top:
//!
//! - **the arena** — every word as a run of `Letter` bytes in one
//!   allocation, with an offset table, so letter *d* of word *i* is an
//!   indexed read rather than a pointer chase.
//! - **a dense table** over the first *two* characters, addressed
//!   arithmetically as `l0 × n + l1`. There is deliberately no one-letter
//!   tier: nothing ever asks a question about a one-character prefix,
//!   because every letter starts some word and one-letter words are
//!   illegal (Scrabble's opening play needs two tiles, and no list we
//!   ship contains a single-character entry).
//! - **a sparse index** below it, holding only prefixes that exist, and
//!   only while a group is bigger than `T1` words. Below that the group
//!   is a leaf and the arena is searched directly.
//!
//! The measurements behind the field widths are in
//! `examples/sparse_budget.rs`.

/// Above this many words a group keeps a child index; at or below it the
/// group becomes a leaf and the arena is searched directly.
///
/// Bounded by [`Child`]'s 7-bit length field, so this is a structural
/// limit rather than a free tuning knob — see [`Child`].
pub const T1: usize = 64;

/// At or below this many words, scan the arena forward instead of
/// bisecting it. Sequential reads prefetch where a bisect jumps.
///
/// Deliberately separate from [`T1`] even though both are "small enough":
/// `T1` is a memory budget (an index entry must earn its 5 bytes) and
/// `T2` is cache behaviour. They answer different questions and are set
/// by different measurements.
pub const T2: usize = 32;

const _: () = assert!(T1 <= Child::MAX_LEAF_LEN, "T1 must fit Child's len field");
const _: () = assert!(T2 <= T1, "the bisect band is empty unless T2 <= T1");

/// Every shipped list has to fit [`Child`]'s fields, and the widths were
/// chosen against the counts in `examples/sparse_budget.rs` rather than
/// against SOWPODS alone — German and Spanish are both ~600k words and
/// are what actually bound the design. Asserted at compile time, with a
/// 3× margin, so narrowing a field to save a bit fails the build here
/// rather than as a panic in `Child::leaf` on one particular word list.
const _: () = {
    assert!(
        151_804 * 3 < Child::MAX_EDGES,
        "spanish @ T1=32, worst edges"
    );
    assert!(635_090 * 3 < Child::MAX_WORDS, "spanish, worst word count");
    assert!(28 <= Child::MAX_FANOUT, "german, widest node");
};

/// One packed edge target: where the words under this prefix live, how
/// many there are, and whether the prefix is itself a word.
///
/// Both non-empty variants are a *(length, start)* pair — the tag only
/// says which array `start` indexes. That is what lets a leaf's word
/// range live in the pointer rather than in an array of its own: a leaf
/// holds at most [`T1`] words *by construction*, and a node's fan-out is
/// at most the alphabet, so neither length has to be general.
///
/// ```text
///  31          30 29        23 22                       0
/// ┌──────────────┬─────────────┬──────────────────────────┐
/// │ tag (2)      │ is_word (1) │ len (6|7) │ start (23|22)│
/// └──────────────┴─────────────┴──────────────────────────┘
/// ```
///
/// `Empty` is tag zero so that an all-zero word *is* an empty slot: the
/// dense table can be zero-initialised, and a construction bug that skips
/// a slot reads as "no such prefix" rather than as a valid pointer at
/// entry 0. The sparse arrays never contain `Empty` — there, absence is
/// the letter simply not appearing in the node's letter run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Child(u32);

/// The decoded form of a [`Child`], for matching on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChildKind {
    /// No word has this prefix. Only ever produced by the dense table.
    Empty,
    /// The group is indexed: `fanout` edges start at `start` in the
    /// sparse arrays.
    Index { start: u32, fanout: u8 },
    /// The group was at or below [`T1`] at construction: `len` words
    /// start at word index `from` in the arena.
    Leaf { from: u32, len: u8 },
}

impl Child {
    const TAG_SHIFT: u32 = 30;
    const IS_WORD_SHIFT: u32 = 29;

    const TAG_EMPTY: u32 = 0;
    const TAG_INDEX: u32 = 1;
    const TAG_LEAF: u32 = 2;

    // Index: 6 bits of fan-out (bounded by MAX_ALPHABET_SIZE), 23 of start.
    const INDEX_LEN_BITS: u32 = 6;
    const INDEX_START_BITS: u32 = 23;
    // Leaf: 7 bits of length (bounded by T1), 22 of first word index.
    const LEAF_LEN_BITS: u32 = 7;
    const LEAF_START_BITS: u32 = 22;

    /// Largest fan-out a node may have. Equals `MAX_ALPHABET_SIZE`, which
    /// is what actually bounds it; the widest node measured is 28.
    pub const MAX_FANOUT: usize = 1 << Self::INDEX_LEN_BITS;
    /// Largest word range a leaf may cover, which is what bounds [`T1`].
    pub const MAX_LEAF_LEN: usize = 1 << Self::LEAF_LEN_BITS;
    /// Largest addressable sparse-edge array. Worst measured is 151,804
    /// (Spanish at T1=32).
    pub const MAX_EDGES: usize = 1 << Self::INDEX_START_BITS;
    /// Largest addressable word list. Worst measured is 635,090 (Spanish).
    pub const MAX_WORDS: usize = 1 << Self::LEAF_START_BITS;

    const _LAYOUT: () = {
        assert!(2 + 1 + Self::INDEX_LEN_BITS + Self::INDEX_START_BITS == 32);
        assert!(2 + 1 + Self::LEAF_LEN_BITS + Self::LEAF_START_BITS == 32);
        assert!(Self::MAX_FANOUT >= crate::model::MAX_ALPHABET_SIZE);
    };

    /// The empty slot. Equal to `Child(0)`, so a zeroed allocation is
    /// already a table of empty slots.
    pub const EMPTY: Self = Self(0);

    /// An indexed group: `fanout` edges beginning at `start`.
    ///
    /// # Panics
    /// If `fanout` or `start` exceeds what the field can hold — a
    /// construction bug, not a runtime condition, so it fails loudly
    /// rather than silently truncating into a wrong pointer.
    pub fn index(start: u32, fanout: u8, is_word: bool) -> Self {
        assert!(
            fanout as usize <= Self::MAX_FANOUT,
            "fan-out {fanout} overflows Child"
        );
        assert!(
            (start as usize) < Self::MAX_EDGES,
            "edge index {start} overflows Child"
        );
        assert!(fanout > 0, "an indexed group has at least one child");
        Self(
            (Self::TAG_INDEX << Self::TAG_SHIFT)
                | ((is_word as u32) << Self::IS_WORD_SHIFT)
                // Stored biased by one: a fan-out of 0 cannot occur, so
                // the field reaches MAX_FANOUT rather than stopping one
                // short of it.
                | ((fanout as u32 - 1) << Self::INDEX_START_BITS)
                | start,
        )
    }

    /// A leaf group: `len` words beginning at word index `from`.
    ///
    /// # Panics
    /// As [`Child::index`].
    pub fn leaf(from: u32, len: u8, is_word: bool) -> Self {
        assert!(
            len as usize <= Self::MAX_LEAF_LEN,
            "leaf length {len} overflows Child"
        );
        assert!(
            (from as usize) < Self::MAX_WORDS,
            "word index {from} overflows Child"
        );
        assert!(len > 0, "a leaf covers at least one word");
        Self(
            (Self::TAG_LEAF << Self::TAG_SHIFT)
                | ((is_word as u32) << Self::IS_WORD_SHIFT)
                | ((len as u32 - 1) << Self::LEAF_START_BITS)
                | from,
        )
    }

    /// Whether the prefix ending at this edge is itself a word.
    ///
    /// Lives here rather than in a parallel array on purpose: the scan
    /// that located the letter has already produced this index, so the
    /// load that fetches the pointer answers this at the same time.
    /// Meaningless for [`Child::EMPTY`], which is never reached with a
    /// question to ask.
    pub fn is_word(self) -> bool {
        self.0 & (1 << Self::IS_WORD_SHIFT) != 0
    }

    pub fn kind(self) -> ChildKind {
        match self.0 >> Self::TAG_SHIFT {
            Self::TAG_EMPTY => ChildKind::Empty,
            Self::TAG_INDEX => ChildKind::Index {
                start: self.0 & ((1 << Self::INDEX_START_BITS) - 1),
                fanout: (((self.0 >> Self::INDEX_START_BITS) & ((1 << Self::INDEX_LEN_BITS) - 1))
                    + 1) as u8,
            },
            Self::TAG_LEAF => ChildKind::Leaf {
                from: self.0 & ((1 << Self::LEAF_START_BITS) - 1),
                len: (((self.0 >> Self::LEAF_START_BITS) & ((1 << Self::LEAF_LEN_BITS) - 1)) + 1)
                    as u8,
            },
            _ => unreachable!("Child has only three tags and none can be constructed"),
        }
    }

    pub fn is_empty(self) -> bool {
        self.0 >> Self::TAG_SHIFT == Self::TAG_EMPTY
    }
}

/// A position part-way through spelling a word, handed back by `advance`
/// and passed into the next call.
///
/// Each variant is one regime of the walk, and the payloads are the
/// *(length, start)* pairs a [`Child`] already held, unpacked once so the
/// hot path doesn't re-decode them.
///
/// `depth` counts *characters*, not tiles: a digraph tile advances it by
/// more than one, which is what makes both tilings of Spanish CH reach
/// the same entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cursor {
    /// Nothing spelled yet.
    Start,
    /// One character seen. Nothing is resolved and nothing needs to be —
    /// every letter starts some word, so there is no prune signal to
    /// give, and a one-character word cannot be legal.
    First(u8),
    /// Inside the sparse index: `fanout` edges from `start`.
    Node { start: u32, fanout: u8, depth: u8 },
    /// A word range in the arena: bisect it above [`T2`], scan it below.
    Range { from: u32, len: u8, depth: u8 },
}

/// The result of advancing one letter: where we are now, and whether what
/// has been spelled is a word. Returned as `Option<Step>` — `None` *is*
/// "no word continues with this", the prune signal — so a cursor that
/// isn't valid can't be used by mistake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    pub cursor: Cursor,
    pub is_word: bool,
}

#[cfg(test)]
mod tests {
    use super::{Child, ChildKind, Cursor};

    #[test]
    fn empty_is_all_zero_so_a_zeroed_table_is_already_empty() {
        assert_eq!(Child::EMPTY, Child::default());
        assert_eq!(Child::EMPTY.0, 0);
        assert!(Child::EMPTY.is_empty());
        assert_eq!(Child::EMPTY.kind(), ChildKind::Empty);
    }

    /// The whole point of packing: a slot that was never written must not
    /// decode as a usable pointer at entry 0.
    #[test]
    fn a_zeroed_slot_does_not_decode_as_a_valid_pointer() {
        assert!(!matches!(
            Child(0).kind(),
            ChildKind::Index { .. } | ChildKind::Leaf { .. }
        ));
    }

    #[test]
    fn index_round_trips_including_the_field_extremes() {
        for (start, fanout, is_word) in [
            (0u32, 1u8, false),
            (1, 2, true),
            (151_804, 28, true),
            ((Child::MAX_EDGES - 1) as u32, Child::MAX_FANOUT as u8, true),
        ] {
            let child = Child::index(start, fanout, is_word);
            assert_eq!(child.kind(), ChildKind::Index { start, fanout });
            assert_eq!(child.is_word(), is_word);
            assert!(!child.is_empty());
        }
    }

    #[test]
    fn leaf_round_trips_including_the_field_extremes() {
        for (from, len, is_word) in [
            (0u32, 1u8, false),
            (1, 2, true),
            (635_090, 64, false),
            (
                (Child::MAX_WORDS - 1) as u32,
                Child::MAX_LEAF_LEN as u8,
                true,
            ),
        ] {
            let child = Child::leaf(from, len, is_word);
            assert_eq!(child.kind(), ChildKind::Leaf { from, len });
            assert_eq!(child.is_word(), is_word);
            assert!(!child.is_empty());
        }
    }

    /// `is_word` shares its word with the pointer, so a mistake in the
    /// packing would show up as the flag bleeding into the payload or
    /// vice versa. Vary one with the other pinned, both ways round.
    #[test]
    fn is_word_is_independent_of_the_payload() {
        for is_word in [false, true] {
            assert_eq!(Child::index(151_804, 28, is_word).is_word(), is_word);
            assert_eq!(Child::leaf(635_090, 64, is_word).is_word(), is_word);
        }
        for is_word in [false, true] {
            assert_eq!(
                Child::index(151_804, 28, is_word).kind(),
                ChildKind::Index {
                    start: 151_804,
                    fanout: 28
                }
            );
            assert_eq!(
                Child::leaf(635_090, 64, is_word).kind(),
                ChildKind::Leaf {
                    from: 635_090,
                    len: 64
                }
            );
        }
    }

    #[test]
    #[should_panic(expected = "overflows Child")]
    fn a_word_index_past_the_field_panics_rather_than_truncating() {
        Child::leaf(Child::MAX_WORDS as u32, 1, false);
    }

    #[test]
    #[should_panic(expected = "overflows Child")]
    fn an_edge_index_past_the_field_panics_rather_than_truncating() {
        Child::index(Child::MAX_EDGES as u32, 1, false);
    }

    /// Small and `Copy`, because move generation passes it by value at
    /// every step of every candidate.
    #[test]
    fn cursor_stays_small() {
        assert!(std::mem::size_of::<Cursor>() <= 8);
    }
}
