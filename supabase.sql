-- =====================================================================
-- Primez (primezo) database schema for Supabase  -  v3
-- Adds: referral codes, friends, study rooms with chat, leaderboard, notes and note sharing.
-- Run in: Supabase Dashboard > SQL Editor > New query > paste > Run
-- Safe to run more than once.
-- Every object Primez creates starts with "pz_", so it can share a Supabase
-- project with other apps without touching their tables, functions or triggers.
-- =====================================================================

-- ---------- Helper: random invite codes -------------------------------

create or replace function public.pz_new_code(p_len integer default 8)
returns text
language sql
volatile
as $$
  select upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, p_len));
$$;

-- ---------- Tables ----------------------------------------------------

create table if not exists public.pz_profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null default 'Learner' check (char_length(username) between 2 and 30),
  xp          integer not null default 0 check (xp >= 0),
  gems        integer not null default 0 check (gems >= 0),
  streak      integer not null default 0 check (streak >= 0),
  last_active date,
  created_at  timestamptz not null default now()
);

-- v2 columns
alter table public.pz_profiles add column if not exists referral_code  text unique;
alter table public.pz_profiles add column if not exists referred_by    uuid references public.pz_profiles (id) on delete set null;
alter table public.pz_profiles add column if not exists referral_count integer not null default 0;

update public.pz_profiles set referral_code = public.pz_new_code(8) where referral_code is null;

create table if not exists public.pz_lesson_progress (
  user_id            uuid not null references auth.users (id) on delete cascade,
  lesson_key         text not null check (lesson_key ~ '^u[1-9][0-9]*-[0-9]+$'),
  best_accuracy      smallint not null default 0 check (best_accuracy between 0 and 100),
  attempts           integer not null default 1 check (attempts >= 1),
  first_completed_at timestamptz not null default now(),
  last_completed_at  timestamptz not null default now(),
  primary key (user_id, lesson_key)
);

create table if not exists public.pz_daily_xp (
  user_id uuid not null references auth.users (id) on delete cascade,
  day     date not null,
  xp      integer not null default 0 check (xp >= 0),
  primary key (user_id, day)
);
create index if not exists pz_daily_xp_day_idx on public.pz_daily_xp (day);

create table if not exists public.pz_friendships (
  id         uuid primary key default gen_random_uuid(),
  requester  uuid not null references public.pz_profiles (id) on delete cascade,
  addressee  uuid not null references public.pz_profiles (id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists pz_friendships_pair_idx
  on public.pz_friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists pz_friendships_addressee_idx on public.pz_friendships (addressee);

create table if not exists public.pz_rooms (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null check (char_length(name) between 2 and 40),
  owner       uuid not null references public.pz_profiles (id) on delete cascade,
  weekly_goal integer not null default 300 check (weekly_goal between 50 and 5000),
  created_at  timestamptz not null default now()
);

create table if not exists public.pz_room_members (
  room_id   uuid not null references public.pz_rooms (id) on delete cascade,
  user_id   uuid not null references public.pz_profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists pz_room_members_user_idx on public.pz_room_members (user_id);

create table if not exists public.pz_room_messages (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.pz_rooms (id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.pz_profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists pz_room_messages_room_idx on public.pz_room_messages (room_id, id desc);

-- ---------- Membership helper (used by row level security) ------------

create or replace function public.pz_is_room_member(p_room uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.pz_room_members
     where room_id = p_room and user_id = (select auth.uid())
  );
$$;

-- ---------- Row level security ---------------------------------------

alter table public.pz_profiles        enable row level security;
alter table public.pz_lesson_progress enable row level security;
alter table public.pz_daily_xp        enable row level security;
alter table public.pz_friendships     enable row level security;
alter table public.pz_rooms           enable row level security;
alter table public.pz_room_members    enable row level security;
alter table public.pz_room_messages   enable row level security;

drop policy if exists "Read own profile"      on public.pz_profiles;
drop policy if exists "Update own profile"    on public.pz_profiles;
drop policy if exists "Read own progress"     on public.pz_lesson_progress;
drop policy if exists "Read own daily xp"     on public.pz_daily_xp;
drop policy if exists "Read own friendships"  on public.pz_friendships;
drop policy if exists "Members read rooms"    on public.pz_rooms;
drop policy if exists "Members read members"  on public.pz_room_members;
drop policy if exists "Members read messages" on public.pz_room_messages;
drop policy if exists "Members post messages" on public.pz_room_messages;

create policy "Read own profile" on public.pz_profiles
  for select to authenticated using (id = (select auth.uid()));

create policy "Update own profile" on public.pz_profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy "Read own progress" on public.pz_lesson_progress
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Read own daily xp" on public.pz_daily_xp
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Read own friendships" on public.pz_friendships
  for select to authenticated
  using (requester = (select auth.uid()) or addressee = (select auth.uid()));

create policy "Members read rooms" on public.pz_rooms
  for select to authenticated using (public.pz_is_room_member(id));

create policy "Members read members" on public.pz_room_members
  for select to authenticated using (public.pz_is_room_member(room_id));

create policy "Members read messages" on public.pz_room_messages
  for select to authenticated using (public.pz_is_room_member(room_id));

create policy "Members post messages" on public.pz_room_messages
  for insert to authenticated
  with check (user_id = (select auth.uid()) and public.pz_is_room_member(room_id));

-- Learners read their own data and can rename themselves. XP, gems, streak,
-- referrals, friends and rooms change only through the functions below, so
-- nobody can edit a score or join a room from the browser console.
revoke all on public.pz_profiles        from anon, authenticated;
revoke all on public.pz_lesson_progress from anon, authenticated;
revoke all on public.pz_daily_xp        from anon, authenticated;
revoke all on public.pz_friendships     from anon, authenticated;
revoke all on public.pz_rooms           from anon, authenticated;
revoke all on public.pz_room_members    from anon, authenticated;
revoke all on public.pz_room_messages   from anon, authenticated;

grant select                on public.pz_profiles        to authenticated;
grant update (username)     on public.pz_profiles        to authenticated;
grant select                on public.pz_lesson_progress to authenticated;
grant select                on public.pz_daily_xp        to authenticated;
grant select                on public.pz_friendships     to authenticated;
grant select                on public.pz_rooms           to authenticated;
grant select                on public.pz_room_members    to authenticated;
grant select, insert        on public.pz_room_messages   to authenticated;

-- Chat flood guard: one message per second per person.
create or replace function public.pz_check_message_rate()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1 from public.pz_room_messages
     where user_id = new.user_id and created_at > now() - interval '1 second'
  ) then
    raise exception 'Slow down a little';
  end if;
  return new;
end;
$$;

drop trigger if exists pz_room_messages_rate on public.pz_room_messages;
create trigger pz_room_messages_rate
  before insert on public.pz_room_messages
  for each row execute function public.pz_check_message_rate();

-- ---------- Referrals -------------------------------------------------
-- Both people get 50 gems. A person can be referred once. A code can reward
-- up to 50 sign-ups.

create or replace function public.pz_apply_referral(p_user uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ref    uuid;
  reward constant integer := 50;
begin
  if p_code is null or char_length(trim(p_code)) = 0 then
    return false;
  end if;

  select id into ref
    from public.pz_profiles
   where referral_code = upper(trim(p_code)) and referral_count < 50;

  if ref is null or ref = p_user then
    return false;
  end if;

  update public.pz_profiles
     set referred_by = ref, gems = gems + reward
   where id = p_user and referred_by is null;

  if not found then
    return false;
  end if;

  update public.pz_profiles
     set gems = gems + reward, referral_count = referral_count + 1
   where id = ref;

  return true;
end;
$$;

create or replace function public.pz_redeem_referral(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  return public.pz_apply_referral(auth.uid(), p_code);
end;
$$;

-- ---------- New account -> profile (+ referral) -----------------------

create or replace function public.pz_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  nm text;
begin
  nm := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Learner'
  );
  nm := left(nm, 30);
  if char_length(nm) < 2 then
    nm := 'Learner';
  end if;

  loop
    begin
      insert into public.pz_profiles (id, username, referral_code)
      values (new.id, nm, public.pz_new_code(8))
      on conflict (id) do nothing;
      exit;
    exception when unique_violation then
      null; -- invite code clash, try another
    end;
  end loop;

  begin
    perform public.pz_apply_referral(new.id, new.raw_user_meta_data ->> 'ref');
  exception when others then
    null; -- a bad code must never block sign-up
  end;

  return new;
end;
$$;

drop trigger if exists pz_on_auth_user_created on auth.users;
create trigger pz_on_auth_user_created
  after insert on auth.users
  for each row execute function public.pz_handle_new_user();

-- ---------- Finish a lesson ------------------------------------------
-- supabase.rpc('complete_lesson', { p_lesson_key: 'u1-0', p_xp: 50,
--   p_gems: 8, p_accuracy: 100 })       (day boundaries use UTC)

create or replace function public.pz_complete_lesson(
  p_lesson_key text,
  p_xp         integer,
  p_gems       integer,
  p_accuracy   integer
)
returns public.pz_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  uid        uuid := auth.uid();
  today      date := (now() at time zone 'utc')::date;
  first_time boolean;
  prof       public.pz_profiles;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if p_lesson_key !~ '^u[1-9][0-9]*-[0-9]+$' then
    raise exception 'Invalid lesson key';
  end if;
  if p_xp not between 0 and 50
     or p_gems not between 0 and 8
     or p_accuracy not between 0 and 100 then
    raise exception 'Invalid values';
  end if;

  insert into public.pz_profiles (id, referral_code)
  values (uid, public.pz_new_code(8))
  on conflict (id) do nothing;

  insert into public.pz_lesson_progress (user_id, lesson_key, best_accuracy)
  values (uid, p_lesson_key, p_accuracy)
  on conflict (user_id, lesson_key) do update
    set best_accuracy     = greatest(public.pz_lesson_progress.best_accuracy, excluded.best_accuracy),
        attempts          = public.pz_lesson_progress.attempts + 1,
        last_completed_at = now()
  returning (xmax = 0) into first_time;

  insert into public.pz_daily_xp (user_id, day, xp)
  values (uid, today, p_xp)
  on conflict (user_id, day) do update
    set xp = public.pz_daily_xp.xp + excluded.xp;

  update public.pz_profiles
     set xp     = xp + p_xp,
         gems   = gems + case when first_time then p_gems else 0 end,
         streak = case
                    when last_active = today     then streak
                    when last_active = today - 1 then streak + 1
                    else 1
                  end,
         last_active = today
   where id = uid
   returning * into prof;

  return prof;
end;
$$;

-- ---------- Leaderboard (top 20, last 7 days) ------------------------

drop function if exists public.pz_weekly_leaderboard();

create or replace function public.pz_weekly_leaderboard()
returns table (user_id uuid, username text, xp bigint)
language sql
security definer
stable
set search_path = public
as $$
  select p.id, p.username, sum(d.xp)::bigint
    from public.pz_daily_xp d
    join public.pz_profiles p on p.id = d.user_id
   where d.day > (now() at time zone 'utc')::date - 7
   group by p.id, p.username
   order by 3 desc
   limit 20;
$$;

-- ---------- Friends ---------------------------------------------------
-- Friends find each other with the invite code shown in the Study tab.

create or replace function public.pz_request_friend(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me       uuid := auth.uid();
  other    uuid;
  existing public.pz_friendships;
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  select id into other from public.pz_profiles where referral_code = upper(trim(p_code));
  if other is null then
    raise exception 'No learner found with that code';
  end if;
  if other = me then
    raise exception 'That is your own code';
  end if;

  select * into existing
    from public.pz_friendships
   where (requester = me and addressee = other) or (requester = other and addressee = me);

  if found then
    if existing.status = 'accepted' then
      return 'already_friends';
    end if;
    if existing.addressee = me then
      update public.pz_friendships set status = 'accepted' where id = existing.id;
      return 'accepted';
    end if;
    return 'already_sent';
  end if;

  if (select count(*) from public.pz_friendships where requester = me and status = 'pending') >= 20 then
    raise exception 'You have too many pending requests';
  end if;

  insert into public.pz_friendships (requester, addressee) values (me, other);
  return 'sent';
end;
$$;

create or replace function public.pz_answer_friend(p_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if p_accept then
    update public.pz_friendships set status = 'accepted'
     where id = p_id and addressee = me and status = 'pending';
  else
    delete from public.pz_friendships
     where id = p_id and addressee = me and status = 'pending';
  end if;
end;
$$;

create or replace function public.pz_remove_friend(p_other uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  delete from public.pz_friendships
   where ((requester = me and addressee = p_other) or (requester = p_other and addressee = me))
     and (status = 'accepted' or requester = me);
end;
$$;

create or replace function public.pz_list_friends()
returns table (
  req_id      uuid,
  user_id     uuid,
  username    text,
  state       text,
  week_xp     bigint,
  streak      integer,
  last_active date
)
language sql
security definer
stable
set search_path = public
as $$
  select f.id,
         p.id,
         p.username,
         case when f.status = 'accepted' then 'friend'
              when f.addressee = (select auth.uid()) then 'incoming'
              else 'outgoing' end,
         case when f.status = 'accepted'
              then coalesce((select sum(d.xp) from public.pz_daily_xp d
                              where d.user_id = p.id
                                and d.day > (now() at time zone 'utc')::date - 7), 0)::bigint
              else 0::bigint end,
         case when f.status = 'accepted' then p.streak else 0 end,
         case when f.status = 'accepted' then p.last_active else null end
    from public.pz_friendships f
    join public.pz_profiles p
      on p.id = case when f.requester = (select auth.uid()) then f.addressee else f.requester end
   where f.requester = (select auth.uid()) or f.addressee = (select auth.uid())
   order by f.created_at desc;
$$;

-- ---------- Study rooms ----------------------------------------------

create or replace function public.pz_create_room(p_name text, p_goal integer default 300)
returns public.pz_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  nm text := trim(p_name);
  rm public.pz_rooms;
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if char_length(nm) not between 2 and 40 then
    raise exception 'Room name needs 2 to 40 characters';
  end if;
  if p_goal not between 50 and 5000 then
    raise exception 'Goal must be between 50 and 5000 XP';
  end if;
  if (select count(*) from public.pz_room_members where user_id = me) >= 10 then
    raise exception 'You can be in up to 10 rooms';
  end if;

  loop
    begin
      insert into public.pz_rooms (code, name, owner, weekly_goal)
      values (public.pz_new_code(10), nm, me, p_goal)
      returning * into rm;
      exit;
    exception when unique_violation then
      null; -- code clash, try another
    end;
  end loop;

  insert into public.pz_room_members (room_id, user_id) values (rm.id, me);
  return rm;
end;
$$;

create or replace function public.pz_join_room(p_code text)
returns public.pz_rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  me     uuid := auth.uid();
  rm     public.pz_rooms;
  inside boolean;
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  select * into rm from public.pz_rooms where code = upper(trim(p_code));
  if not found then
    raise exception 'No room with that code';
  end if;

  select exists (select 1 from public.pz_room_members where room_id = rm.id and user_id = me) into inside;

  if not inside then
    if (select count(*) from public.pz_room_members where room_id = rm.id) >= 20 then
      raise exception 'This room is full';
    end if;
    if (select count(*) from public.pz_room_members where user_id = me) >= 10 then
      raise exception 'You can be in up to 10 rooms';
    end if;
    insert into public.pz_room_members (room_id, user_id) values (rm.id, me);
  end if;

  return rm;
end;
$$;

create or replace function public.pz_leave_room(p_room uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me  uuid := auth.uid();
  nxt uuid;
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  delete from public.pz_room_members where room_id = p_room and user_id = me;
  if not found then
    return;
  end if;

  select user_id into nxt from public.pz_room_members
   where room_id = p_room order by joined_at limit 1;

  if nxt is null then
    delete from public.pz_rooms where id = p_room;
  else
    update public.pz_rooms set owner = nxt where id = p_room and owner = me;
  end if;
end;
$$;

create or replace function public.pz_my_rooms()
returns table (
  id           uuid,
  code         text,
  name         text,
  weekly_goal  integer,
  member_count integer,
  week_xp      bigint
)
language sql
security definer
stable
set search_path = public
as $$
  select r.id, r.code, r.name, r.weekly_goal,
         (select count(*)::int from public.pz_room_members m2 where m2.room_id = r.id),
         coalesce((select sum(d.xp)
                     from public.pz_room_members m3
                     join public.pz_daily_xp d on d.user_id = m3.user_id
                    where m3.room_id = r.id
                      and d.day > (now() at time zone 'utc')::date - 7), 0)::bigint
    from public.pz_rooms r
    join public.pz_room_members m on m.room_id = r.id and m.user_id = (select auth.uid())
   order by r.created_at desc;
$$;

create or replace function public.pz_room_board(p_room uuid)
returns table (
  room_id     uuid,
  name        text,
  code        text,
  weekly_goal integer,
  user_id     uuid,
  username    text,
  week_xp     bigint,
  streak      integer,
  is_owner    boolean
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.pz_is_room_member(p_room) then
    raise exception 'You are not in this room';
  end if;

  return query
  select r.id, r.name, r.code, r.weekly_goal, p.id, p.username,
         coalesce((select sum(d.xp) from public.pz_daily_xp d
                    where d.user_id = p.id
                      and d.day > (now() at time zone 'utc')::date - 7), 0)::bigint,
         p.streak,
         (p.id = r.owner)
    from public.pz_rooms r
    join public.pz_room_members m on m.room_id = r.id
    join public.pz_profiles p on p.id = m.user_id
   where r.id = p_room
   order by 7 desc;
end;
$$;

-- ---------- Who may call what ----------------------------------------

revoke all on function public.pz_handle_new_user()       from public, anon, authenticated;
revoke all on function public.pz_apply_referral(uuid, text) from public, anon, authenticated;
revoke all on function public.pz_check_message_rate()    from public, anon, authenticated;

revoke all on function public.pz_redeem_referral(text)                         from public, anon;
revoke all on function public.pz_complete_lesson(text, integer, integer, integer) from public, anon;
revoke all on function public.pz_weekly_leaderboard()                          from public, anon;
revoke all on function public.pz_request_friend(text)                          from public, anon;
revoke all on function public.pz_answer_friend(uuid, boolean)                  from public, anon;
revoke all on function public.pz_remove_friend(uuid)                           from public, anon;
revoke all on function public.pz_list_friends()                                from public, anon;
revoke all on function public.pz_create_room(text, integer)                    from public, anon;
revoke all on function public.pz_join_room(text)                               from public, anon;
revoke all on function public.pz_leave_room(uuid)                              from public, anon;
revoke all on function public.pz_my_rooms()                                    from public, anon;
revoke all on function public.pz_room_board(uuid)                             from public, anon;
revoke all on function public.pz_is_room_member(uuid)                          from public, anon;

grant execute on function public.pz_redeem_referral(text)                         to authenticated;
grant execute on function public.pz_complete_lesson(text, integer, integer, integer) to authenticated;
grant execute on function public.pz_weekly_leaderboard()                          to authenticated;
grant execute on function public.pz_request_friend(text)                          to authenticated;
grant execute on function public.pz_answer_friend(uuid, boolean)                  to authenticated;
grant execute on function public.pz_remove_friend(uuid)                           to authenticated;
grant execute on function public.pz_list_friends()                                to authenticated;
grant execute on function public.pz_create_room(text, integer)                    to authenticated;
grant execute on function public.pz_join_room(text)                               to authenticated;
grant execute on function public.pz_leave_room(uuid)                              to authenticated;
grant execute on function public.pz_my_rooms()                                    to authenticated;
grant execute on function public.pz_room_board(uuid)                             to authenticated;
grant execute on function public.pz_is_room_member(uuid)                          to authenticated;

-- ---------- Notes and sharing (v3) ------------------------------------
-- Personal notes, optional public share links, and notes shared into study rooms.

create table if not exists public.pz_notes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.pz_profiles (id) on delete cascade,
  title       text not null default '' check (char_length(title) <= 120),
  body        text not null default '' check (char_length(body) <= 20000),
  tags        text[] not null default '{}' check (cardinality(tags) <= 6),
  pinned      boolean not null default false,
  lesson_key  text check (lesson_key is null or lesson_key ~ '^u[1-9][0-9]*-[0-9]+$'),
  share_token text unique,
  is_public   boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists pz_notes_user_idx on public.pz_notes (user_id, updated_at desc);

create table if not exists public.pz_room_notes (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.pz_rooms (id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.pz_profiles (id) on delete cascade,
  title      text not null default '' check (char_length(title) <= 120),
  body       text not null default '' check (char_length(body) <= 20000),
  created_at timestamptz not null default now()
);
create index if not exists pz_room_notes_room_idx on public.pz_room_notes (room_id, created_at desc);

alter table public.pz_notes      enable row level security;
alter table public.pz_room_notes enable row level security;

drop policy if exists "Own notes read"        on public.pz_notes;
drop policy if exists "Own notes insert"      on public.pz_notes;
drop policy if exists "Own notes update"      on public.pz_notes;
drop policy if exists "Own notes delete"      on public.pz_notes;
drop policy if exists "Members read room notes"  on public.pz_room_notes;
drop policy if exists "Members add room notes"   on public.pz_room_notes;
drop policy if exists "Authors delete room notes" on public.pz_room_notes;

create policy "Own notes read" on public.pz_notes
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Own notes insert" on public.pz_notes
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Own notes update" on public.pz_notes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
create policy "Own notes delete" on public.pz_notes
  for delete to authenticated using (user_id = (select auth.uid()));

create policy "Members read room notes" on public.pz_room_notes
  for select to authenticated using (public.pz_is_room_member(room_id));
create policy "Members add room notes" on public.pz_room_notes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and public.pz_is_room_member(room_id));
create policy "Authors delete room notes" on public.pz_room_notes
  for delete to authenticated using (user_id = (select auth.uid()));

revoke all on public.pz_notes      from anon, authenticated;
revoke all on public.pz_room_notes from anon, authenticated;
grant select, delete on public.pz_notes to authenticated;
grant insert (title, body, tags, pinned, lesson_key) on public.pz_notes to authenticated;
grant update (title, body, tags, pinned, lesson_key) on public.pz_notes to authenticated;
grant select, delete on public.pz_room_notes to authenticated;
grant insert (room_id, title, body) on public.pz_room_notes to authenticated;

-- Keep updated_at honest and cap how many notes one person can store.
create or replace function public.pz_notes_touch()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.pz_notes where user_id = new.user_id) >= 500 then
      raise exception 'You can keep up to 500 notes';
    end if;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists pz_notes_touch_trg on public.pz_notes;
create trigger pz_notes_touch_trg
  before insert or update on public.pz_notes
  for each row execute function public.pz_notes_touch();

-- Turn a public link on or off. Returns the token while sharing, null when off.
create or replace function public.pz_share_note(p_id uuid, p_on boolean)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me  uuid := auth.uid();
  tok text;
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  if p_on then
    update public.pz_notes
       set is_public   = true,
           share_token = coalesce(share_token, substr(replace(gen_random_uuid()::text, '-', ''), 1, 16))
     where id = p_id and user_id = me
     returning share_token into tok;
    if tok is null then
      raise exception 'Note not found';
    end if;
    return tok;
  end if;

  update public.pz_notes set is_public = false where id = p_id and user_id = me;
  return null;
end;
$$;

-- Anyone with the link can read a shared note (no login needed).
create or replace function public.pz_get_shared_note(p_token text)
returns table (title text, body text, author text, updated_at timestamptz)
language sql
security definer
stable
set search_path = public
as $$
  select n.title, n.body, p.username, n.updated_at
    from public.pz_notes n
    join public.pz_profiles p on p.id = n.user_id
   where n.share_token = p_token and n.is_public = true;
$$;

revoke all on function public.pz_notes_touch() from public, anon, authenticated;
revoke all on function public.pz_share_note(uuid, boolean) from public, anon;
revoke all on function public.pz_get_shared_note(text)     from public;
grant execute on function public.pz_share_note(uuid, boolean) to authenticated;
grant execute on function public.pz_get_shared_note(text)     to anon, authenticated;

-- ---------- Also do these in the dashboard ----------------------------
-- Authentication > Providers > Email: on
-- Authentication > Providers > Google: add your Google client ID and secret
-- Authentication > URL Configuration: add your site address to the redirect list
-- Optional live chat: uncomment the next line, then switch the app from
-- polling to realtime if you want instant messages.
-- alter publication supabase_realtime add table public.pz_room_messages;
