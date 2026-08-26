
-- ===== SOURCE: profile-room-system.sql =====
-- ============================================================
-- RES WARS — RESIDENT PROFILE + ROOM/TEAM SYSTEM
-- Safe migration for the current RES WARS project.
-- Run this whole file in Supabase SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;

-- 1) Extend profiles WITHOUT requiring a role column.
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists xp integer not null default 0;
alter table public.profiles add column if not exists wins integer not null default 0;
alter table public.profiles add column if not exists games_played integer not null default 0;
alter table public.profiles add column if not exists created_at timestamptz not null default now();

-- 2) Rooms are the team identity.
create table if not exists public.rw_rooms (
  id uuid primary key default gen_random_uuid(),
  residence_id uuid,
  room_number text not null,
  team_name text,
  team_logo_url text,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  total_xp integer not null default 0,
  wins integer not null default 0,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One room number per residence.
create unique index if not exists rw_rooms_residence_room_unique
on public.rw_rooms(coalesce(residence_id::text,'NO_RESIDENCE'), lower(room_number));

-- 3) Membership table. One active room/team per resident.
create table if not exists public.rw_room_members (
  room_id uuid not null references public.rw_rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(room_id,user_id),
  unique(user_id)
);

-- 4) Achievements.
create table if not exists public.rw_achievements (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  description text not null,
  icon text,
  xp_reward integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.rw_user_achievements (
  user_id uuid not null references auth.users(id) on delete cascade,
  achievement_id uuid not null references public.rw_achievements(id) on delete cascade,
  unlocked_at timestamptz not null default now(),
  primary key(user_id,achievement_id)
);

insert into public.rw_achievements(slug,name,description,icon,xp_reward) values
('first-game','First Battle','Play your first RES WARS game','play',50),
('first-win','First Victory','Win your first RES WARS game','trophy',100),
('five-wins','On Fire','Reach 5 wins','flame',200),
('ten-games','Regular','Play 10 games','gamepad',250),
('xp-1000','Rising Star','Reach 1,000 XP','star',300)
on conflict(slug) do update set name=excluded.name,description=excluded.description,icon=excluded.icon,xp_reward=excluded.xp_reward;

-- 5) Game history used by profile/recent activity.
create table if not exists public.rw_game_history (
  id uuid primary key default gen_random_uuid(),
  session_id uuid,
  game_slug text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  room_id uuid references public.rw_rooms(id) on delete set null,
  score integer not null default 0,
  xp_earned integer not null default 0,
  won boolean not null default false,
  played_at timestamptz not null default now()
);
create index if not exists rw_game_history_user_time on public.rw_game_history(user_id,played_at desc);

-- 6) RLS.
alter table public.rw_rooms enable row level security;
alter table public.rw_room_members enable row level security;
alter table public.rw_achievements enable row level security;
alter table public.rw_user_achievements enable row level security;
alter table public.rw_game_history enable row level security;

-- Profiles: residents can update ONLY their own row; existing admin policies remain.
drop policy if exists "rw_profile_update_self" on public.profiles;
create policy "rw_profile_update_self" on public.profiles
for update to authenticated using(id=auth.uid()) with check(id=auth.uid());

-- Rooms are visible to authenticated residents.
drop policy if exists "rw_rooms_read" on public.rw_rooms;
create policy "rw_rooms_read" on public.rw_rooms for select to authenticated using(true);

-- Direct room writes are intentionally restricted; creation/joining uses RPC below.
drop policy if exists "rw_room_members_read" on public.rw_room_members;
create policy "rw_room_members_read" on public.rw_room_members
for select to authenticated using(true);

drop policy if exists "rw_achievements_read" on public.rw_achievements;
create policy "rw_achievements_read" on public.rw_achievements
for select to authenticated using(true);

drop policy if exists "rw_user_achievements_read" on public.rw_user_achievements;
create policy "rw_user_achievements_read" on public.rw_user_achievements
for select to authenticated using(true);

drop policy if exists "rw_history_read" on public.rw_game_history;
create policy "rw_history_read" on public.rw_game_history
for select to authenticated using(true);

-- 7) Secure room creation.
create or replace function public.rw_create_room(p_room_number text, p_team_name text default null)
returns public.rw_rooms
language plpgsql security definer set search_path=public
as $$
declare
  r public.rw_rooms;
  my_residence uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if trim(coalesce(p_room_number,''))='' then raise exception 'Room number is required'; end if;
  if exists(select 1 from public.rw_room_members where user_id=auth.uid()) then
    raise exception 'You already belong to a room/team';
  end if;

  select residence_id into my_residence from public.profiles where id=auth.uid();

  insert into public.rw_rooms(residence_id,room_number,team_name,created_by)
  values(my_residence,trim(p_room_number),nullif(trim(coalesce(p_team_name,'')),'') ,auth.uid())
  returning * into r;

  insert into public.rw_room_members(room_id,user_id) values(r.id,auth.uid());
  update public.profiles set room_id=r.id where id=auth.uid();
  return r;
end $$;

revoke all on function public.rw_create_room(text,text) from public;
grant execute on function public.rw_create_room(text,text) to authenticated;

-- 8) Secure invite-code join. Limit a room/team to 2 members for roommate teams.
create or replace function public.rw_join_room(p_invite_code text)
returns public.rw_rooms
language plpgsql security definer set search_path=public
as $$
declare
  r public.rw_rooms;
  my_residence uuid;
  member_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.rw_room_members where user_id=auth.uid()) then
    raise exception 'You already belong to a room/team';
  end if;

  select residence_id into my_residence from public.profiles where id=auth.uid();

  select * into r from public.rw_rooms
  where upper(invite_code)=upper(trim(p_invite_code))
  for update;

  if r.id is null then raise exception 'Invalid room invite code'; end if;
  if r.residence_id is distinct from my_residence then raise exception 'This room belongs to another residence'; end if;

  select count(*) into member_count from public.rw_room_members where room_id=r.id;
  if member_count >= 2 then raise exception 'This room/team already has two members'; end if;

  insert into public.rw_room_members(room_id,user_id) values(r.id,auth.uid());
  update public.profiles set room_id=r.id where id=auth.uid();
  return r;
end $$;

revoke all on function public.rw_join_room(text) from public;
grant execute on function public.rw_join_room(text) to authenticated;

-- 9) Room owner can update team identity through RPC.
create or replace function public.rw_update_team(p_team_name text, p_team_logo_url text default null)
returns void
language plpgsql security definer set search_path=public
as $$
declare rid uuid;
begin
  select room_id into rid from public.rw_room_members where user_id=auth.uid();
  if rid is null then raise exception 'You are not in a room/team'; end if;

  update public.rw_rooms
  set team_name=nullif(trim(coalesce(p_team_name,'')),''),
      team_logo_url=nullif(trim(coalesce(p_team_logo_url,'')),''),
      updated_at=now()
  where id=rid and (created_by=auth.uid() or exists(
    select 1 from public.rw_room_members where room_id=rid and user_id=auth.uid()
  ));
end $$;

revoke all on function public.rw_update_team(text,text) from public;
grant execute on function public.rw_update_team(text,text) to authenticated;

-- 10) Leave team. Creator cannot abandon a teammate; teammate may leave.
create or replace function public.rw_leave_room()
returns void
language plpgsql security definer set search_path=public
as $$
declare rid uuid; owner_id uuid; members integer;
begin
  select room_id into rid from public.rw_room_members where user_id=auth.uid();
  if rid is null then return; end if;
  select created_by into owner_id from public.rw_rooms where id=rid;
  select count(*) into members from public.rw_room_members where room_id=rid;

  if owner_id=auth.uid() and members>1 then
    raise exception 'Your roommate must leave before you can delete this room/team';
  end if;

  delete from public.rw_room_members where room_id=rid and user_id=auth.uid();
  update public.profiles set room_id=null where id=auth.uid();

  if not exists(select 1 from public.rw_room_members where room_id=rid) then
    delete from public.rw_rooms where id=rid;
  end if;
end $$;

revoke all on function public.rw_leave_room() from public;
grant execute on function public.rw_leave_room() to authenticated;

-- 11) Recalculate room totals from member profiles.
create or replace function public.rw_refresh_room_totals(p_room uuid)
returns void
language plpgsql security definer set search_path=public
as $$
begin
  update public.rw_rooms r set
    total_xp=coalesce((select sum(p.xp) from public.rw_room_members m join public.profiles p on p.id=m.user_id where m.room_id=r.id),0),
    wins=coalesce((select sum(p.wins) from public.rw_room_members m join public.profiles p on p.id=m.user_id where m.room_id=r.id),0),
    updated_at=now()
  where r.id=p_room;
end $$;

revoke all on function public.rw_refresh_room_totals(uuid) from public;
grant execute on function public.rw_refresh_room_totals(uuid) to authenticated;

-- 12) Realtime.
do $$ begin
  begin alter publication supabase_realtime add table public.rw_rooms; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.rw_room_members; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.rw_user_achievements; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.rw_game_history; exception when duplicate_object then null; end;
end $$;

select 'RES WARS PROFILE + ROOM/TEAM SYSTEM READY' as result;


-- ============================================================
-- 13) PROFILE PICTURE STORAGE
-- Residents upload real image files from profile.html.
-- ============================================================
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('avatars','avatars',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public=true,
  file_size_limit=5242880,
  allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "rw_avatar_upload_own" on storage.objects;
drop policy if exists "rw_avatar_update_own" on storage.objects;
drop policy if exists "rw_avatar_delete_own" on storage.objects;

create policy "rw_avatar_upload_own"
on storage.objects for insert to authenticated
with check (
  bucket_id='avatars'
  and (storage.foldername(name))[1]=auth.uid()::text
);

create policy "rw_avatar_update_own"
on storage.objects for update to authenticated
using (
  bucket_id='avatars'
  and (storage.foldername(name))[1]=auth.uid()::text
)
with check (
  bucket_id='avatars'
  and (storage.foldername(name))[1]=auth.uid()::text
);

create policy "rw_avatar_delete_own"
on storage.objects for delete to authenticated
using (
  bucket_id='avatars'
  and (storage.foldername(name))[1]=auth.uid()::text
);


-- ===== SOURCE: progression-engine.sql =====
-- RES WARS SECURE PROGRESSION ENGINE
-- Run once in Supabase SQL Editor.

alter table public.profiles add column if not exists xp integer not null default 0;
alter table public.profiles add column if not exists wins integer not null default 0;
alter table public.profiles add column if not exists games_played integer not null default 0;

create table if not exists public.rw_game_history(
 id uuid primary key default gen_random_uuid(),
 session_key text not null,
 game_slug text not null,
 user_id uuid not null references auth.users(id) on delete cascade,
 room_id uuid references public.rw_rooms(id) on delete set null,
 score integer not null default 0,
 xp_earned integer not null default 0,
 won boolean not null default false,
 played_at timestamptz not null default now(),
 unique(session_key,user_id)
);

create index if not exists rw_game_history_user_played
on public.rw_game_history(user_id,played_at desc);

alter table public.rw_game_history enable row level security;
drop policy if exists "rw_history_read" on public.rw_game_history;
create policy "rw_history_read" on public.rw_game_history
for select to authenticated using(true);

-- Result writes are ONLY through this RPC.
create or replace function public.rw_finish_game(
 p_session_key text,
 p_game_slug text,
 p_score integer default 0,
 p_won boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 uid uuid:=auth.uid();
 rid uuid;
 base_xp integer:=100;
 win_bonus integer:=0;
 earned integer;
 new_xp integer;
 new_wins integer;
 new_played integer;
 inserted_id uuid;
 aid uuid;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if trim(coalesce(p_session_key,''))='' then raise exception 'Session key required'; end if;
 if trim(coalesce(p_game_slug,''))='' then raise exception 'Game required'; end if;

 select room_id into rid from public.rw_room_members where user_id=uid limit 1;
 if p_won then win_bonus:=50; end if;
 earned:=base_xp+win_bonus;

 -- Idempotency: the same resident cannot claim the same game twice.
 insert into public.rw_game_history(session_key,game_slug,user_id,room_id,score,xp_earned,won)
 values(trim(p_session_key),lower(trim(p_game_slug)),uid,rid,greatest(coalesce(p_score,0),0),earned,coalesce(p_won,false))
 on conflict(session_key,user_id) do nothing
 returning id into inserted_id;

 if inserted_id is null then
   select xp,wins,games_played into new_xp,new_wins,new_played from public.profiles where id=uid;
   return jsonb_build_object('already_awarded',true,'xp',new_xp,'wins',new_wins,'games_played',new_played);
 end if;

 update public.profiles set
   xp=coalesce(xp,0)+earned,
   wins=coalesce(wins,0)+case when p_won then 1 else 0 end,
   games_played=coalesce(games_played,0)+1
 where id=uid
 returning xp,wins,games_played into new_xp,new_wins,new_played;

 -- Unlock achievements. Rewards listed on achievement cards are badges,
 -- not added again here, preventing recursive/double XP awards.
 if to_regclass('public.rw_achievements') is not null and to_regclass('public.rw_user_achievements') is not null then
   select id into aid from public.rw_achievements where slug='first-game';
   if aid is not null then insert into public.rw_user_achievements values(uid,aid,now()) on conflict do nothing; end if;

   if new_wins>=1 then
     select id into aid from public.rw_achievements where slug='first-win';
     if aid is not null then insert into public.rw_user_achievements values(uid,aid,now()) on conflict do nothing; end if;
   end if;
   if new_wins>=5 then
     select id into aid from public.rw_achievements where slug='five-wins';
     if aid is not null then insert into public.rw_user_achievements values(uid,aid,now()) on conflict do nothing; end if;
   end if;
   if new_played>=10 then
     select id into aid from public.rw_achievements where slug='ten-games';
     if aid is not null then insert into public.rw_user_achievements values(uid,aid,now()) on conflict do nothing; end if;
   end if;
   if new_xp>=1000 then
     select id into aid from public.rw_achievements where slug='xp-1000';
     if aid is not null then insert into public.rw_user_achievements values(uid,aid,now()) on conflict do nothing; end if;
   end if;
 end if;

 if rid is not null then perform public.rw_refresh_room_totals(rid); end if;

 return jsonb_build_object(
   'already_awarded',false,'xp_earned',earned,'xp',new_xp,
   'wins',new_wins,'games_played',new_played,'won',p_won
 );
end $$;

revoke all on function public.rw_finish_game(text,text,integer,boolean) from public;
grant execute on function public.rw_finish_game(text,text,integer,boolean) to authenticated;

do $$ begin
 begin alter publication supabase_realtime add table public.rw_game_history;
 exception when duplicate_object then null; end;
end $$;

select 'RES WARS progression ready' result;


-- ===== SOURCE: presence-invites.sql =====
-- ============================================================
-- RES WARS — LIVE PRESENCE + GAME INVITATIONS
-- Run in Supabase SQL Editor.
-- ============================================================

create table if not exists public.rw_presence (
  user_id uuid primary key references auth.users(id) on delete cascade,
  residence_id uuid,
  status text not null default 'online'
    check (status in ('online','away','playing','offline')),
  current_game text,
  current_session text,
  last_seen timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.rw_game_invites (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  residence_id uuid,
  game_slug text not null,
  game_name text not null,
  session_key text,
  status text not null default 'pending'
    check (status in ('pending','accepted','declined','cancelled','expired')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  expires_at timestamptz not null default (now()+interval '10 minutes'),
  check(sender_id<>recipient_id)
);

create index if not exists rw_invites_recipient_status
on public.rw_game_invites(recipient_id,status,created_at desc);

alter table public.rw_presence enable row level security;
alter table public.rw_game_invites enable row level security;

drop policy if exists "rw_presence_read" on public.rw_presence;
create policy "rw_presence_read" on public.rw_presence
for select to authenticated using(true);

drop policy if exists "rw_presence_self_insert" on public.rw_presence;
create policy "rw_presence_self_insert" on public.rw_presence
for insert to authenticated with check(user_id=auth.uid());

drop policy if exists "rw_presence_self_update" on public.rw_presence;
create policy "rw_presence_self_update" on public.rw_presence
for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

drop policy if exists "rw_invites_read_party" on public.rw_game_invites;
create policy "rw_invites_read_party" on public.rw_game_invites
for select to authenticated using(sender_id=auth.uid() or recipient_id=auth.uid());

-- Inserts/updates use RPCs, not direct browser writes.
create or replace function public.rw_set_presence(
 p_status text default 'online',
 p_game text default null,
 p_session text default null
) returns void language plpgsql security definer set search_path=public as $$
declare rid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_status not in ('online','away','playing','offline') then raise exception 'Invalid presence status'; end if;
 select residence_id into rid from public.profiles where id=auth.uid();
 insert into public.rw_presence(user_id,residence_id,status,current_game,current_session,last_seen,updated_at)
 values(auth.uid(),rid,p_status,p_game,p_session,now(),now())
 on conflict(user_id) do update set
 residence_id=excluded.residence_id,status=excluded.status,current_game=excluded.current_game,
 current_session=excluded.current_session,last_seen=now(),updated_at=now();
end $$;

create or replace function public.rw_send_game_invite(
 p_recipient uuid,p_game_slug text,p_game_name text,p_session_key text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare rid uuid; other_rid uuid; iid uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_recipient=auth.uid() then raise exception 'You cannot invite yourself'; end if;
 select residence_id into rid from public.profiles where id=auth.uid();
 select residence_id into other_rid from public.profiles where id=p_recipient;
 if other_rid is null then raise exception 'Resident not found'; end if;
 if rid is distinct from other_rid then raise exception 'You can only invite residents from your residence'; end if;

 update public.rw_game_invites set status='expired'
 where recipient_id=p_recipient and sender_id=auth.uid() and status='pending' and expires_at<=now();

 if exists(select 1 from public.rw_game_invites where recipient_id=p_recipient and sender_id=auth.uid()
   and status='pending' and expires_at>now()) then raise exception 'You already have a pending invite for this resident'; end if;

 insert into public.rw_game_invites(sender_id,recipient_id,residence_id,game_slug,game_name,session_key)
 values(auth.uid(),p_recipient,rid,trim(p_game_slug),trim(p_game_name),p_session_key)
 returning id into iid;
 return iid;
end $$;

create or replace function public.rw_respond_game_invite(
 p_invite uuid,p_accept boolean
) returns public.rw_game_invites language plpgsql security definer set search_path=public as $$
declare r public.rw_game_invites;
begin
 select * into r from public.rw_game_invites where id=p_invite for update;
 if r.id is null then raise exception 'Invite not found'; end if;
 if r.recipient_id<>auth.uid() then raise exception 'This invite is not yours'; end if;
 if r.status<>'pending' then return r; end if;
 if r.expires_at<=now() then
   update public.rw_game_invites set status='expired',responded_at=now() where id=r.id returning * into r;
   return r;
 end if;
 update public.rw_game_invites
 set status=case when p_accept then 'accepted' else 'declined' end,responded_at=now()
 where id=r.id returning * into r;
 return r;
end $$;

revoke all on function public.rw_set_presence(text,text,text) from public;
revoke all on function public.rw_send_game_invite(uuid,text,text,text) from public;
revoke all on function public.rw_respond_game_invite(uuid,boolean) from public;
grant execute on function public.rw_set_presence(text,text,text) to authenticated;
grant execute on function public.rw_send_game_invite(uuid,text,text,text) to authenticated;
grant execute on function public.rw_respond_game_invite(uuid,boolean) to authenticated;

do $$ begin
 begin alter publication supabase_realtime add table public.rw_presence; exception when duplicate_object then null; end;
 begin alter publication supabase_realtime add table public.rw_game_invites; exception when duplicate_object then null; end;
end $$;

select 'RES WARS LIVE PRESENCE + INVITES READY' result;


-- ===== SOURCE: invite-session-bridge.sql =====
-- RES WARS — INVITE -> SHARED SESSION BRIDGE
-- Run AFTER presence-invites.sql and your existing playable game SQL.

alter table public.rw_game_invites
  add column if not exists resolved_session_id uuid,
  add column if not exists resolved_at timestamptz;

create or replace function public.rw_resolve_spin_invite(p_invite uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare i public.rw_game_invites; s public.stb_sessions; me uuid:=auth.uid();
begin
 select * into i from public.rw_game_invites where id=p_invite for update;
 if i.id is null then raise exception 'Invite not found'; end if;
 if me<>i.sender_id and me<>i.recipient_id then raise exception 'Not part of this invite'; end if;
 if i.status not in ('pending','accepted') then raise exception 'Invite is not active'; end if;
 if i.expires_at<=now() then raise exception 'Invite expired'; end if;

 if i.resolved_session_id is null then
   if me<>i.sender_id then raise exception 'Waiting for host to open the game'; end if;
   select * into s from public.stb_host();
   update public.rw_game_invites set resolved_session_id=s.id,resolved_at=now() where id=i.id returning * into i;
 else
   select * into s from public.stb_sessions where id=i.resolved_session_id;
 end if;

 if not exists(select 1 from public.stb_players where session_id=s.id and user_id=me and active=true) then
   perform public.stb_join(s.code);
 end if;
 return jsonb_build_object('session_id',s.id,'code',s.code,'host_id',i.sender_id,'game','spin-the-bottle');
end $$;

create or replace function public.rw_resolve_game_invite(p_invite uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare i public.rw_game_invites; s public.rw_sessions; me uuid:=auth.uid(); gslug text;
begin
 select * into i from public.rw_game_invites where id=p_invite for update;
 if i.id is null then raise exception 'Invite not found'; end if;
 if me<>i.sender_id and me<>i.recipient_id then raise exception 'Not part of this invite'; end if;
 if i.status not in ('pending','accepted') then raise exception 'Invite is not active'; end if;
 if i.expires_at<=now() then raise exception 'Invite expired'; end if;
 gslug=case when i.game_slug in ('battle','res-wars-battle') then 'truth-dare' else i.game_slug end;

 if i.resolved_session_id is null then
   if me<>i.sender_id then raise exception 'Waiting for host to open the game'; end if;
   select * into s from public.rw_host(gslug);
   update public.rw_game_invites set resolved_session_id=s.id,resolved_at=now() where id=i.id returning * into i;
 else
   select * into s from public.rw_sessions where id=i.resolved_session_id;
 end if;

 if not exists(select 1 from public.rw_players where session_id=s.id and user_id=me) then
   perform public.rw_join(s.code);
 end if;
 return jsonb_build_object('session_id',s.id,'code',s.code,'host_id',i.sender_id,'game_slug',s.game_slug);
end $$;

revoke all on function public.rw_resolve_spin_invite(uuid) from public;
revoke all on function public.rw_resolve_game_invite(uuid) from public;
grant execute on function public.rw_resolve_spin_invite(uuid) to authenticated;
grant execute on function public.rw_resolve_game_invite(uuid) to authenticated;

select 'INVITE SESSION BRIDGE READY' result;


-- ===== SOURCE: ready-countdown.sql =====
-- ============================================================
-- RES WARS — READY + SYNCHRONIZED 5 SECOND START
-- Run AFTER the existing live-games / Spin the Bottle SQL.
-- ============================================================

alter table public.stb_players add column if not exists ready boolean not null default false;
alter table public.stb_sessions add column if not exists start_at timestamptz;

alter table public.rw_players add column if not exists ready boolean not null default false;
alter table public.rw_sessions add column if not exists start_at timestamptz;

create or replace function public.stb_set_ready(p_session uuid,p_ready boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 update public.stb_players set ready=coalesce(p_ready,false)
 where session_id=p_session and user_id=auth.uid() and active=true;
 if not found then raise exception 'You are not in this game'; end if;
end $$;

create or replace function public.stb_begin_ready_countdown(p_session uuid)
returns public.stb_sessions language plpgsql security definer set search_path=public as $$
declare s public.stb_sessions; total int; ready_count int;
begin
 select * into s from public.stb_sessions where id=p_session for update;
 if s.host_user_id<>auth.uid() then raise exception 'Only the host can start'; end if;
 if s.status<>'lobby' then return s; end if;
 select count(*),count(*) filter(where ready) into total,ready_count
 from public.stb_players where session_id=s.id and active=true;
 if total<2 then raise exception 'At least 2 players are required'; end if;
 if ready_count<>total then raise exception 'Everyone must be ready'; end if;
 update public.stb_sessions set start_at=now()+interval '5 seconds'
 where id=s.id returning * into s;
 return s;
end $$;

create or replace function public.stb_activate_after_countdown(p_session uuid)
returns public.stb_sessions language plpgsql security definer set search_path=public as $$
declare s public.stb_sessions;
begin
 select * into s from public.stb_sessions where id=p_session for update;
 if s.host_user_id<>auth.uid() then raise exception 'Only host can activate'; end if;
 if s.status='lobby' and s.start_at is not null and now()>=s.start_at then
   update public.stb_sessions set status='live',start_at=null where id=s.id returning * into s;
 end if;
 return s;
end $$;

create or replace function public.rw_set_ready(p_session uuid,p_ready boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 update public.rw_players set ready=coalesce(p_ready,false)
 where session_id=p_session and user_id=auth.uid();
 if not found then raise exception 'You are not in this game'; end if;
end $$;

create or replace function public.rw_begin_ready_countdown(p_session uuid)
returns public.rw_sessions language plpgsql security definer set search_path=public as $$
declare s public.rw_sessions; total int; ready_count int;
begin
 select * into s from public.rw_sessions where id=p_session for update;
 if s.host_user_id<>auth.uid() then raise exception 'Only the host can start'; end if;
 if s.status<>'lobby' then return s; end if;
 select count(*),count(*) filter(where ready) into total,ready_count
 from public.rw_players where session_id=s.id;
 if total<2 then raise exception 'At least 2 players are required'; end if;
 if ready_count<>total then raise exception 'Everyone must be ready'; end if;
 update public.rw_sessions set start_at=now()+interval '5 seconds'
 where id=s.id returning * into s;
 return s;
end $$;

create or replace function public.rw_activate_after_countdown(p_session uuid)
returns public.rw_sessions language plpgsql security definer set search_path=public as $$
declare s public.rw_sessions;
begin
 select * into s from public.rw_sessions where id=p_session for update;
 if s.host_user_id<>auth.uid() then raise exception 'Only host can activate'; end if;
 if s.status='lobby' and s.start_at is not null and now()>=s.start_at then
   -- Reuse the existing authoritative start function only after countdown.
   s:=public.rw_start(p_session);
 end if;
 return s;
end $$;

revoke all on function public.stb_set_ready(uuid,boolean) from public;
revoke all on function public.stb_begin_ready_countdown(uuid) from public;
revoke all on function public.stb_activate_after_countdown(uuid) from public;
revoke all on function public.rw_set_ready(uuid,boolean) from public;
revoke all on function public.rw_begin_ready_countdown(uuid) from public;
revoke all on function public.rw_activate_after_countdown(uuid) from public;
grant execute on function public.stb_set_ready(uuid,boolean) to authenticated;
grant execute on function public.stb_begin_ready_countdown(uuid) to authenticated;
grant execute on function public.stb_activate_after_countdown(uuid) to authenticated;
grant execute on function public.rw_set_ready(uuid,boolean) to authenticated;
grant execute on function public.rw_begin_ready_countdown(uuid) to authenticated;
grant execute on function public.rw_activate_after_countdown(uuid) to authenticated;

select 'READY + COUNTDOWN SYSTEM READY' result;


-- ===== SOURCE: final-gameplay-integration.sql =====
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
