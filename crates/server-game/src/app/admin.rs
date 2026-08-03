use super::*;

pub(crate) async fn require_loopback(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    if !addr.ip().is_loopback() {
        return ApiProblem::forbidden("Admin endpoints are only reachable from the server itself")
            .into_response();
    }
    next.run(request).await
}

// Reachable only from loopback (see `require_loopback`) — an operator with
// terminal access to the server, not player-facing, hence no per-account
// auth here.

pub(crate) async fn admin_list_users(
    State(state): State<AppState>,
) -> Result<Json<Vec<api::AdminPlayerSummaryDto>>, ApiProblem> {
    let players = persistence::list_player_summaries(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    Ok(Json(players))
}

pub(crate) async fn admin_delete_user(
    State(state): State<AppState>,
    Path(player_id): Path<String>,
) -> Result<StatusCode, ApiProblem> {
    // Refuse while the account has any game at all — seated or created.
    //
    // Deleting a user with games attached is what raises every awkward
    // question: unclaimed seats, an unmanageable game whose creator is gone,
    // another player's history half-owned by an account that no longer
    // exists. Requiring the games to be gone first removes all of them.
    //
    // It is only reasonable because games do not last: a finished one is
    // swept a week after it ends, and an unstarted one within 30 days unless
    // its creator keeps asking to keep it — which a departing user will not.
    // So the admin waits, or deletes the games explicitly first. Two ordered
    // commands rather than one with cascading semantics.
    {
        let games = state.games.read().await;
        let attached: Vec<&str> = games
            .values()
            .filter(|game| {
                game.creator_player_id.as_deref() == Some(player_id.as_str())
                    || game
                        .participants
                        .iter()
                        .any(|seat| seat.player_id.as_deref() == Some(player_id.as_str()))
            })
            .map(|game| game.id.as_str())
            .collect();
        if !attached.is_empty() {
            return Err(ApiProblem::bad_request(format!(
                "That account still has {} game(s): {}. Delete them first, or \
                 wait — a finished game is removed a week after it ends.",
                attached.len(),
                attached.join(", "),
            )));
        }
    }

    let deleted = persistence::delete_player(&state.db, &player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !deleted {
        return Err(ApiProblem::not_found("Player not found"));
    }

    // `delete_player` nulls `game_participants.player_id` in the database, but
    // every loaded `GameSession` is a separate in-memory copy — and the
    // creator id lives in `snapshot_json` rather than a column, so SQL cannot
    // reach it at all. `release_player` does both, bumps the version so
    // clients actually see the seat become unclaimed, and reports whether
    // anything changed so only affected games are written and announced.
    let mut touched = Vec::new();
    {
        let mut games = state.games.write().await;
        for game in games.values_mut() {
            if game.release_player(&player_id) {
                if let Err(error) = persistence::save_game(&state.db, game).await {
                    tracing::error!(game_id = %game.id, %error, "failed to persist user deletion");
                }
                touched.push(game.to_dto());
            }
        }
    }
    for dto in touched {
        let _ = state
            .events
            .send(api::GameEventDto::StateUpdated { game: dto });
    }

    tracing::warn!(player_id, "admin: user deleted");
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn admin_reset_password(
    State(state): State<AppState>,
    Path(player_id): Path<String>,
    Json(request): Json<AdminResetPasswordRequest>,
) -> Result<StatusCode, ApiProblem> {
    if request.new_password.is_empty() {
        return Err(ApiProblem::bad_request("A new password is required"));
    }
    // Bounded like every other hash, though this endpoint is loopback-only
    // with a single client: the work costs the same 19 MiB either way, and an
    // admin reset landing during a login flurry should queue with them rather
    // than adding to the total.
    let password_hash = hash_password_bounded(&state, &request.new_password).await?;
    let updated = persistence::update_player_password(&state.db, &player_id, &password_hash)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !updated {
        return Err(ApiProblem::not_found("Player not found"));
    }
    tracing::warn!(player_id, "admin: password reset");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
pub(crate) struct AdminGamesQuery {
    status: Option<String>,
    older_than_days: Option<i64>,
}

pub(crate) async fn admin_list_games(
    State(state): State<AppState>,
    Query(query): Query<AdminGamesQuery>,
) -> Result<Json<Vec<AdminGameSummaryDto>>, ApiProblem> {
    let created_at = persistence::created_at_by_game(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    let last_activity = persistence::last_activity_by_game(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;

    let status_filter = match query.status.as_deref() {
        Some("waiting") => Some(api::GameStatus::Waiting),
        Some("active") => Some(api::GameStatus::Active),
        Some("finished") => Some(api::GameStatus::Finished),
        Some("aborted") => Some(api::GameStatus::Aborted),
        Some(other) => {
            return Err(ApiProblem::bad_request(format!(
                "Unknown status '{other}', expected waiting/active/finished/aborted"
            )));
        }
        None => None,
    };
    let cutoff = query
        .older_than_days
        .map(|days| now_unix_seconds() - days * 86_400);

    let games = state.games.read().await;
    let mut summaries: Vec<AdminGameSummaryDto> = games
        .values()
        .filter(|game| {
            status_filter
                .as_ref()
                .is_none_or(|status| &game.status == status)
        })
        .filter(|game| {
            let Some(cutoff) = cutoff else {
                return true;
            };
            created_at
                .get(&game.id)
                .is_some_and(|created| *created <= cutoff)
        })
        .map(|game| AdminGameSummaryDto {
            id: game.id.clone(),
            status: game.status,
            created_at: created_at.get(&game.id).copied().unwrap_or(0),
            last_activity_at: last_activity.get(&game.id).copied().unwrap_or(0),
            participants: game
                .participants
                .iter()
                .map(|participant| api::ParticipantDto {
                    seat_number: participant.seat_number,
                    kind: participant.kind.clone(),
                    display_name: participant.display_name.clone(),
                    player_id: participant.player_id.clone(),
                    engine_id: participant.engine_id.clone(),
                    score: participant.score,
                    // Not meaningful in an admin summary view.
                    invitation_status: None,
                    invited_email: participant.invited_email.clone(),
                    rating_before: None,
                    rating_after: None,
                    current_rating: None,
                    resigned: participant.resigned,
                })
                .collect(),
        })
        .collect();
    summaries.sort_by_key(|s| std::cmp::Reverse(s.created_at));

    Ok(Json(summaries))
}

pub(crate) async fn admin_delete_game(
    State(state): State<AppState>,
    Path(game_id): Path<String>,
) -> Result<StatusCode, ApiProblem> {
    let deleted = persistence::delete_game(&state.db, &game_id)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !deleted {
        return Err(ApiProblem::not_found("Game not found"));
    }
    state.games.write().await.remove(&game_id);
    tracing::warn!(game_id, "admin: game deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// Directly marks a game `Finished` without going through per-seat
/// resignation — for an operator to clear out a stuck or abandoned game
/// (e.g. a human seat that will never act again). Doesn't touch scores or
/// `winner_seat`. Rejects a game that has already ended (see
/// `GameSession::admin_force_finish`) rather than overwriting its result.
pub(crate) async fn admin_force_end_game(
    State(state): State<AppState>,
    Path(game_id): Path<String>,
) -> Result<Json<api::GameStateDto>, ApiProblem> {
    let mut dto = {
        let mut games = state.games.write().await;
        let game = games
            .get_mut(&game_id)
            .ok_or_else(|| ApiProblem::not_found("Game not found"))?;
        game.admin_force_finish().map_err(ApiProblem::bad_request)?;
        let dto = game.to_dto();
        persistence::save_game(&state.db, game)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        dto
    };
    stats::attach_current_ratings(&state.db, &mut dto)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    // Always a no-op in practice — an admin force-end never moves rating
    // (see `stats::settle_ratings`) — but calling it anyway keeps this
    // handler consistent with every other place a Finished game's DTO
    // goes out, rather than being a special case someone has to remember.
    stats::attach_rating_deltas(&state.db, &mut dto)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    tracing::warn!(game_id, "admin: game force-ended");
    let _ = state
        .events
        .send(GameEventDto::GameFinished { game: dto.clone() });
    Ok(Json(dto))
}
