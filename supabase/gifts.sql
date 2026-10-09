create table if not exists public.gift_inventory (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.profiles (id) on delete cascade,
  gift_key text not null,
  gift_name text not null,
  gift_emoji text not null,
  rarity text not null check (rarity in ('common', 'rare', 'epic', 'legendary')),
  case_key text not null check (case_key in ('stardust', 'moon', 'orbit')),
  created_at timestamptz not null default now()
);

create index if not exists gift_inventory_player_created_idx
  on public.gift_inventory (player_id, created_at desc);

create table if not exists public.reward_claims (
  player_id uuid not null references public.profiles (id) on delete cascade,
  reward_key text not null,
  claimed_on date not null,
  primary key (player_id, reward_key, claimed_on)
);

alter table public.gift_inventory enable row level security;
alter table public.reward_claims enable row level security;

drop policy if exists "Players can read their own gift collection" on public.gift_inventory;
create policy "Players can read their own gift collection"
  on public.gift_inventory for select to authenticated using (auth.uid() = player_id);
drop policy if exists "Players can read their own reward claims" on public.reward_claims;
create policy "Players can read their own reward claims"
  on public.reward_claims for select to authenticated using (auth.uid() = player_id);

grant select on public.gift_inventory, public.reward_claims to authenticated;
revoke insert, update, delete on public.gift_inventory, public.reward_claims from anon, authenticated;

create or replace function public.open_gift_case(p_case_key text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  price integer;
  roll double precision := random();
  chosen_rarity text;
  chosen_key text;
  chosen_name text;
  chosen_emoji text;
  new_gift uuid;
begin
  if actor is null then raise exception 'Sign in required'; end if;

  price := case p_case_key
    when 'stardust' then 45
    when 'moon' then 120
    when 'orbit' then 280
    else null
  end;
  if price is null then raise exception 'Unknown case'; end if;

  update public.profiles
    set stars = stars - price, cases_opened = cases_opened + 1
    where id = actor and stars >= price;
  if not found then raise exception 'Not enough Stars'; end if;

  chosen_rarity := case p_case_key
    when 'stardust' then case when roll < 0.68 then 'common' when roll < 0.91 then 'rare' when roll < 0.99 then 'epic' else 'legendary' end
    when 'moon' then case when roll < 0.42 then 'common' when roll < 0.78 then 'rare' when roll < 0.97 then 'epic' else 'legendary' end
    when 'orbit' then case when roll < 0.20 then 'common' when roll < 0.58 then 'rare' when roll < 0.93 then 'epic' else 'legendary' end
  end;

  select item.gift_key, item.gift_name, item.gift_emoji
    into chosen_key, chosen_name, chosen_emoji
    from (values
      ('rose', 'Алая роза', '🌹', 'common'),
      ('cookie', 'Счастливое печенье', '🍪', 'common'),
      ('heart', 'Золотое сердце', '💝', 'common'),
      ('tulip', 'Весенний тюльпан', '🌷', 'common'),
      ('duck', 'Космическая уточка', '🦆', 'rare'),
      ('bunny', 'Лунный зайка', '🐰', 'rare'),
      ('crystal', 'Кристальная сфера', '🔮', 'rare'),
      ('rocket', 'Ракета желаний', '🚀', 'epic'),
      ('trophy', 'Кубок созвездий', '🏆', 'epic'),
      ('phoenix', 'Феникс удачи', '🦚', 'legendary')
    ) as item(gift_key, gift_name, gift_emoji, rarity)
    where item.rarity = chosen_rarity
    order by random()
    limit 1;

  insert into public.gift_inventory (player_id, gift_key, gift_name, gift_emoji, rarity, case_key)
    values (actor, chosen_key, chosen_name, chosen_emoji, chosen_rarity, p_case_key)
    returning id into new_gift;
  return new_gift;
end;
$$;

create or replace function public.claim_daily_stars()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  today date := (now() at time zone 'UTC')::date;
  reward integer := 60;
begin
  if actor is null then raise exception 'Sign in required'; end if;
  insert into public.reward_claims (player_id, reward_key, claimed_on)
    values (actor, 'daily', today);
  update public.profiles set stars = stars + reward where id = actor;
  return reward;
exception when unique_violation then
  raise exception 'Daily reward already claimed';
end;
$$;

create or replace function public.claim_gift_task(p_task_key text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  today date := (now() at time zone 'UTC')::date;
  reward integer;
  eligible boolean := false;
begin
  if actor is null then raise exception 'Sign in required'; end if;

  case p_task_key
    when 'first-case' then
      reward := 30;
      select cases_opened > 0 into eligible from public.profiles where id = actor;
    when 'little-collection' then
      reward := 75;
      select count(*) >= 3 into eligible from public.gift_inventory where player_id = actor;
    when 'bright-find' then
      reward := 100;
      select exists (
        select 1 from public.gift_inventory
          where player_id = actor and rarity <> 'common'
      ) into eligible;
    else raise exception 'Unknown task';
  end case;

  if not coalesce(eligible, false) then raise exception 'Task is not completed yet'; end if;

  insert into public.reward_claims (player_id, reward_key, claimed_on)
    values (actor, p_task_key, today);
  update public.profiles set stars = stars + reward where id = actor;
  return reward;
exception when unique_violation then
  raise exception 'Task reward already claimed';
end;
$$;

revoke execute on function public.open_gift_case(text) from public, anon;
revoke execute on function public.claim_daily_stars() from public, anon;
revoke execute on function public.claim_gift_task(text) from public, anon;
grant execute on function public.open_gift_case(text) to authenticated;
grant execute on function public.claim_daily_stars() to authenticated;
grant execute on function public.claim_gift_task(text) to authenticated;
