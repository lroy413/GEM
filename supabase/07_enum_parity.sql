-- ============================================================
-- GEM · 07 — reconcile the enums with what the app actually writes
-- Run AFTER 06_app_parity.sql. Safe to re-run.
--
-- Found by auditing the app's literal values against the enum definitions,
-- rather than assuming they agreed. Each of these would have surfaced as a
-- "22P02 invalid input value for enum" only once real data hit it — a lead
-- dragged into a custom stage, or a questionnaire with an email field.
-- ============================================================


-- ---------- 1 · pipeline stages are user-defined ----------
-- Settings → Pipeline stages lets a studio add its own stages, and a new one
-- gets a generated id (st-7-k29f…). An enum cannot hold values invented at
-- runtime, so any lead sitting in a custom stage would refuse to save.
-- Text is the honest type here; the app owns this vocabulary and validates it.
alter table leads alter column stage type text using stage::text;
alter table leads alter column stage set default 'inquiry';

-- The (org_id, stage) index rebuilds itself on the type change; nothing to do.


-- ---------- 2 · questionnaires can ask for an email address ----------
-- The builder offers seven answer types; the enum was written with six of
-- them and no 'email'.
alter type question_kind add value if not exists 'email';


-- ---------- verify ----------
-- Expect: stage_is_text true, and email_kind true.
select
  (select data_type from information_schema.columns
     where table_name = 'leads' and column_name = 'stage') = 'text'  as stage_is_text,
  'email' = any(enum_range(null::question_kind)::text[])             as email_kind;
