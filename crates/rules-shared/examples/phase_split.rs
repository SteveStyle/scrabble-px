//! Dev-only: where does a bot's turn actually spend its time?
//!
//! Usage: `cargo run --release -p rules-shared --example phase_split`
//!
//! The dictionary work in a turn splits into two phases that behave
//! completely differently, and it matters which one dominates before
//! optimising either:
//!
//! - **cross-checks** — `apply_move` re-derives, for every empty square and
//!   both directions, which letters could legally sit there. Each
//!   constrained square asks the dictionary once per letter of the
//!   alphabet. This happens **once per move applied**, and is a full-board
//!   sweep rather than an incremental update.
//! - **generation** — `enumerate_legal_moves` walks the prefix cursor
//!   millions of times per turn, pruning as it goes.
//!
//! A 2x improvement to cross-checks is worth little if they are 2% of the
//! turn, so this reports the ratio rather than either number alone.

use std::time::Instant;

use rules_shared::{
    BoardCell, BoardState, Direction, FilledCell, Letter, Position, Rack, RuleCache, RulesEngine,
    VariantRules, WordListDictionary,
};

const REPS: usize = 5;

/// A plausible mid-game board: real words crossing each other, leaving most
/// squares empty but many of them constrained.
fn mid_game_board(rules: &VariantRules) -> BoardState {
    let mut board = BoardState::new(rules);
    let placements: &[(&str, u8, u8, Direction)] = &[
        ("TAZOS", 5, 4, Direction::Horizontal),
        ("JANAPERY", 3, 5, Direction::Horizontal),
        ("QUAXING", 2, 6, Direction::Horizontal),
        ("UNWIT", 2, 7, Direction::Horizontal),
        ("HATTIRED", 3, 8, Direction::Horizontal),
        ("NO", 3, 9, Direction::Horizontal),
        ("SOL", 3, 10, Direction::Horizontal),
        ("IRE", 3, 11, Direction::Horizontal),
        ("KEF", 2, 12, Direction::Horizontal),
        ("ODE", 2, 13, Direction::Horizontal),
    ];
    for (word, x, y, direction) in placements {
        for (offset, ch) in word.chars().enumerate() {
            let offset = offset as u8;
            let letter = Letter::from(ch);
            let pos = match direction {
                Direction::Horizontal => Position::new(x + offset, *y),
                Direction::Vertical => Position::new(*x, y + offset),
            };
            if pos.x >= rules.width || pos.y >= rules.height {
                continue;
            }
            board.set(
                pos,
                BoardCell::Filled(FilledCell {
                    letter,
                    is_blank: false,
                }),
            );
        }
    }
    board
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs"));
    values[values.len() / 2]
}

fn main() {
    let rules = VariantRules::official();
    let dictionary = WordListDictionary::new();
    let engine = RulesEngine {
        rules: &rules,
        dictionary: &dictionary,
    };
    let board = mid_game_board(&rules);

    let mut rack = Rack::default();
    for ch in ['E', 'A', 'R', 'T', 'S', 'N', 'I'] {
        rack.add_letter(Letter::from(ch));
    }

    let empty = (0..rules.height)
        .flat_map(|y| (0..rules.width).map(move |x| Position::new(x, y)))
        .filter(|pos| matches!(board.get(*pos), Some(BoardCell::Empty(_))))
        .count();

    // Phase 1: the full-board cross-check sweep `apply_move` performs.
    let cross_ms = median(
        (0..REPS)
            .map(|_| {
                let mut cache = RuleCache::default();
                let start = Instant::now();
                cache.recompute_all(&board, &rules, &dictionary);
                std::hint::black_box(&cache);
                start.elapsed().as_secs_f64() * 1000.0
            })
            .collect(),
    );

    // Phase 2: generation over the same position.
    let mut cache = RuleCache::default();
    cache.recompute_all(&board, &rules, &dictionary);
    let state = rules_shared::GameState { board, cache };

    let mut move_count = 0usize;
    let gen_ms = median(
        (0..REPS)
            .map(|_| {
                let start = Instant::now();
                let moves = engine.enumerate_legal_multi_tile_moves(&state, &rack);
                move_count = moves.len();
                std::hint::black_box(moves.len());
                start.elapsed().as_secs_f64() * 1000.0
            })
            .collect(),
    );

    let total = cross_ms + gen_ms;
    println!("mid-game board: {empty} empty squares, {move_count} legal moves found");
    println!("median of {REPS} runs:");
    println!(
        "  cross-check sweep   {cross_ms:>8.2} ms   {:>5.1}% of the two",
        100.0 * cross_ms / total
    );
    println!(
        "  move generation     {gen_ms:>8.2} ms   {:>5.1}%",
        100.0 * gen_ms / total
    );
    println!();
    println!(
        "A 2x faster cross-check would save {:.2} ms of {total:.2} ms",
        cross_ms / 2.0
    );
    println!(
        "A 5x faster cursor would save        {:.2} ms of {total:.2} ms",
        gen_ms * 0.8
    );
}
