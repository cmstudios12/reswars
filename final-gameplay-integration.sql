-- ============================================================
-- RES WARS — FINAL GAMEPLAY INTEGRATION
-- Run AFTER:
-- profile-room-system.sql
-- progression-engine.sql
-- presence-invites.sql
-- invite-session-bridge.sql
-- ready-countdown.sql
-- ============================================================

-- Award results from an authoritative finished universal game.
create or replace function public.rw_claim_finished_game(p_session uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.rw_sessions; me public.rw_players; top_score int; winners int; won boolean;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into s from public.rw_sessions where id=p_session;
 if s.id is null then raise exception 'Game not found'; end if;
 if s.status<>'finished' then raise exception 'Game is not finished yet'; end if;
 select * into me from public.rw_players where session_id=s.id and user_id=auth.uid();
 if me.user_id is null then raise exception 'You did not play this game'; end if;
 select max(score) into top_score from public.rw_players where session_id=s.id;
 select count(*) into winners from public.rw_players where session_id=s.id and score=top_score;
 won := me.score=top_score and winners=1;
 return public.rw_finish_game(s.id::text,s.game_slug,coalesce(me.score,0),won);
end $$;

-- Spin is participation-based: no fake winner.
create or replace function public.rw_claim_finished_spin(p_session uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.stb_sessions; p public.stb_players;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into s from public.stb_sessions where id=p_session;
 if s.id is null then raise exception 'Spin game not found'; end if;
 if s.status<>'finished' then raise exception 'Spin game is not finished yet'; end if;
 select * into p from public.stb_players where session_id=s.id and user_id=auth.uid();
 if p.user_id is null then raise exception 'You did not play this game'; end if;
 return public.rw_finish_game(s.id::text,'spin-the-bottle',0,false);
end $$;

revoke all on function public.rw_claim_finished_game(uuid) from public;
revoke all on function public.rw_claim_finished_spin(uuid) from public;
grant execute on function public.rw_claim_finished_game(uuid) to authenticated;
grant execute on function public.rw_claim_finished_spin(uuid) to authenticated;

select 'FINAL GAMEPLAY INTEGRATION READY' result;
