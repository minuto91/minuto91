-- Minuto 91 / 038: incremental statistics at finalization (V4.2 sec. 8.2). Formulas untouched.
-- A finalized match only changes the counters (season and career) of the players on its sheet: their
-- games, goals, results, ratings, streaks and the Craque of that match. Recomputing every member of the
-- pelada at each finalization (014) was the largest share of the ~0.9 s measured in V4.1.
-- Now after_match_finalized rebuilds only those players, with the SAME per-member function
-- (private.compute_stats), so the result is identical to the full recomputation (checked by
-- supabase/local_db/load.mjs, which compares both outputs row by row).
-- Cards still recompute the whole season: Presença uses the number of finalized matches of the season,
-- so every player's Card changes at each match (official rule, Doc 03 sec. 19).
-- Annulment (020) and the clean-up keep the full recomputation (rare events).

create function private.recompute_member_stats(p_pelada uuid, p_season uuid, p_membership uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.player_season_stats;
begin
 delete from public.player_career_stats where pelada_id=p_pelada and membership_id=p_membership;
 delete from public.player_season_stats where season_id=p_season and membership_id=p_membership;
 s := private.compute_stats(p_pelada, p_membership, null);
 if s.matches_played > 0 then
  insert into public.player_career_stats(pelada_id,membership_id,matches_played,wins,draws,losses,goals,assists,
   red_cards,valid_ratings,avg_final_rating,high_ratings,best_final_rating,max_goals_in_match,craque_awards,
   best_win_streak,best_unbeaten_streak,best_high_rating_streak,current_win_streak,current_unbeaten_streak,
   current_high_rating_streak)
  values(p_pelada,p_membership,s.matches_played,s.wins,s.draws,s.losses,s.goals,s.assists,s.red_cards,s.valid_ratings,
   s.avg_final_rating,s.high_ratings,s.best_final_rating,s.max_goals_in_match,s.craque_awards,s.best_win_streak,
   s.best_unbeaten_streak,s.best_high_rating_streak,s.current_win_streak,s.current_unbeaten_streak,
   s.current_high_rating_streak);
 end if;
 if private.retention_excluded(p_season, p_membership) then return; end if;
 s := private.compute_stats(p_pelada, p_membership, p_season);
 if s.matches_played > 0 then
  s.id := gen_random_uuid(); s.updated_at := now();
  insert into public.player_season_stats values (s.*);
 end if;
end $$;

create or replace function private.after_match_finalized(p_match uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_m public.matches; v_mem uuid;
begin
 select * into v_m from public.matches where id=p_match;
 for v_mem in select membership_id from public.match_player_results where match_id=p_match order by membership_id loop
  perform private.recompute_member_stats(v_m.pelada_id, v_m.season_id, v_mem);
 end loop;
 perform private.recompute_cards(v_m.season_id, p_match);
 perform private.after_cards_updated(p_match);
end $$;

revoke all on function private.recompute_member_stats(uuid,uuid,uuid) from public,anon,authenticated;
