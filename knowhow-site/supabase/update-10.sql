-- =====================================================================
-- KnowHow update 10: face-to-face or online sessions
--   * sessions.mode      'online' (KnowHow video call) or 'f2f' (face-to-face)
--   * sessions.location  where to meet for face-to-face sessions
--   * mentor_profiles.session_modes  which of the two a mentor offers
--   * mentor_directory   now also returns session_modes
-- Safe to run more than once. Existing sessions stay 'online'.
-- (Group mentoring was removed from the app; its tables are left in place.)
-- =====================================================================

alter table public.sessions
  add column if not exists mode text not null default 'online';
alter table public.sessions
  add column if not exists location text;

alter table public.sessions drop constraint if exists sessions_mode_check;
alter table public.sessions add constraint sessions_mode_check
  check (mode in ('online', 'f2f'));
alter table public.sessions drop constraint if exists sessions_location_check;
alter table public.sessions add constraint sessions_location_check
  check (location is null or char_length(location) between 1 and 120);
alter table public.sessions drop constraint if exists sessions_f2f_needs_place;
alter table public.sessions add constraint sessions_f2f_needs_place
  check (mode = 'online' or (location is not null and char_length(btrim(location)) >= 3));

alter table public.mentor_profiles
  add column if not exists session_modes text[] not null default array['online', 'f2f']::text[];
alter table public.mentor_profiles drop constraint if exists mentor_profiles_session_modes_check;
alter table public.mentor_profiles add constraint mentor_profiles_session_modes_check
  check (cardinality(session_modes) between 1 and 2 and session_modes <@ array['online', 'f2f']::text[]);

grant insert (mode, location) on public.sessions to authenticated;
grant insert (session_modes), update (session_modes) on public.mentor_profiles to authenticated;

-- Same columns as before, in the same order, plus session_modes at the end.
create or replace view public.mentor_directory
with (security_invoker = true) as
select
  m.id,
  p.full_name,
  p.course,
  p.year_level,
  p.avatar_url,
  m.bio,
  m.rate_php,
  m.available_days,
  m.available_from,
  m.available_to,
  m.verified,
  m.sessions_taught,
  coalesce(round(r.avg_stars, 1), 0)   as rating,
  coalesce(r.review_count, 0)          as review_count,
  coalesce(s.subjects, '{}')           as subjects,
  coalesce(s.teaches_critical, false)  as teaches_critical,
  p.cover_url,
  p.cover_preset,
  m.availability,
  m.status_note,
  m.session_modes
from public.mentor_profiles m
join public.profiles p on p.id = m.id and p.status = 'active'
left join lateral (
  select avg(stars)::numeric as avg_stars, count(*) as review_count
  from public.reviews where mentor_id = m.id
) r on true
left join lateral (
  select array_agg(sb.name order by sb.name) as subjects, bool_or(sb.is_critical) as teaches_critical
  from public.mentor_subjects ms join public.subjects sb on sb.id = ms.subject_id
  where ms.mentor_id = m.id
) s on true;

grant select on public.mentor_directory to authenticated;

-- Health check: every row should say OK
select 'sessions.mode' as item, case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sessions' and column_name = 'mode') then 'OK' else 'MISSING' end as status
union all
select 'sessions.location', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sessions' and column_name = 'location') then 'OK' else 'MISSING' end
union all
select 'mentor_profiles.session_modes', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'mentor_profiles' and column_name = 'session_modes') then 'OK' else 'MISSING' end
union all
select 'mentor_directory.session_modes', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'mentor_directory' and column_name = 'session_modes') then 'OK' else 'MISSING' end;
