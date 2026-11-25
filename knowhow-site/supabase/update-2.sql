-- =====================================================================
-- KnowHow · update 2 (run ONCE in Supabase > SQL Editor)
--   * profile covers (color theme or photo)
--   * mentor availability status (Available / Busy / Away) with a note
-- Safe to run on your existing database. Running it twice is also safe.
-- =====================================================================

-- Covers
alter table public.profiles
  add column if not exists cover_url    text,
  add column if not exists cover_preset text;

grant select (cover_url, cover_preset) on public.profiles to authenticated;
grant update (cover_url, cover_preset) on public.profiles to authenticated;

-- Availability
alter table public.mentor_profiles
  add column if not exists availability text not null default 'available',
  add column if not exists status_note  text;

alter table public.mentor_profiles drop constraint if exists mentor_availability_valid;
alter table public.mentor_profiles add  constraint mentor_availability_valid
  check (availability in ('available', 'busy', 'away'));
alter table public.mentor_profiles drop constraint if exists mentor_status_note_len;
alter table public.mentor_profiles add  constraint mentor_status_note_len
  check (status_note is null or char_length(status_note) <= 120);

grant insert (availability, status_note), update (availability, status_note)
  on public.mentor_profiles to authenticated;

-- Mentor directory: same columns as before, new ones added at the end
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
  m.status_note
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
