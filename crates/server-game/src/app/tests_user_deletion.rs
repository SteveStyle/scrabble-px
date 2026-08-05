//! Deleting an account, and the retention that eventually allows it.
//!
//! Rules: `docs/1.0-rules.md`, DEL-1 to DEL-9 and RET-1 to RET-4. Test plan:
//! issue #41.
//!
//! Most tests here are a walk rather than a single check — build the thing
//! that attaches an account to a game, watch the delete refused, bring the
//! game to an end, backdate it past the retention window, sweep, then watch
//! the same delete succeed. A test that only proved the refusal would pass
//! just as well against a guard that refused everything, and the second half
//! is what pins the refusal to the attachment rather than to the account.
//!
//! It also puts the sweep under test. The middle of every walk is a real
//! retention pass removing a real game, so a retention bug fails here rather
//! than waiting to be noticed in production — which is how the last one was
//! found.

use super::tests::{
    create_test_state, create_three_human_game, create_two_human_game,
    create_two_human_game_waiting, loopback_peer, read_json, register_player, send_admin,
    send_empty_auth, send_json_auth, test_database_url,
};
use super::*;
use api::{
    CreateSeatRequest, GameActionRequest, GameStateDto, InvitePlayerRequest, PlayerActionDto,
    SeatClaim, SeatKind,
};
use axum::body::Body;
use axum::http::Method;

/// Comfortably past RET-1's seven days, so a backdated game is unambiguously
/// old rather than sitting on the boundary.
const WELL_PAST_THE_WINDOW: i64 = 8 * 24 * 60 * 60;

// ---------------------------------------------------------------- the walk

async fn delete_account(app: Router, player_id: &str) -> axum::http::Response<Body> {
    send_admin::<()>(
        app,
        Method::DELETE,
        &format!("/admin/users/{player_id}"),
        loopback_peer(),
        None,
    )
    .await
}

/// DEL-2 refused, and DEL-6 satisfied — the message has to name what is in
/// the way. Asserted separately from the status because five different
/// attachments produce the same 400, and without this they would all pass on
/// a refusal that told the operator nothing.
async fn assert_refused(app: Router, player_id: &str, naming: &[&str]) {
    let response = delete_account(app, player_id).await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "an attached account should not be deletable"
    );
    let problem: serde_json::Value = read_json(response).await;
    let message = problem["message"]
        .as_str()
        .expect("a problem response carries a message")
        .to_string();
    for id in naming {
        assert!(
            message.contains(id),
            "the refusal should name {id}, said: {message}"
        );
    }
}

async fn assert_deleted(app: Router, player_id: &str) {
    let response = delete_account(app, player_id).await;
    assert_eq!(
        response.status(),
        StatusCode::NO_CONTENT,
        "an unattached account should be deletable"
    );
}

async fn game_rows(state: &AppState, game_id: &str) -> i64 {
    sqlx::query_scalar::<_, i64>("select count(*) from games where id = ?1")
        .bind(game_id)
        .fetch_one(&state.db)
        .await
        .expect("counting games should work")
}

/// Both sweeps are lazy — no scheduler in this server — so listing games is
/// what runs them (`sweeps::expire_overdue_turns`, `expire_old_terminal_games`).
async fn trigger_sweeps(app: Router, token: &str) {
    let response = send_empty_auth(app, Method::GET, "/games", Some(token)).await;
    assert_eq!(response.status(), StatusCode::OK);
}

/// Backdate a terminal game past RET-1 and let the sweep take it.
///
/// `ended_at` is a column and lives only in SQL, so this is a plain update —
/// unlike `turn_started_at`, which is a field inside `snapshot_json`.
async fn sweep_away(app: Router, state: &AppState, game_id: &str, token: &str) {
    let ended = now_unix_seconds() - WELL_PAST_THE_WINDOW;
    sqlx::query("update games set ended_at = ?1 where id = ?2")
        .bind(ended)
        .bind(game_id)
        .execute(&state.db)
        .await
        .expect("backdating the end should work");

    trigger_sweeps(app, token).await;

    assert_eq!(
        game_rows(state, game_id).await,
        0,
        "the sweep should have removed a game {} days past the window",
        WELL_PAST_THE_WINDOW / 86_400
    );
    assert!(
        !state.games.read().await.contains_key(game_id),
        "a swept game should leave the loaded set too, not only the database"
    );
}

// ------------------------------------------------------------- game set-up

fn human(display_name: &str, claim: Option<SeatClaim>) -> CreateSeatRequest {
    CreateSeatRequest {
        kind: SeatKind::Human,
        display_name: display_name.to_string(),
        engine_id: None,
        claim,
    }
}

fn engine(display_name: &str) -> CreateSeatRequest {
    CreateSeatRequest {
        kind: SeatKind::Engine,
        display_name: display_name.to_string(),
        engine_id: Some("greedy-v1".to_string()),
        claim: None,
    }
}

async fn create_game(app: Router, token: &str, seats: Vec<CreateSeatRequest>) -> GameStateDto {
    let response = send_json_auth(
        app,
        Method::POST,
        "/games",
        Some(token),
        &CreateGameRequest {
            seats,
            seed: Some(42),
            variant: None,
            language: None,
            board_layout: None,
            move_time_limit_seconds: None,
        },
    )
    .await;
    let status = response.status();
    if status != StatusCode::OK {
        let body: serde_json::Value = read_json(response).await;
        panic!("creating the game should succeed, got {status}: {body}");
    }
    read_json(response).await
}

/// Alice, with an unstarted game whose second seat is open to anyone and has
/// no taker.
///
/// This stands in for "the creator built a roster and asked nobody", which
/// cannot actually arise: every human seat needs a claim at creation, and
/// each claim creates an invitation, so `SeatInvitationStatus::NotSent` is
/// unreachable through the API for a seat that exists.
async fn alice_with_an_open_seat(app: Router) -> (PlayerSessionDto, GameStateDto) {
    let alice = register_player(app.clone(), "Alice").await;
    let game = create_game(
        app,
        &alice.session_token,
        vec![
            human("Alice", Some(SeatClaim::Creator)),
            human("Second seat", Some(SeatClaim::Open)),
        ],
    )
    .await;
    (alice, game)
}

/// Alice, having asked Bob by name for the second seat. He has not answered.
async fn alice_having_asked_bob(
    app: Router,
) -> (PlayerSessionDto, PlayerSessionDto, GameStateDto) {
    let alice = register_player(app.clone(), "Alice").await;
    let bob = register_player(app.clone(), "Bob").await;
    let game = create_game(
        app.clone(),
        &alice.session_token,
        vec![
            human("Alice", Some(SeatClaim::Creator)),
            human(
                "Bob",
                Some(SeatClaim::Named {
                    display_name: "Bob".to_string(),
                }),
            ),
        ],
    )
    .await;
    (alice, bob, game)
}

/// The pending invitation on a seat, as the invitee sees it in their own
/// games list — the path a real client uses to find one.
async fn invitation_for(app: Router, game_id: &str, token: &str) -> String {
    let games: Vec<api::GameSummaryDto> =
        read_json(send_empty_auth(app, Method::GET, "/games", Some(token)).await).await;
    games
        .iter()
        .find(|summary| summary.id == game_id)
        .expect("an invited player should see the game")
        .invitation_id
        .clone()
        .expect("an invited entry should carry an invitation id")
}

async fn decline(app: Router, invitation_id: &str, token: &str) {
    let response = send_empty_auth(
        app,
        Method::POST,
        &format!("/invitations/{invitation_id}/reject"),
        Some(token),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "declining should succeed");
}

async fn abort(app: Router, game_id: &str, token: &str) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/abort"),
        Some(token),
        &serde_json::json!({}),
    )
    .await;
    let status = response.status();
    if status != StatusCode::OK {
        let body: serde_json::Value = read_json(response).await;
        panic!("aborting should succeed, got {status}: {body}");
    }
}

async fn resign(app: Router, game_id: &str, token: &str, seat: u8) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/actions"),
        Some(token),
        &GameActionRequest {
            seat_number: seat,
            action: PlayerActionDto::Resign,
        },
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "resigning should succeed");
}

async fn pass_turn(app: Router, game_id: &str, token: &str, seat: u8) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/actions"),
        Some(token),
        &GameActionRequest {
            seat_number: seat,
            action: PlayerActionDto::Pass,
        },
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "passing should succeed");
}

async fn hide_from_my_list(app: Router, game_id: &str, token: &str) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/remove"),
        Some(token),
        &serde_json::json!({}),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "removing should succeed");
}

// ============================================================== S1 to S4
// The four situations an unstarted game can be in. The refusal is the same
// in all four, which is the point: it does not care how far the game got.

#[tokio::test]
async fn cannot_delete_a_creator_of_an_unstarted_game_with_an_open_seat() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, game) = alice_with_an_open_seat(app.clone()).await;

    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_while_an_invitation_is_outstanding() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, _bob, game) = alice_having_asked_bob(app.clone()).await;

    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_after_an_invitation_is_declined() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;
    let invitation = invitation_for(app.clone(), &game.id, &bob.session_token).await;
    decline(app.clone(), &invitation, &bob.session_token).await;

    // Declining releases Bob (DEL-3) but does nothing for Alice, who still
    // created the game.
    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_of_a_game_ready_to_start() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let waiting = create_two_human_game_waiting(app.clone()).await;

    assert_refused(app.clone(), &waiting.alice.player_id, &[&waiting.game.id]).await;

    abort(app.clone(), &waiting.game.id, &waiting.alice.session_token).await;
    sweep_away(
        app.clone(),
        &state,
        &waiting.game.id,
        &waiting.alice.session_token,
    )
    .await;

    assert_deleted(app, &waiting.alice.player_id).await;
}

// ============================================================== S5 to S11

#[tokio::test]
async fn cannot_delete_a_player_seated_in_a_game_in_play() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;

    // Bob holds a seat he did not create — the seat arm of DEL-2 on its own.
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    let force_end = send_admin::<()>(
        app.clone(),
        Method::POST,
        &format!("/admin/games/{}/force-end", playing.game.id),
        loopback_peer(),
        None,
    )
    .await;
    assert_eq!(force_end.status(), StatusCode::OK);

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_until_their_finished_game_is_swept() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    // Two seats, so one resignation leaves one player and finishes the game.
    resign(app.clone(), &playing.game.id, &playing.alice.session_token, 0).await;

    // Finished, but inside the window — a game that has ended still refuses.
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;

    assert_deleted(app, &playing.alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_who_took_no_seat() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let alice = register_player(app.clone(), "Alice").await;
    let game = create_game(
        app.clone(),
        &alice.session_token,
        vec![engine("Greedy One"), engine("Greedy Two")],
    )
    .await;

    // The creator arm of DEL-2 on its own: Alice holds no seat at all.
    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_who_resigned_while_the_game_continued() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    // Bob resigns on his own turn. Resigning off-turn is allowed but leaves
    // the game unable to record another move (#62), so a walk that has to
    // reach an end state cannot use it — the game would be stuck rather than
    // swept, and this test would be asserting that bug instead of the rule.
    pass_turn(app.clone(), &playing.game.id, &playing.alice.session_token, 0).await;
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;

    // Three seats, so Bob leaving does not end the game — and the seat he
    // gave up still refers to him.
    assert!(
        state
            .games
            .read()
            .await
            .get(&playing.game.id)
            .map(|game| game.status == api::GameStatus::Active)
            .unwrap_or(false),
        "a three-player game should carry on after one seat resigns"
    );
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;
    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_either_player_of_an_aborted_game() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;

    // GAME-1: aborting gives up every seat, so neither of them holds a seat
    // they have not given up — and both are still refused.
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app.clone(), &playing.alice.player_id).await;
    assert_deleted(app, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_with_an_unanswered_invitation() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;

    // DEL-2's third arm. Bob holds no seat and created nothing — only an
    // invitation he has not answered.
    assert_refused(app.clone(), &bob.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &bob.player_id).await;
}

#[tokio::test]
async fn hiding_a_game_does_not_make_its_players_deletable() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    resign(app.clone(), &playing.game.id, &playing.alice.session_token, 0).await;

    hide_from_my_list(app.clone(), &playing.game.id, &playing.alice.session_token).await;
    hide_from_my_list(app.clone(), &playing.game.id, &playing.bob.session_token).await;

    // DEL-5. Both lists are empty, so from the outside the accounts look
    // unattached — and neither can be deleted.
    let alice_games: Vec<api::GameSummaryDto> = read_json(
        send_empty_auth(
            app.clone(),
            Method::GET,
            "/games",
            Some(&playing.alice.session_token),
        )
        .await,
    )
    .await;
    assert!(
        alice_games.is_empty(),
        "removing the only game should leave an empty list"
    );

    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;

    assert_deleted(app.clone(), &playing.alice.player_id).await;
    assert_deleted(app, &playing.bob.player_id).await;
}
