-- HANDCRIC initial Supabase schema: guest profiles, public/private rooms, invitations and authoritative 1v1 matches.
-- Run this in Supabase SQL Editor. Enable Anonymous Sign-Ins in Authentication > Providers first.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  created_at timestamptz not null default now()
);
create table if not exists public.rooms (
  code text primary key,
  mode text not null check (mode in ('1v1','2v2','1v1v1')),
  privacy text not null check (privacy in ('public','private')),
  host_id uuid not null references auth.users(id) on delete cascade,
  host_name text not null,
  status text not null default 'waiting' check (status in ('waiting','in_progress','completed','closed')),
  game_state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.room_players (
  room_code text not null references public.rooms(code) on delete cascade,
  player_id uuid not null references auth.users(id) on delete cascade,
  username text not null,
  joined_at timestamptz not null default now(),
  primary key(room_code, player_id)
);
create table if not exists public.room_choices (
  room_code text not null references public.rooms(code) on delete cascade,
  inning integer not null,
  ball_no integer not null,
  player_id uuid not null references auth.users(id) on delete cascade,
  choice integer not null check (choice between 1 and 10),
  created_at timestamptz not null default now(),
  primary key(room_code, inning, ball_no, player_id)
);
create table if not exists public.invitations (
  id uuid primary key default gen_random_uuid(),
  room_code text not null references public.rooms(code) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique(room_code, recipient_id)
);
create index if not exists rooms_public_waiting_idx on public.rooms(status, privacy, created_at desc);
create index if not exists room_players_lookup_idx on public.room_players(room_code, joined_at);
create index if not exists invitations_recipient_idx on public.invitations(recipient_id, status, created_at desc);

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.room_choices enable row level security;
alter table public.invitations enable row level security;

drop policy if exists "Profiles visible to signed-in guests" on public.profiles;
create policy "Profiles visible to signed-in guests" on public.profiles for select to authenticated using (true);
drop policy if exists "Players can insert own profile" on public.profiles;
create policy "Players can insert own profile" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "Players can update own profile" on public.profiles;
create policy "Players can update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists "Signed-in guests can read rooms" on public.rooms;
create policy "Signed-in guests can read rooms" on public.rooms for select to authenticated using (true);
drop policy if exists "Signed-in guests can read room players" on public.room_players;
create policy "Signed-in guests can read room players" on public.room_players for select to authenticated using (true);
-- Choices intentionally have no client SELECT policy: only security-definer RPCs can read them.
drop policy if exists "Users can read invitations involving them" on public.invitations;
create policy "Users can read invitations involving them" on public.invitations for select to authenticated using (sender_id = auth.uid() or recipient_id = auth.uid());

create or replace function public.create_room(p_mode text, p_privacy text, p_host_name text)
returns text language plpgsql security definer set search_path = public as $$
declare v_code text; v_username text;
begin
  if auth.uid() is null then raise exception 'Guest session missing. Refresh and try again.'; end if;
  if p_mode not in ('1v1','2v2','1v1v1') then raise exception 'Unsupported game mode.'; end if;
  if p_privacy not in ('public','private') then raise exception 'Invalid room visibility.'; end if;
  v_username := trim(p_host_name);
  if v_username !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'Username must be 3–20 letters, numbers, or underscores.'; end if;
  insert into public.profiles(id,username) values(auth.uid(),v_username)
    on conflict(id) do update set username=excluded.username;
  loop
    v_code := upper(substr(encode(gen_random_bytes(6),'hex'),1,6));
    exit when not exists(select 1 from public.rooms where code=v_code);
  end loop;
  insert into public.rooms(code,mode,privacy,host_id,host_name,status,game_state)
    values(v_code,p_mode,p_privacy,auth.uid(),v_username,'waiting','{}'::jsonb);
  insert into public.room_players(room_code,player_id,username) values(v_code,auth.uid(),v_username);
  return v_code;
end; $$;

create or replace function public.join_room(p_code text, p_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_room public.rooms%rowtype; v_count integer; v_limit integer; v_username text;
begin
  if auth.uid() is null then raise exception 'Guest session missing. Refresh and try again.'; end if;
  v_username := trim(p_username);
  if v_username !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'Username must be 3–20 letters, numbers, or underscores.'; end if;
  select * into v_room from public.rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if v_room.status in ('completed','closed') then raise exception 'This room is no longer active.'; end if;
  if v_room.privacy='private' and not exists(select 1 from public.invitations where room_code=v_room.code and recipient_id=auth.uid() and status='accepted') and v_room.host_id<>auth.uid() and not exists(select 1 from public.room_players where room_code=v_room.code and player_id=auth.uid()) then
    raise exception 'This is a private room. Ask the host to invite you by username.';
  end if;
  v_limit := case v_room.mode when '1v1' then 2 when '2v2' then 4 else 3 end;
  select count(*) into v_count from public.room_players where room_code=v_room.code;
  if not exists(select 1 from public.room_players where room_code=v_room.code and player_id=auth.uid()) then
    if v_room.status <> 'waiting' then raise exception 'This match has already started.'; end if;
    if v_count >= v_limit then raise exception 'This room is full.'; end if;
    insert into public.profiles(id,username) values(auth.uid(),v_username) on conflict(id) do update set username=excluded.username;
    insert into public.room_players(room_code,player_id,username) values(v_room.code,auth.uid(),v_username);
  end if;
  return jsonb_build_object('code',v_room.code,'mode',v_room.mode,'privacy',v_room.privacy,'host_id',v_room.host_id,'host_name',v_room.host_name,'status',v_room.status,'game_state',v_room.game_state,'created_at',v_room.created_at);
end; $$;

create or replace function public.invite_by_username(p_code text, p_username text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_room public.rooms%rowtype; v_recipient uuid; v_sender_name text; v_inv uuid;
begin
  select * into v_room from public.rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if v_room.host_id <> auth.uid() then raise exception 'Only the host can invite players.'; end if;
  if v_room.status <> 'waiting' then raise exception 'Invites are closed after a match starts.'; end if;
  select id into v_recipient from public.profiles where lower(username)=lower(trim(p_username));
  if v_recipient is null then raise exception 'No guest profile found with that username. Ask them to visit HANDCRIC first.'; end if;
  if v_recipient=auth.uid() then raise exception 'You cannot invite yourself.'; end if;
  select username into v_sender_name from public.profiles where id=auth.uid();
  insert into public.invitations(room_code,sender_id,recipient_id,sender_name,status)
    values(v_room.code,auth.uid(),v_recipient,coalesce(v_sender_name,v_room.host_name),'pending')
    on conflict(room_code,recipient_id) do update set sender_id=excluded.sender_id,sender_name=excluded.sender_name,status='pending',created_at=now(),responded_at=null
    returning id into v_inv;
  return v_inv;
end; $$;

create or replace function public.respond_invite(p_invite_id uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_inv public.invitations%rowtype; v_room public.rooms%rowtype; v_username text; v_count integer; v_limit integer;
begin
  select * into v_inv from public.invitations where id=p_invite_id and recipient_id=auth.uid() for update;
  if not found then raise exception 'Invitation not found.'; end if;
  if v_inv.status <> 'pending' then raise exception 'This invitation has already been answered.'; end if;
  if not p_accept then update public.invitations set status='declined',responded_at=now() where id=v_inv.id; return 'declined'; end if;
  select * into v_room from public.rooms where code=v_inv.room_code for update;
  if not found or v_room.status <> 'waiting' then raise exception 'That room is no longer accepting players.'; end if;
  v_limit := case v_room.mode when '1v1' then 2 when '2v2' then 4 else 3 end;
  select count(*) into v_count from public.room_players where room_code=v_room.code;
  if v_count >= v_limit then raise exception 'That room is full.'; end if;
  select username into v_username from public.profiles where id=auth.uid();
  insert into public.room_players(room_code,player_id,username) values(v_room.code,auth.uid(),v_username) on conflict do nothing;
  update public.invitations set status='accepted',responded_at=now() where id=v_inv.id;
  return v_room.code;
end; $$;

create or replace function public.start_match(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_room public.rooms%rowtype; v_players uuid[]; v_names text[]; v_batter uuid; v_state jsonb;
begin
  select * into v_room from public.rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if v_room.host_id<>auth.uid() then raise exception 'Only the host can start the match.'; end if;
  if v_room.status<>'waiting' then raise exception 'This room has already started.'; end if;
  if v_room.mode<>'1v1' then raise exception 'Online 2v2 and 1v1v1 are next; the first live backend build currently supports 1v1.'; end if;
  select array_agg(player_id order by joined_at), array_agg(username order by joined_at) into v_players,v_names from public.room_players where room_code=v_room.code;
  if coalesce(array_length(v_players,1),0)<>2 then raise exception 'A 1v1 match needs exactly two players.'; end if;
  v_batter := v_players[1 + floor(random()*2)::int];
  v_state := jsonb_build_object('phase','in_progress','inning',1,'score',0,'first_score',null,'balls',0,'total_balls',12,'wickets',0,'batter_id',v_batter,'target',null,'last_result','Match started. First batter selected by toss.','winner_id',null,'scores',jsonb_build_object(v_players[1]::text,0,v_players[2]::text,0));
  update public.rooms set status='in_progress',game_state=v_state,updated_at=now() where code=v_room.code;
  return v_state;
end; $$;

create or replace function public.submit_choice(p_code text, p_choice integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_room public.rooms%rowtype; v_state jsonb; v_inning int; v_ball int; v_batter uuid; v_players uuid[]; v_count int; v_bat_choice int; v_bowl_choice int; v_score int; v_wicket boolean; v_target int; v_first int; v_next_batter uuid; v_winner uuid; v_result text; v_scores jsonb; v_new_status text;
begin
  if p_choice < 1 or p_choice > 10 then raise exception 'Choose a number from 1 to 10.'; end if;
  select * into v_room from public.rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if v_room.status<>'in_progress' then raise exception 'The match is not accepting choices.'; end if;
  if not exists(select 1 from public.room_players where room_code=v_room.code and player_id=auth.uid()) then raise exception 'You are not in this room.'; end if;
  v_state := v_room.game_state; v_inning := (v_state->>'inning')::int; v_ball := (v_state->>'balls')::int; v_batter := (v_state->>'batter_id')::uuid;
  insert into public.room_choices(room_code,inning,ball_no,player_id,choice) values(v_room.code,v_inning,v_ball,auth.uid(),p_choice) on conflict do nothing;
  if not found then raise exception 'Your choice for this ball was already submitted.'; end if;
  select count(*) into v_count from public.room_choices where room_code=v_room.code and inning=v_inning and ball_no=v_ball;
  if v_count<2 then return jsonb_build_object('pending',true,'message','Choice locked. Waiting for the other player.'); end if;
  select array_agg(player_id order by joined_at) into v_players from public.room_players where room_code=v_room.code;
  select choice into v_bat_choice from public.room_choices where room_code=v_room.code and inning=v_inning and ball_no=v_ball and player_id=v_batter;
  select choice into v_bowl_choice from public.room_choices where room_code=v_room.code and inning=v_inning and ball_no=v_ball and player_id<>v_batter limit 1;
  v_wicket := v_bat_choice=v_bowl_choice;
  v_score := (v_state->>'score')::int + case when v_wicket then 0 else v_bat_choice end;
  v_ball := v_ball+1; v_target := nullif(v_state->>'target','')::int; v_first := nullif(v_state->>'first_score','')::int;
  v_scores := v_state->'scores';
  v_scores := jsonb_set(v_scores,array[v_batter::text],to_jsonb(v_score),true);
  v_result := case when v_wicket then 'WICKET! Both players chose '||v_bat_choice||'.' else 'Batter scored '||v_bat_choice||' runs; bowler chose '||v_bowl_choice||'.' end;
  delete from public.room_choices where room_code=v_room.code and inning=v_inning and ball_no=v_ball-1;
  if v_wicket or v_ball>=12 or (v_inning=2 and v_target is not null and v_score>=v_target) then
    if v_inning=1 then
      v_first:=v_score; v_next_batter:=v_players[case when v_batter=v_players[1] then 2 else 1 end];
      v_state:=jsonb_build_object('phase','in_progress','inning',2,'score',0,'first_score',v_first,'balls',0,'total_balls',12,'wickets',0,'batter_id',v_next_batter,'target',v_first+1,'last_result',v_result||' Innings over. Target: '||(v_first+1)||'.','winner_id',null,'scores',v_scores);
    else
      if v_score>=v_first+1 then v_winner:=v_batter; elsif v_score<v_first then v_winner:=v_players[case when v_batter=v_players[1] then 2 else 1 end]; else v_winner:=null; end if;
      v_state:=jsonb_build_object('phase','completed','inning',2,'score',v_score,'first_score',v_first,'balls',v_ball,'total_balls',12,'wickets',case when v_wicket then 1 else 0 end,'batter_id',v_batter,'target',v_first+1,'last_result',v_result,'winner_id',v_winner,'scores',v_scores);
      update public.rooms set status='completed',game_state=v_state,updated_at=now() where code=v_room.code;
      return v_state;
    end if;
  else
    v_state:=jsonb_set(v_state,'{score}',to_jsonb(v_score),true);
    v_state:=jsonb_set(v_state,'{balls}',to_jsonb(v_ball),true);
    v_state:=jsonb_set(v_state,'{wickets}',to_jsonb(case when v_wicket then 1 else 0 end),true);
    v_state:=jsonb_set(v_state,'{scores}',v_scores,true);
    v_state:=jsonb_set(v_state,'{last_result}',to_jsonb(v_result),true);
  end if;
  update public.rooms set game_state=v_state,updated_at=now() where code=v_room.code;
  return v_state;
end; $$;

-- Prevent clients from bypassing the RPC game rules with direct writes.
revoke insert, update, delete on public.rooms from anon, authenticated;
revoke insert, update, delete on public.room_players from anon, authenticated;
revoke insert, update, delete on public.room_choices from anon, authenticated;
revoke insert, update, delete on public.invitations from anon, authenticated;
grant select on public.profiles, public.rooms, public.room_players, public.invitations to authenticated;
grant insert, update on public.profiles to authenticated;
grant execute on function public.create_room(text,text,text) to authenticated;
grant execute on function public.join_room(text,text) to authenticated;
grant execute on function public.invite_by_username(text,text) to authenticated;
grant execute on function public.respond_invite(uuid,boolean) to authenticated;
grant execute on function public.start_match(text) to authenticated;
grant execute on function public.submit_choice(text,integer) to authenticated;

-- Enable Realtime events used by the room page. Safe to run if already included.
do $$ begin
  alter publication supabase_realtime add table public.rooms;
exception when duplicate_object then null; when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.room_players;
exception when duplicate_object then null; when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.invitations;
exception when duplicate_object then null; when others then null; end $$;
