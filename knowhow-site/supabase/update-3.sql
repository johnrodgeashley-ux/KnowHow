-- =====================================================================
-- KnowHow · update 3 (run ONCE in Supabase > SQL Editor)
-- Fixes "You don't have permission" when saving a mentor profile,
-- booking, uploading credentials or editing your profile.
--
-- Before: protected fields (verified, status, is_admin, ...) were guarded
-- with column-level permissions, which the Supabase API handles poorly.
-- Now: users get normal insert/update permission, and triggers quietly
-- keep the protected fields unchanged. Row-level security still decides
-- WHICH rows each person may touch. Safe to run more than once.
-- =====================================================================

-- Protected-field rules only apply to requests from the website
-- (roles "authenticated"/"anon"). Admin functions and the SQL Editor
-- run as the database owner and are not affected.

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
