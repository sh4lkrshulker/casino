create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique,
  display_name text not null,
  bio text not null default '',
  chips bigint not null default 1000 check (chips >= 0),
  stars integer not null default 300 check (stars >= 0),
  cases_opened integer not null default 0 check (cases_opened >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint username_format check (username ~ '^[a-z0-9_]{3,20}$'),
  constraint bio_length check (char_length(bio) <= 160),
  constraint display_name_length check (char_length(display_name) between 1 and 32)
);

alter table public.profiles add column if not exists stars integer not null default 300 check (stars >= 0);
alter table public.profiles add column if not exists cases_opened integer not null default 0 check (cases_opened >= 0);

create table if not exists public.duels (
  id uuid primary key default gen_random_uuid(),
  challenger_id uuid not null references public.profiles (id),
  opponent_id uuid not null references public.profiles (id),
  stake integer not null check (stake between 10 and 5000),
  status text not null default 'pending'
    check (status in ('pending', 'active', 'completed', 'cancelled')),
  winner_id uuid references public.profiles (id),
  challenger_pick text check (challenger_pick in ('rock', 'paper', 'scissors')),
  opponent_pick text check (opponent_pick in ('rock', 'paper', 'scissors')),
  challenger_ready boolean not null default false,
  opponent_ready boolean not null default false,
  created_at timestamptz not null default now(),
  constraint distinct_players check (challenger_id <> opponent_id)
);

alter table public.duels add column if not exists challenger_ready boolean not null default false;
alter table public.duels add column if not exists opponent_ready boolean not null default false;

create table if not exists public.duel_moves (
  duel_id uuid not null references public.duels (id) on delete cascade,
  player_id uuid not null references public.profiles (id),
  pick text not null check (pick in ('rock', 'paper', 'scissors')),
  created_at timestamptz not null default now(),
  primary key (duel_id, player_id)
);

create index if not exists duels_challenger_created_idx
  on public.duels (challenger_id, created_at desc);
create index if not exists duels_opponent_created_idx
  on public.duels (opponent_id, created_at desc);
create index if not exists profiles_leaderboard_idx
  on public.profiles (wins desc, chips desc);

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_username text := lower(new.raw_user_meta_data ->> 'username');
begin
  if requested_username is null or requested_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username must be 3-20 letters, numbers, or underscores';
  end if;

  insert into public.profiles (id, username, display_name)
  values (new.id, requested_username, requested_username);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.create_profile_for_new_user();

alter table public.profiles enable row level security;
alter table public.duels enable row level security;
alter table public.duel_moves enable row level security;

drop policy if exists "Profiles are readable by everyone" on public.profiles;
create policy "Profiles are readable by everyone"
  on public.profiles for select using (true);
drop policy if exists "Players update their editable profile fields" on public.profiles;
create policy "Players update their editable profile fields"
  on public.profiles for update to authenticated using (auth.uid() = id)
  with check (auth.uid() = id);

revoke update on public.profiles from anon, authenticated;
grant update (display_name, bio, last_seen_at) on public.profiles to authenticated;
grant select on public.profiles to anon, authenticated;

drop policy if exists "Players can read their own duels" on public.duels;
create policy "Players can read their own duels"
  on public.duels for select to authenticated
  using (auth.uid() = challenger_id or auth.uid() = opponent_id);
grant select on public.duels to authenticated;

drop policy if exists "Players can read their own secret moves" on public.duel_moves;
create policy "Players can read their own secret moves"
  on public.duel_moves for select to authenticated using (auth.uid() = player_id);
grant select on public.duel_moves to authenticated;
revoke insert, update, delete on public.duels, public.duel_moves from anon, authenticated;

create or replace function public.create_duel(target_username text, wager integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  target uuid;
  new_duel uuid;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  if wager is null or wager < 10 or wager > 5000 then raise exception 'Stake must be between 10 and 5000'; end if;

  select id into target from public.profiles where username = lower(target_username);
  if target is null then raise exception 'Player not found'; end if;
  if target = actor then raise exception 'You cannot challenge yourself'; end if;

  update public.profiles set chips = chips - wager
    where id = actor and chips >= wager;
  if not found then raise exception 'Not enough chips'; end if;

  insert into public.duels (challenger_id, opponent_id, stake)
    values (actor, target, wager) returning id into new_duel;
  return new_duel;
end;
$$;

create or replace function public.accept_duel(duel_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  selected public.duels%rowtype;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  select * into selected from public.duels where id = duel_id for update;
  if not found or selected.opponent_id <> actor or selected.status <> 'pending' then
    raise exception 'This duel is no longer available';
  end if;
  update public.profiles set chips = chips - selected.stake
    where id = actor and chips >= selected.stake;
  if not found then raise exception 'Not enough chips'; end if;
  update public.duels set status = 'active' where id = duel_id;
end;
$$;

create or replace function public.cancel_duel(duel_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  selected public.duels%rowtype;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  select * into selected from public.duels where id = duel_id for update;
  if not found or selected.challenger_id <> actor or selected.status <> 'pending' then
    raise exception 'This duel cannot be cancelled';
  end if;
  update public.duels set status = 'cancelled' where id = duel_id;
  update public.profiles set chips = chips + selected.stake where id = actor;
end;
$$;

create or replace function public.decline_duel(duel_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  selected public.duels%rowtype;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  select * into selected from public.duels where id = duel_id for update;
  if not found or selected.opponent_id <> actor or selected.status <> 'pending' then
    raise exception 'This duel cannot be declined';
  end if;
  update public.duels set status = 'cancelled' where id = duel_id;
  update public.profiles set chips = chips + selected.stake where id = selected.challenger_id;
end;
$$;

drop function if exists public.submit_duel_pick(uuid, text);
create function public.submit_duel_pick(p_duel_id uuid, p_player_pick text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  selected public.duels%rowtype;
  first_pick text;
  second_pick text;
  move_count integer;
  victor uuid;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  if p_player_pick not in ('rock', 'paper', 'scissors') then raise exception 'Invalid pick'; end if;

  select * into selected from public.duels where id = p_duel_id for update;
  if not found or selected.status <> 'active'
    or actor not in (selected.challenger_id, selected.opponent_id) then
    raise exception 'This duel is not available';
  end if;
  if exists (select 1 from public.duel_moves where duel_moves.duel_id = p_duel_id and player_id = actor) then
    raise exception 'You have already played this round';
  end if;

  insert into public.duel_moves (duel_id, player_id, pick)
    values (p_duel_id, actor, p_player_pick);

  if actor = selected.challenger_id then
    update public.duels set challenger_ready = true where id = p_duel_id;
  else
    update public.duels set opponent_ready = true where id = p_duel_id;
  end if;

  select count(*) into move_count from public.duel_moves where duel_moves.duel_id = p_duel_id;
  if move_count < 2 then return; end if;

  select pick into first_pick from public.duel_moves
    where duel_moves.duel_id = p_duel_id and player_id = selected.challenger_id;
  select pick into second_pick from public.duel_moves
    where duel_moves.duel_id = p_duel_id and player_id = selected.opponent_id;

  if first_pick = second_pick then
    update public.profiles set chips = chips + selected.stake where id in (selected.challenger_id, selected.opponent_id);
  else
    victor := case
      when (first_pick = 'rock' and second_pick = 'scissors')
        or (first_pick = 'paper' and second_pick = 'rock')
        or (first_pick = 'scissors' and second_pick = 'paper')
      then selected.challenger_id else selected.opponent_id end;
    update public.profiles set chips = chips + (selected.stake * 2) where id = victor;
    update public.profiles set wins = wins + 1 where id = victor;
    update public.profiles set losses = losses + 1 where id <> victor and id in (selected.challenger_id, selected.opponent_id);
  end if;

  update public.duels set
    status = 'completed',
    winner_id = victor,
    challenger_pick = first_pick,
    opponent_pick = second_pick,
    challenger_ready = true,
    opponent_ready = true
    where id = p_duel_id;
end;
$$;

revoke execute on function public.create_duel(text, integer) from public, anon;
revoke execute on function public.accept_duel(uuid) from public, anon;
revoke execute on function public.cancel_duel(uuid) from public, anon;
revoke execute on function public.decline_duel(uuid) from public, anon;
revoke execute on function public.submit_duel_pick(uuid, text) from public, anon;
grant execute on function public.create_duel(text, integer) to authenticated;
grant execute on function public.accept_duel(uuid) to authenticated;
grant execute on function public.cancel_duel(uuid) to authenticated;
grant execute on function public.decline_duel(uuid) to authenticated;
grant execute on function public.submit_duel_pick(uuid, text) to authenticated;

alter table public.duels replica identity full;
do $$
begin
  alter publication supabase_realtime add table public.duels;
exception when duplicate_object then null;
end;
$$;
