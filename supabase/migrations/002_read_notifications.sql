-- ════════════════════════════════════════════════════════════════════════════
-- 002 — separate reading and writing notifications
--
-- 001 only watched writing. This gives reading its own pair:
--   Writing · 12 kanji gone stale        Writing · 3 of 10 new kanji today
--   Reading · 34 items gone stale        Reading · 4 of 10 new items today
-- Each kind has its own tag, so the tray holds at most four: one stale and one goal
-- per kind, each updating in place.
--
-- Settings (user_settings.configuration.notifications):
--   shared   enabled, quiet_from, quiet_to, goal_hour
--   writing  stale_alert, stale_threshold, stale_nag, goal_reminder, daily_goal
--            (001's flat keys, unchanged, so saved settings carry straight over)
--   reading  the same five prefixed read_
--
-- Also replaces 001's way of recording unlocks. 001 stamped unlocked_at inside
-- upsert_write_progress, but rows are also written directly by the page
-- (saveLastQuizzed / saveWriteLastQuizzed upsert the tables without the RPC), and a
-- row created that way was never stamped. A trigger on each table catches every
-- path. The rule is now "level went from 0 to 1+", which also covers a level-0 row
-- (e.g. one set via the modal's level picker) being studied later.
--
-- Run after 001. Safe to re-run.
-- ════════════════════════════════════════════════════════════════════════════


-- ── unlock stamping, by trigger, on both tables ─────────────────────────────
alter table progress add column if not exists unlocked_at timestamptz;
create index if not exists progress_unlocked_at_idx
  on progress (user_id, unlocked_at) where unlocked_at is not null;

-- First move to level 1+ wins and is never overwritten. On an upsert, Postgres runs
-- the INSERT trigger on the proposed row, then (on conflict) the UPDATE trigger with
-- the real old row, so the UPDATE branch is the one that decides for existing items.
-- Rows that predate tracking keep NULL ("unlocked before this was recorded"), and NULL
-- never counts toward today.
create or replace function js_stamp_unlocked() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.unlocked_at is null and new.level >= 1
     and (tg_op = 'INSERT' or old.level = 0) then
    new.unlocked_at := now();
  end if;
  return new;
end $$;

drop trigger if exists js_progress_unlocked on progress;
create trigger js_progress_unlocked before insert or update on progress
  for each row execute function js_stamp_unlocked();

drop trigger if exists js_write_progress_unlocked on write_progress;
create trigger js_write_progress_unlocked before insert or update on write_progress
  for each row execute function js_stamp_unlocked();

-- The trigger now does this job, so upsert_write_progress goes back to exactly its
-- pre-001 definition — one mechanism, not two.
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

    INSERT INTO write_progress (user_id, item_id, level, last_quizzed, streak, updated_at)
    VALUES (p_user_id, p_item_id, v_level, p_last_quizzed, v_new_streak, now())
    ON CONFLICT (user_id, item_id)
    DO UPDATE SET
        level        = EXCLUDED.level,
        last_quizzed = EXCLUDED.last_quizzed,
        streak       = EXCLUDED.streak,
        updated_at   = now();

    RETURN v_level;
END;
$function$;


-- ── reading counts ──────────────────────────────────────────────────────────
-- Stale, as renderReadStats counts it: any item (every category), level >= 2, never
-- quizzed or quizzed longer ago than that level's read stale_days. The page's own
-- fallback for a missing level is 14 days for reading (1 for writing), matched here.
create or replace function js_read_stale_count(p_user uuid) returns int
language sql stable set search_path = public as $$
  with cfg as (
    select coalesce((select configuration->'stale_days'->'read' from user_settings where user_id = p_user), '{}'::jsonb) sd,
           '{"2":0.5,"3":1,"4":3,"5":7,"6":60}'::jsonb def
  )
  select count(*)::int
    from progress r, cfg
   where r.user_id = p_user
     and r.level >= 2
     and (r.last_quizzed is null
          or r.last_quizzed < now() - (coalesce((cfg.sd->>r.level::text)::numeric,
                                                (cfg.def->>r.level::text)::numeric,
                                                14) * interval '1 day'));
$$;

-- New items (any category) unlocked for reading today, local time.
create or replace function js_read_unlocked_today(p_user uuid) returns int
language sql stable set search_path = public as $$
  select count(*)::int
    from progress
   where user_id = p_user
     and unlocked_at is not null
     and (unlocked_at at time zone 'Australia/Brisbane')::date = js_local_now()::date;
$$;


-- ── settings defaults, now with reading ─────────────────────────────────────
-- Must stay in step with DEFAULT_NOTIFS in index.html.
create or replace function js_notif_prefs(p_user uuid) returns jsonb
language sql stable set search_path = public as $$
  select '{"enabled":true,"quiet_from":7,"quiet_to":21,"goal_hour":19,
           "stale_alert":true,"stale_threshold":10,"stale_nag":true,"goal_reminder":true,"daily_goal":10,
           "read_stale_alert":true,"read_stale_threshold":10,"read_stale_nag":true,
           "read_goal_reminder":true,"read_daily_goal":10}'::jsonb
         || coalesce((select configuration->'notifications' from user_settings where user_id = p_user), '{}'::jsonb);
$$;


-- ── state per kind ──────────────────────────────────────────────────────────
-- 001 kept one state row per person; now it's one per person per kind. Existing rows
-- become the writing rows, so nothing already sent gets repeated.
alter table js_push_state add column if not exists kind text not null default 'write';
alter table js_push_state drop constraint if exists js_push_state_pkey;
alter table js_push_state add constraint js_push_state_pkey primary key (user_id, kind);


-- ── deciding what to send ───────────────────────────────────────────────────
-- One kind ('read' or 'write') for one person. Same three rules as 001:
-- threshold alert (once, until it drops back under), hourly nag, daily goal.
create or replace function js_notify_kind(
  p_user uuid, p_kind text, p jsonb, p_hour int, p_today date, p_waking boolean) returns void
language plpgsql set search_path = public as $$
declare
  k       text := case p_kind when 'read' then 'read_' else '' end;      -- settings key prefix
  v_label text := case p_kind when 'read' then 'Reading' else 'Writing' end;
  v_noun  text := case p_kind when 'read' then 'items' else 'kanji' end;
  s js_push_state;
  v_stale int; v_threshold int; v_goal int; v_unlocked int;
begin
  insert into js_push_state (user_id, kind) values (p_user, p_kind) on conflict (user_id, kind) do nothing;
  select * into s from js_push_state where user_id = p_user and kind = p_kind;

  v_stale     := case p_kind when 'read' then js_read_stale_count(p_user) else js_write_stale_count(p_user) end;
  v_threshold := coalesce((p->>(k || 'stale_threshold'))::int, 10);

  -- 1. crossed the threshold — once, until it drops back under; held until waking hours
  if coalesce((p->>(k || 'stale_alert'))::boolean, true)
     and v_stale >= v_threshold and p_waking and not s.stale_alerted then
    insert into js_push_queue (user_id, title, body, url, tag)
    values (p_user, format('%s · %s %s gone stale', v_label, v_stale, v_noun),
            'Time for a review.', './', 'stale-' || p_kind);
    update js_push_state set stale_alerted = true, stale_nagged_at = now()
     where user_id = p_user and kind = p_kind;

  -- 2. hourly nag while any remain, waking hours only
  elsif coalesce((p->>(k || 'stale_nag'))::boolean, true) and v_stale > 0 and p_waking
     and coalesce(s.stale_nagged_at, 'epoch'::timestamptz) < now() - interval '1 hour' then
    insert into js_push_queue (user_id, title, body, url, tag)
    values (p_user, format('%s · %s stale %s waiting', v_label, v_stale, v_noun),
            'Still to be reviewed.', './', 'stale-' || p_kind);
    update js_push_state set stale_nagged_at = now()
     where user_id = p_user and kind = p_kind;
  end if;

  -- back under the threshold: re-arm the one-off alert
  if v_stale < v_threshold then
    update js_push_state set stale_alerted = false where user_id = p_user and kind = p_kind;
  end if;

  -- 3. the daily goal, at goal_hour local, once a day, only if short
  if coalesce((p->>(k || 'goal_reminder'))::boolean, true)
     and p_hour >= coalesce((p->>'goal_hour')::int, 19)
     and coalesce(s.goal_nudged_on, 'epoch'::date) < p_today then
    v_goal     := coalesce((p->>(k || 'daily_goal'))::int, 10);
    v_unlocked := case p_kind when 'read' then js_read_unlocked_today(p_user) else js_unlocked_today(p_user) end;
    if v_unlocked < v_goal then
      insert into js_push_queue (user_id, title, body, url, tag)
      values (p_user, format('%s · %s of %s new %s today', v_label, v_unlocked, v_goal, v_noun),
              'Still time to unlock a few more.', './', 'goal-' || p_kind);
    end if;
    update js_push_state set goal_nudged_on = p_today where user_id = p_user and kind = p_kind;
  end if;
end $$;

create or replace function js_notify_tick() returns void
language plpgsql set search_path = public as $$
declare
  u record; p jsonb;
  v_hour  int  := extract(hour from js_local_now())::int;
  v_today date := js_local_now()::date;
  v_waking boolean;
  v_kind text;
begin
  for u in select distinct user_id from js_push_subs loop
    p := js_notif_prefs(u.user_id);
    continue when not coalesce((p->>'enabled')::boolean, true);
    v_waking := v_hour >= coalesce((p->>'quiet_from')::int, 7)
            and v_hour <  coalesce((p->>'quiet_to')::int, 21);
    foreach v_kind in array array['write', 'read'] loop
      begin
        perform js_notify_kind(u.user_id, v_kind, p, v_hour, v_today, v_waking);
      exception when others then raise warning 'js_notify_tick (user %, %): %', u.user_id, v_kind, sqlerrm;
      end;
    end loop;
  end loop;
  perform js_push_flush();
end $$;

revoke all on function js_notify_kind(uuid, text, jsonb, int, date, boolean) from public, anon, authenticated;
revoke all on function js_notify_tick() from public, anon, authenticated;
