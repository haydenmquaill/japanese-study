-- ════════════════════════════════════════════════════════════════════════════
-- dump-schema.sql — reconstruct the public schema as DDL text.
--
-- This project has no local Postgres tooling (no psql / pg_dump / supabase CLI),
-- so this stands in for `pg_dump --schema-only`.
--
-- HOW TO USE
--   1. Supabase dashboard → SQL Editor → paste and run.
--   2. Download the result (the editor's download button) or select-all + copy.
--   3. Save over supabase/schema.sql in this repo and commit.
--
-- SCHEMA ONLY — never row data. Two reasons: the progress tables hold personal
-- study history, and config-style tables can hold secrets (e.g. a push URL or
-- shared secret). Neither belongs in git.
--
-- NOTE: this Supabase project is shared with the cooking planner, so the output
-- includes those tables and functions too. That is intentional (it stops new
-- objects colliding with existing names) — they are reference only, not to be
-- modified by study-app work.
-- ════════════════════════════════════════════════════════════════════════════
with parts as (
  -- extensions ──────────────────────────────────────────────────────────────
  select 1 ord, e.extname obj,
         format('-- extension: %s %s (schema: %s)', e.extname, e.extversion, n.nspname) ddl
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace

  -- tables ──────────────────────────────────────────────────────────────────
  union all
  select 2, c.relname,
         format(E'create table %I (\n%s\n);', c.relname,
           (select string_agg(
                     format('  %I %s%s%s', a.attname,
                            format_type(a.atttypid, a.atttypmod),
                            case when a.attnotnull then ' not null' else '' end,
                            coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '')),
                     E',\n' order by a.attnum)
              from pg_attribute a
              left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'

  -- row level security ──────────────────────────────────────────────────────
  union all
  select 3, c.relname, format('alter table %I enable row level security;', c.relname)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity

  -- constraints (pk / fk / unique / check) ──────────────────────────────────
  union all
  select 4, con.conrelid::regclass::text,
         format('alter table %s add constraint %I %s;',
                con.conrelid::regclass, con.conname, pg_get_constraintdef(con.oid))
    from pg_constraint con
   where con.connamespace = 'public'::regnamespace and con.conrelid <> 0

  -- indexes (excluding those backing a constraint) ──────────────────────────
  union all
  select 5, i.tablename, i.indexdef || ';'
    from pg_indexes i
   where i.schemaname = 'public'
     and not exists (select 1 from pg_constraint con
                      where con.connamespace = 'public'::regnamespace
                        and con.conname = i.indexname)

  -- functions (skipping anything owned by an extension) ─────────────────────
  union all
  select 6, p.proname, pg_get_functiondef(p.oid) || E';\n'
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')

  -- triggers ────────────────────────────────────────────────────────────────
  union all
  select 7, c.relname, pg_get_triggerdef(t.oid) || ';'
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal

  -- rls policies ────────────────────────────────────────────────────────────
  union all
  select 8, pol.tablename,
         format('create policy %I on %I for %s to %s%s%s;',
                pol.policyname, pol.tablename, lower(pol.cmd),
                array_to_string(pol.roles, ', '),
                coalesce(' using (' || pol.qual || ')', ''),
                coalesce(' with check (' || pol.with_check || ')', ''))
    from pg_policies pol
   where pol.schemaname = 'public'

  -- views ───────────────────────────────────────────────────────────────────
  union all
  select 9, c.relname,
         format(E'create or replace view %I as\n%s', c.relname, pg_get_viewdef(c.oid, true))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')
)
select string_agg(ddl, E'\n' order by ord, obj, ddl) as schema_dump from parts;

-- If the editor truncates the single large cell, run it one section at a time by
-- adding a filter before the final select, e.g.:
--   select string_agg(ddl, E'\n' order by obj, ddl) from parts where ord = 6;
-- Sections: 1 extensions · 2 tables · 3 rls · 4 constraints · 5 indexes
--           6 functions · 7 triggers · 8 policies · 9 views
