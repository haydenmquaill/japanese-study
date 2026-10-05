-- ════════════════════════════════════════════════════════════════════════════
-- 001 — push notifications
--
-- Three notifications, each switchable in Settings → Notifications
-- (stored in user_settings.configuration.notifications):
--
--   stale alert   one-off, when your stale write count crosses `stale_threshold`.
--                 Edge-triggered: it fires on the way up and won't fire again until
--                 the count drops back under the threshold and climbs through it again.
--                 Waking hours only — a crossing at 3am is held until quiet_from.
--   stale nag     hourly while any stale items remain, inside waking hours only.
--   daily goal    at `goal_hour` local, if you've unlocked fewer than `daily_goal`
--                 new kanji today. Silent once you've hit the number.
--
-- How it's sent (same shape as JALF's ft-push):
--   js_push_subs      one row per device that turned notifications on
--   js_push_queue     messages waiting to go out
--   js_notify_tick()  decides what to queue — cron, every 15 minutes
--   js_push_flush()   pokes the js-push Edge Function, which claims the queue with
--                     js_push_claim(), signs each message (VAPID), sends it, and drops
--                     dead devices via js_push_drop().
--
-- This Supabase project is shared with the cooking planner, so every new object here
-- is prefixed js_. Nothing outside that prefix is modified except write_progress
-- (one new column) and upsert_write_progress (which sets it).
--
-- Requires pg_cron and pg_net — enable both first (Dashboard → Database → Extensions),
-- or the cron.schedule / net.http_post calls will fail.
--
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════

create extension if not exists pg_cron;
create extension if not exists pg_net;


-- ── when was an item first unlocked? ────────────────────────────────────────
-- write_progress stores only a snapshot: level, last_quizzed, updated_at. A kanji
-- unlocked today and one demoted back down months ago look identical (both level 1–2,
-- streak 0), and updated_at is bumped on every review — so "unlocked today" cannot be
-- derived from what is already here. Hence one new column.
--
-- It is written on INSERT only, never on conflict. A write_progress row is created the
-- first time an item is studied (saveWriteLevel only ever sends level >= 1, and nothing
-- demotes back to 0), so row creation *is* the unlock moment.
--
-- Rows that already exist keep NULL, meaning "unlocked before this was tracked". NULL
-- never counts toward today, so there is no fabricated history and no backfill.
alter table write_progress add column if not exists unlocked_at timestamptz;

create index if not exists write_progress_unlocked_at_idx
  on write_progress (user_id, unlocked_at) where unlocked_at is not null;

-- Unchanged from the live definition except the two unlocked_at lines flagged below.
create or replace function public.upsert_write_progress(
  p_item_id text, p_level integer, p_last_quizzed timestamptz, p_user_id uuid, p_threshold integer default 0)
returns integer language plpgsql as $function$
DECLARE
    v_threshold int := COALESCE(p_threshold, 0);
    v_current   int;
    v_streak    int;
    v_level     int;   -- level we will actually commit
    v_new_streak int;
BEGIN
    SELECT level, streak INTO v_current, v_streak
    FROM write_progress
    WHERE user_id = p_user_id AND item_id = p_item_id;

    IF v_current IS NULL THEN
        v_current := 0;
        v_streak  := 0;
    END IF;

    IF v_threshold >= 2 AND p_level > v_current THEN
        -- Gated rung: hold here and count up, release only at threshold.
        v_new_streak := v_streak + 1;
        IF v_new_streak >= v_threshold THEN
            v_level := p_level;      -- promote (rung change)
            v_new_streak := 0;       -- rung changed -> reset
        ELSE
            v_level := v_current;    -- stay put (same rung -> streak stands)
        END IF;
    ELSIF p_level = v_current THEN
        -- Same rung, not gated: generic increment.
        v_level := p_level;
        v_new_streak := v_streak + 1;
    ELSE
        -- Any other rung change (promotion elsewhere, or a lapse/drop): reset.
        v_level := p_level;
        v_new_streak := 0;
    END IF;

    INSERT INTO write_progress (user_id, item_id, level, last_quizzed, streak, updated_at, unlocked_at)
    VALUES (p_user_id, p_item_id, v_level, p_last_quizzed, v_new_streak, now(),
            CASE WHEN v_level >= 1 THEN now() END)            -- NEW: set on first study only
    ON CONFLICT (user_id, item_id)
    DO UPDATE SET
        level        = EXCLUDED.level,
        last_quizzed = EXCLUDED.last_quizzed,
        streak       = EXCLUDED.streak,
        updated_at   = now();
        -- NEW: deliberately no unlocked_at here — an existing row was unlocked earlier.

    RETURN v_level;
END;
$function$;


-- ── which items are kanji ───────────────────────────────────────────────────
-- items live in data/data.json, not in Postgres, so the database identifies kanji by id
-- prefix. These three prefixes are exactly the 3488 items whose category is "Kanji"
-- (joyo_ 2136 + jinmeiyo_ 862 + kanji_ext_ 490), matching the client's
-- WRITE_KANJI_CATS = Set(['Kanji']).
--
-- ⚠ If data.json ever adds kanji under a new id prefix, add it here too or these counts
--   will silently run low.
create or replace function js_is_kanji(p_item_id text) returns boolean
language sql immutable set search_path = public as $$
  select p_item_id ~ '^(joyo|jinmeiyo|kanji_ext)_';
$$;


-- ── local time ──────────────────────────────────────────────────────────────
-- AEST, fixed UTC+10 all year. Change to 'Australia/Sydney' to follow daylight saving.
create or replace function js_local_now() returns timestamp
language sql stable set search_path = public as $$
  select now() at time zone 'Australia/Brisbane';
$$;


-- ── settings, with defaults ─────────────────────────────────────────────────
-- Mirrors the client's defaults; anything the page has not written falls back here.
create or replace function js_notif_prefs(p_user uuid) returns jsonb
language sql stable set search_path = public as $$
  select '{"enabled":true,"stale_alert":true,"stale_threshold":10,"stale_nag":true,
           "quiet_from":7,"quiet_to":21,"goal_reminder":true,"daily_goal":10,"goal_hour":19}'::jsonb
         || coalesce((select configuration->'notifications' from user_settings where user_id = p_user), '{}'::jsonb);
$$;

-- Stale, exactly as the page counts it (getStaleCutoff): level >= 2, and either never
-- quizzed or last quizzed longer ago than that level's stale_days. Per-level days come
-- from the same user_settings.configuration the page writes, so the two cannot drift.
create or replace function js_write_stale_count(p_user uuid) returns int
language sql stable set search_path = public as $$
  with cfg as (
    select coalesce((select configuration->'stale_days'->'write' from user_settings where user_id = p_user), '{}'::jsonb) sd,
           '{"2":0.5,"3":1,"4":3,"5":7,"6":30}'::jsonb def
  )
  select count(*)::int
    from write_progress w, cfg
   where w.user_id = p_user
     and js_is_kanji(w.item_id)
     and w.level >= 2
     and (w.last_quizzed is null
          or w.last_quizzed < now() - (coalesce((cfg.sd->>w.level::text)::numeric,
                                                (cfg.def->>w.level::text)::numeric,
                                                1) * interval '1 day'));
$$;

-- New kanji unlocked today, in local time.
create or replace function js_unlocked_today(p_user uuid) returns int
language sql stable set search_path = public as $$
  select count(*)::int
    from write_progress
   where user_id = p_user
     and js_is_kanji(item_id)
     and unlocked_at is not null
     and (unlocked_at at time zone 'Australia/Brisbane')::date = js_local_now()::date;
$$;


-- ── plumbing: devices, queue, config ────────────────────────────────────────
create table if not exists js_push_subs (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists js_push_subs_user on js_push_subs (user_id);

create table if not exists js_push_queue (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  title      text not null,
  body       text not null default '',
  url        text not null default './',
  tag        text,                        -- same tag replaces the previous notification
  created_at timestamptz not null default now()
);

-- what has already been said, so nothing repeats itself
create table if not exists js_push_state (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  stale_alerted    boolean not null default false,  -- threshold alert sent, awaiting reset
  stale_nagged_at  timestamptz,                     -- last hourly nag
  goal_nudged_on   date                             -- local date the goal nudge went out
);

create table if not exists js_config (key text primary key, value text);
insert into js_config (key, value) values ('push_url', null), ('push_secret', null)
  on conflict (key) do nothing;

alter table js_push_subs  enable row level security;
alter table js_push_queue enable row level security;
alter table js_push_state enable row level security;
alter table js_config     enable row level security;   -- no policies: holds the shared secret
drop policy if exists js_push_subs_mine on js_push_subs;
create policy js_push_subs_mine on js_push_subs for select to authenticated using (user_id = auth.uid());


-- ── the page: this device on / off ──────────────────────────────────────────
create or replace function js_push_subscribe(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into js_push_subs (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function js_push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from js_push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- so you can check it works without waiting for the cron
create or replace function js_push_test() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into js_push_queue (user_id, title, body, url, tag)
  values (auth.uid(), '日本語辞典', 'Notifications are working.', './', 'test');
  perform js_push_flush();
end $$;


-- ── sending ─────────────────────────────────────────────────────────────────
create or replace function js_push_flush() returns void
language plpgsql set search_path = public as $$
declare v_url text; v_secret text;
begin
  delete from js_push_queue where created_at < now() - interval '1 hour';   -- nobody sending; don't pile up
  if not exists (select 1 from js_push_queue) then return; end if;
  select value into v_url    from js_config where key = 'push_url';
  select value into v_secret from js_config where key = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(v_url, '{}'::jsonb, '{}'::jsonb,
    jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret), 10000);
end $$;

-- for the Edge Function (service role): take messages, with each person's devices
create or replace function js_push_claim(p_limit int default 200)
returns table (id bigint, title text, body text, url text, tag text, subs jsonb)
language sql security definer set search_path = public as $$
  with taken as (
    delete from js_push_queue where id in (select id from js_push_queue order by id limit p_limit for update skip locked)
    returning *
  )
  select t.id, t.title, t.body, t.url, t.tag,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                     from js_push_subs s where s.user_id = t.user_id), '[]')
    from taken t order by t.id;
$$;

create or replace function js_push_drop(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from js_push_subs where endpoint = p_endpoint;
$$;


-- ── deciding what to send ───────────────────────────────────────────────────
create or replace function js_notify_tick() returns void
language plpgsql set search_path = public as $$
declare
  u record; p jsonb; v_stale int; v_unlocked int; v_goal int; v_threshold int;
  v_hour   int     := extract(hour from js_local_now())::int;
  v_today  date    := js_local_now()::date;
  v_waking boolean;
begin
  for u in select distinct user_id from js_push_subs loop
    begin
      p := js_notif_prefs(u.user_id);
      continue when not coalesce((p->>'enabled')::boolean, true);

      insert into js_push_state (user_id) values (u.user_id) on conflict (user_id) do nothing;

      v_stale     := js_write_stale_count(u.user_id);
      v_threshold := coalesce((p->>'stale_threshold')::int, 10);
      v_waking    := v_hour >= coalesce((p->>'quiet_from')::int, 7)
                 and v_hour <  coalesce((p->>'quiet_to')::int, 21);

      -- 1. crossed the threshold — once, until it drops back under.
      -- Held until waking hours: if it crosses at 3am the alert goes out at quiet_from,
      -- because stale_alerted is only set once the message is actually queued.
      if coalesce((p->>'stale_alert')::boolean, true)
         and v_stale >= v_threshold and v_waking
         and not (select stale_alerted from js_push_state where user_id = u.user_id) then
        insert into js_push_queue (user_id, title, body, url, tag)
        values (u.user_id, format('%s kanji have gone stale', v_stale),
                'Time for a write review.', './', 'stale');
        update js_push_state set stale_alerted = true, stale_nagged_at = now() where user_id = u.user_id;

      -- 2. hourly nag while any remain, waking hours only
      elsif coalesce((p->>'stale_nag')::boolean, true) and v_stale > 0 and v_waking
         and coalesce((select stale_nagged_at from js_push_state where user_id = u.user_id),
                      'epoch'::timestamptz) < now() - interval '1 hour' then
        insert into js_push_queue (user_id, title, body, url, tag)
        values (u.user_id, format('%s stale kanji waiting', v_stale),
                'Still to be reviewed.', './', 'stale');
        update js_push_state set stale_nagged_at = now() where user_id = u.user_id;
      end if;

      -- back under the threshold: re-arm the one-off alert
      if v_stale < v_threshold then
        update js_push_state set stale_alerted = false where user_id = u.user_id;
      end if;

      -- 3. the daily goal, at goal_hour local, once a day, only if short
      if coalesce((p->>'goal_reminder')::boolean, true)
         and v_hour >= coalesce((p->>'goal_hour')::int, 19)
         and coalesce((select goal_nudged_on from js_push_state where user_id = u.user_id), 'epoch'::date) < v_today then
        v_goal     := coalesce((p->>'daily_goal')::int, 10);
        v_unlocked := js_unlocked_today(u.user_id);
        if v_unlocked < v_goal then
          insert into js_push_queue (user_id, title, body, url, tag)
          values (u.user_id, format('%s of %s new kanji today', v_unlocked, v_goal),
                  'Still time to unlock a few more.', './', 'goal');
        end if;
        update js_push_state set goal_nudged_on = v_today where user_id = u.user_id;
      end if;
    exception when others then raise warning 'js_notify_tick (user %): %', u.user_id, sqlerrm;
    end;
  end loop;
  perform js_push_flush();
end $$;


-- ── who can call what ───────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array['js_push_subscribe(text,text,text)', 'js_push_unsubscribe(text)', 'js_push_test()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['js_push_claim(int)', 'js_push_drop(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  foreach f in array array['js_push_flush()', 'js_notify_tick()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;


-- ── the schedule ────────────────────────────────────────────────────────────
-- Every 15 minutes. The hourly nag and the goal-hour check are gated inside
-- js_notify_tick(), so the job itself just needs to run often enough to catch them.
select cron.unschedule('js-notify') where exists (select 1 from cron.job where jobname = 'js-notify');
select cron.schedule('js-notify', '*/15 * * * *', $job$ select js_notify_tick(); $job$);
