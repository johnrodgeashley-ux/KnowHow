-- =====================================================================
-- KnowHow · update 4 (run ONCE in Supabase > SQL Editor)
-- Fixes "permission denied for table ..." (error 42501).
--
-- Your project doesn't give logged-in users automatic access to new
-- tables, so this grants exactly what the website needs, table by table.
-- It also includes everything from update 3, so you don't need to run
-- update 3 separately. Safe to run more than once.
--
-- The last query prints a health report: one row per table with what
-- the website can do. Nothing should say MISSING.
-- =====================================================================

-- ---------- mentor_profiles: users can't verify themselves or edit their session count
create or replace function public.protect_mentor_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.verified := false;
      new.sessions_taught := 0;
    else
      new.id := old.id;
      new.verified := old.verified;
      new.sessions_taught := old.sessions_taught;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists mentor_profiles_protect on public.mentor_profiles;
create trigger mentor_profiles_protect
  before insert or update on public.mentor_profiles
  for each row execute function public.protect_mentor_fields();
grant insert, update on public.mentor_profiles to authenticated;

-- ---------- sessions: new bookings always start as pending; who/what can't be changed later
create or replace function public.protect_session_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.status := 'pending';
      new.recording_url := null;
    else
      new.learner_id := old.learner_id;
      new.mentor_id := old.mentor_id;
      new.subject_id := old.subject_id;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists sessions_protect on public.sessions;
create trigger sessions_protect
  before insert or update on public.sessions
  for each row execute function public.protect_session_fields();
grant insert, update on public.sessions to authenticated;

-- ---------- credentials: uploads always start as pending review
create or replace function public.protect_credential_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
  end if;
  return new;
end;
$$;
drop trigger if exists credentials_protect on public.credentials;
create trigger credentials_protect
  before insert on public.credentials
  for each row execute function public.protect_credential_fields();
grant insert on public.credentials to authenticated;

-- ---------- profiles: users can edit their own name/course/photo, never admin/status/verification
create or replace function public.protect_profile_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.id := old.id;
    new.email := old.email;
    new.student_no := old.student_no;
    new.is_admin := old.is_admin;
    new.status := old.status;
    new.id_verified := old.id_verified;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_protect on public.profiles;
create trigger profiles_protect
  before update on public.profiles
  for each row execute function public.protect_profile_fields();
grant update on public.profiles to authenticated;

-- (Reading profiles stays column-limited, so emails and student numbers
--  remain private. Row-level security policies are unchanged.)

-- ---------------------------------------------------------------------
-- Explicit permissions for logged-in users (role "authenticated").
-- Needed when "Automatically expose new tables" is off in Supabase.
-- Row-level security policies still decide WHICH rows each person sees
-- or changes; protected fields are kept by the triggers above.
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;

grant select                         on public.subjects         to authenticated;
grant select, insert, update, delete on public.mentor_profiles  to authenticated;
grant select, insert, delete         on public.mentor_subjects  to authenticated;
grant select, insert, delete         on public.credentials      to authenticated;
grant select, insert, delete         on public.teaching_videos  to authenticated;
grant select, insert, update         on public.sessions         to authenticated;
grant select, insert, delete         on public.reviews          to authenticated;
grant select, insert, update, delete on public.posts            to authenticated;
grant select, insert, delete         on public.post_likes       to authenticated;
grant select, insert, delete         on public.saved_mentors    to authenticated;
grant select, update, delete         on public.notifications    to authenticated;
grant select, insert                 on public.reports          to authenticated;
grant select                         on public.activity_log     to authenticated;
grant select                         on public.mentor_directory to authenticated;

-- profiles: everyone may read names/courses/photos (not emails or student numbers);
-- each person may update their own row (protected fields are kept by a trigger)
grant select (id, full_name, course, year_level, role, avatar_url, cover_url, cover_preset,
              status, is_admin, id_verified, created_at) on public.profiles to authenticated;
grant update on public.profiles to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- ---------------------------------------------------------------------
-- Health report: what the website (logged-in users) can do on each table.
-- Every row should show something; profiles shows UPDATE only because
-- reading profiles is limited to safe columns.
-- ---------------------------------------------------------------------
select t.table_name as "table",
       coalesce(string_agg(distinct g.privilege_type, ', '), 'MISSING') as "website can"
from (values ('subjects'),('profiles'),('mentor_profiles'),('mentor_subjects'),('credentials'),
             ('teaching_videos'),('sessions'),('reviews'),('posts'),('post_likes'),('saved_mentors'),
             ('notifications'),('reports'),('activity_log'),('mentor_directory')) as t(table_name)
left join information_schema.role_table_grants g
  on g.table_schema = 'public' and g.table_name = t.table_name and g.grantee = 'authenticated'
group by t.table_name
order by 1;
