-- =====================================================================
-- KnowHow · Supabase schema (Postgres 15+)
-- Peer tutoring for MMCL students. Sign-in uses Gmail accounts.
--
-- How to use
--   1. Create a new Supabase project.
--   2. Authentication > Providers: keep Email on (and optionally turn on
--      Google so students can "Continue with Google").
--   3. SQL Editor > New query > paste this whole file > Run.
--   4. Make your admin: sign up once in the app with the admin's Gmail,
--      then run the "MAKE ADMIN" line at the very bottom with that email.
--
-- From the app (supabase-js):
--   sign up   supabase.auth.signUp({ email, password, options: { data: {
--               full_name, student_no, course, year_level, role } } })
--             role must be 'learner', 'mentor' or 'both' (lowercase).
--   log in    supabase.auth.signInWithPassword({ email, password })
--   forgot    supabase.auth.resetPasswordForEmail(email, { redirectTo })
--   my row    supabase.rpc('my_profile')
--   mentors   supabase.from('mentor_directory').select('*')
--   NOTE: profiles uses column-level privileges, so never select('*') on
--   profiles. List the columns you need, e.g. select('id, full_name, course').
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.user_role        as enum ('learner', 'mentor', 'both');
create type public.account_status   as enum ('active', 'suspended', 'under_review');
create type public.subject_category as enum ('Math', 'Programming', 'Engineering', 'Science', 'Business');
create type public.arrangement      as enum ('per_session', 'per_day', 'per_week', 'per_month');
create type public.session_status   as enum ('pending', 'confirmed', 'completed', 'cancelled');
create type public.credential_kind  as enum ('grade', 'certificate', 'achievement', 'student_id', 'document');
create type public.review_status    as enum ('pending', 'verified', 'rejected');
create type public.post_kind        as enum ('offer', 'announcement', 'request');
create type public.report_status    as enum ('open', 'resolved', 'dismissed');
create type public.report_target    as enum ('post', 'profile', 'session');

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text not null unique,
  full_name    text not null check (char_length(full_name) between 2 and 120),
  student_no   text unique check (student_no is null or student_no ~ '^\d{4}-?\d{4,7}$'),
  course       text not null default '',
  year_level   text not null default '',
  role         public.user_role not null default 'learner',
  is_admin     boolean not null default false,
  status       public.account_status not null default 'active',
  id_verified  boolean not null default false,
  avatar_url   text,
  cover_url    text,
  cover_preset text,
  created_at   timestamptz not null default now()
);

create table public.subjects (
  id           smallint generated always as identity primary key,
  name         text not null unique,
  category     public.subject_category not null,
  is_critical  boolean not null default false
);

create table public.mentor_profiles (
  id               uuid primary key references public.profiles (id) on delete cascade,
  bio              text not null check (char_length(bio) between 30 and 1000),
  rate_php         integer not null check (rate_php between 50 and 1000),
  available_days   smallint[] not null default '{}',   -- 0 = Monday ... 6 = Sunday
  available_from   time not null,
  available_to     time not null,
  verified         boolean not null default false,
  sessions_taught  integer not null default 0,
  availability     text not null default 'available',
  status_note      text,
  created_at       timestamptz not null default now(),
  constraint available_days_valid check (available_days <@ array[0,1,2,3,4,5,6]::smallint[]),
  constraint available_window check (available_to > available_from),
  constraint mentor_availability_valid check (availability in ('available', 'busy', 'away')),
  constraint mentor_status_note_len check (status_note is null or char_length(status_note) <= 120)
);

create table public.mentor_subjects (
  mentor_id   uuid not null references public.mentor_profiles (id) on delete cascade,
  subject_id  smallint not null references public.subjects (id) on delete cascade,
  primary key (mentor_id, subject_id)
);

create table public.credentials (
  id           uuid primary key default gen_random_uuid(),
  mentor_id    uuid not null references public.mentor_profiles (id) on delete cascade,
  kind         public.credential_kind not null default 'document',
  title        text not null check (char_length(title) between 2 and 200),
  file_path    text not null,                 -- path inside the "credentials" bucket
  status       public.review_status not null default 'pending',
  reviewed_by  uuid references public.profiles (id) on delete set null,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);

create table public.teaching_videos (
  id            uuid primary key default gen_random_uuid(),
  mentor_id     uuid not null references public.mentor_profiles (id) on delete cascade,
  title         text not null check (char_length(title) between 2 and 200),
  file_path     text not null,                -- path inside the "videos" bucket
  duration_sec  integer check (duration_sec between 1 and 1800),
  created_at    timestamptz not null default now()
);

create table public.sessions (
  id             uuid primary key default gen_random_uuid(),
  learner_id     uuid not null references public.profiles (id) on delete cascade,
  mentor_id      uuid not null references public.mentor_profiles (id) on delete cascade,
  subject_id     smallint not null references public.subjects (id),
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  arrangement    public.arrangement not null default 'per_session',
  status         public.session_status not null default 'pending',
  zoom_url       text check (zoom_url is null or zoom_url ~* '^https://([a-z0-9-]+\.)*zoom\.us/\S+$'),
  recording_url  text check (recording_url is null or recording_url ~* '^https://\S+$'),
  notes          text check (notes is null or char_length(notes) <= 1000),
  created_at     timestamptz not null default now(),
  constraint session_time check (ends_at > starts_at),
  constraint not_self check (learner_id <> mentor_id)
);
create index sessions_mentor_time  on public.sessions (mentor_id, starts_at);
create index sessions_learner_time on public.sessions (learner_id, starts_at);

create table public.reviews (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null unique references public.sessions (id) on delete cascade,
  mentor_id   uuid not null references public.mentor_profiles (id) on delete cascade,
  learner_id  uuid not null references public.profiles (id) on delete cascade,
  stars       smallint not null check (stars between 1 and 5),
  body        text check (body is null or char_length(body) <= 1000),
  created_at  timestamptz not null default now()
);
create index reviews_mentor on public.reviews (mentor_id);

create table public.posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references public.profiles (id) on delete cascade,
  kind        public.post_kind not null default 'request',
  body        text not null check (char_length(body) between 10 and 2000),
  subject_id  smallint references public.subjects (id),
  created_at  timestamptz not null default now()
);
create index posts_created on public.posts (created_at desc);

create table public.post_likes (
  post_id     uuid not null references public.posts (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.saved_mentors (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  mentor_id   uuid not null references public.mentor_profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, mentor_id)
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  body        text not null,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index notifications_user on public.notifications (user_id, created_at desc);

create table public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references public.profiles (id) on delete set null,
  target_type  public.report_target not null,
  target_id    uuid not null,
  reason       text not null check (char_length(reason) between 5 and 1000),
  status       public.report_status not null default 'open',
  resolved_by  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

create table public.activity_log (
  id          bigint generated always as identity primary key,
  actor_id    uuid references public.profiles (id) on delete set null,
  action      text not null,
  created_at  timestamptz not null default now()
);

-- Non-Gmail emails allowed to sign up (for the admin). Editable only in the SQL Editor.
create table public.allowed_non_gmail (
  email       text primary key check (email = lower(email)),
  note        text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Helper: is the signed-in user an admin?
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------------------
-- New sign-ups: Gmail only, create the profile row from sign-up data
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.email !~* '^[a-z0-9.+_-]+@gmail\.com$'
     and not exists (select 1 from public.allowed_non_gmail a where a.email = lower(new.email)) then
    raise exception 'Please sign up with a Gmail address (ending in @gmail.com).';
  end if;

  insert into public.profiles (id, email, full_name, student_no, course, year_level, role, avatar_url)
  values (
    new.id,
    lower(new.email),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''),
             nullif(new.raw_user_meta_data ->> 'name', ''),       -- Google sign-in
             split_part(new.email, '@', 1)),
    nullif(new.raw_user_meta_data ->> 'student_no', ''),
    coalesce(new.raw_user_meta_data ->> 'course', ''),
    coalesce(new.raw_user_meta_data ->> 'year_level', ''),
    coalesce(nullif(lower(new.raw_user_meta_data ->> 'role'), '')::public.user_role, 'learner'),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')           -- Google sign-in
  );

  insert into public.activity_log (actor_id, action) values (new.id, 'signed up');
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Your own full profile row (includes email and student number)
create or replace function public.my_profile()
returns public.profiles
language sql stable security definer set search_path = public
as $$
  select * from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- Sessions: guard status changes, notify, count completed sessions
-- ---------------------------------------------------------------------
create or replace function public.sessions_guard()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status then
    if old.status in ('completed', 'cancelled') then
      raise exception 'This session is already %.', old.status;
    end if;
    if new.status = 'pending' then
      raise exception 'A session cannot go back to pending.';
    end if;
    if new.status = 'confirmed' and auth.uid() is distinct from old.mentor_id then
      raise exception 'Only the mentor can confirm a session.';
    end if;
    if new.status = 'completed' and old.status <> 'confirmed' then
      raise exception 'Only confirmed sessions can be marked completed.';
    end if;
  end if;
  return new;
end;
$$;

create trigger sessions_guard
  before update on public.sessions
  for each row execute function public.sessions_guard();

create or replace function public.on_session_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  subj text;
  who  text;
begin
  select coalesce(name, 'tutoring') into subj from public.subjects where id = new.subject_id;
  subj := coalesce(subj, 'tutoring');

  if tg_op = 'INSERT' then
    select full_name into who from public.profiles where id = new.learner_id;
    who := coalesce(who, 'A student');
    insert into public.notifications (user_id, body)
      values (new.mentor_id, who || ' requested a ' || subj || ' session.');
    insert into public.activity_log (actor_id, action)
      values (new.learner_id, 'requested a ' || subj || ' session');

  elsif new.status is distinct from old.status then
    if new.status = 'confirmed' then
      select full_name into who from public.profiles where id = new.mentor_id;
      who := coalesce(who, 'Your mentor');
      insert into public.notifications (user_id, body)
        values (new.learner_id, who || ' confirmed your ' || subj || ' session.');
    elsif new.status = 'cancelled' then
      insert into public.notifications (user_id, body)
        values (case when auth.uid() = new.mentor_id then new.learner_id else new.mentor_id end,
                'Your ' || subj || ' session was cancelled.');
    elsif new.status = 'completed' then
      update public.mentor_profiles set sessions_taught = sessions_taught + 1 where id = new.mentor_id;
      insert into public.notifications (user_id, body)
        values (new.learner_id, 'How was ' || subj || '? Leave a rating for your mentor.');
    end if;
  end if;
  return new;
end;
$$;

create trigger sessions_notify
  after insert or update on public.sessions
  for each row execute function public.on_session_change();

-- ---------------------------------------------------------------------
-- Admin actions (each checks is_admin)
-- ---------------------------------------------------------------------
create or replace function public.admin_accounts()
returns table (
  id uuid, email text, full_name text, student_no text, course text, year_level text,
  role public.user_role, is_admin boolean, status public.account_status,
  id_verified boolean, is_mentor boolean, created_at timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  return query
    select p.id, p.email, p.full_name, p.student_no, p.course, p.year_level,
           p.role, p.is_admin, p.status, p.id_verified,
           exists (select 1 from public.mentor_profiles m where m.id = p.id),
           p.created_at
    from public.profiles p
    order by p.created_at desc;
end;
$$;

create or replace function public.admin_set_status(target uuid, new_status public.account_status)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if target = auth.uid() then raise exception 'You cannot change your own account status.'; end if;
  update public.profiles set status = new_status where id = target;
  insert into public.activity_log (actor_id, action)
    values (auth.uid(), 'set account ' || target || ' to ' || new_status);
end;
$$;

create or replace function public.admin_verify_id(target uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.profiles set id_verified = true where id = target;
  insert into public.activity_log (actor_id, action) values (auth.uid(), 'verified student ID of ' || target);
end;
$$;

create or replace function public.admin_review_credential(cred uuid, approve boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  m uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;

  update public.credentials
     set status = (case when approve then 'verified' else 'rejected' end)::public.review_status,
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = cred
  returning mentor_id into m;

  if m is null then raise exception 'Credential not found.'; end if;

  -- A mentor is verified once every uploaded credential is verified.
  update public.mentor_profiles
     set verified = exists (select 1 from public.credentials where mentor_id = m)
                and not exists (select 1 from public.credentials where mentor_id = m and status <> 'verified')
   where id = m;

  insert into public.notifications (user_id, body)
    values (m, case when approve then 'An admin verified one of your credentials.'
                    else 'An admin could not verify one of your credentials. Please upload a clearer copy.' end);
  insert into public.activity_log (actor_id, action)
    values (auth.uid(), (case when approve then 'approved' else 'rejected' end) || ' credential ' || cred);
end;
$$;

create or replace function public.admin_resolve_report(rep uuid, outcome public.report_status)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  if outcome = 'open' then raise exception 'Choose resolved or dismissed.'; end if;
  update public.reports set status = outcome, resolved_by = auth.uid() where id = rep;
  insert into public.activity_log (actor_id, action) values (auth.uid(), outcome || ' report ' || rep);
end;
$$;

-- Only signed-in users may call these functions.
revoke execute on function public.my_profile()                                   from public, anon;
revoke execute on function public.admin_accounts()                               from public, anon;
revoke execute on function public.admin_set_status(uuid, public.account_status)  from public, anon;
revoke execute on function public.admin_verify_id(uuid)                          from public, anon;
revoke execute on function public.admin_review_credential(uuid, boolean)         from public, anon;
revoke execute on function public.admin_resolve_report(uuid, public.report_status) from public, anon;
grant  execute on function public.my_profile()                                   to authenticated;
grant  execute on function public.admin_accounts()                               to authenticated;
grant  execute on function public.admin_set_status(uuid, public.account_status)  to authenticated;
grant  execute on function public.admin_verify_id(uuid)                          to authenticated;
grant  execute on function public.admin_review_credential(uuid, boolean)         to authenticated;
grant  execute on function public.admin_resolve_report(uuid, public.report_status) to authenticated;

-- ---------------------------------------------------------------------
-- Mentor directory (what Find a Mentor reads)
-- ---------------------------------------------------------------------
create view public.mentor_directory
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

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.subjects         enable row level security;
alter table public.mentor_profiles  enable row level security;
alter table public.mentor_subjects  enable row level security;
alter table public.credentials      enable row level security;
alter table public.teaching_videos  enable row level security;
alter table public.sessions         enable row level security;
alter table public.reviews          enable row level security;
alter table public.posts            enable row level security;
alter table public.post_likes       enable row level security;
alter table public.saved_mentors    enable row level security;
alter table public.notifications    enable row level security;
alter table public.reports          enable row level security;
alter table public.activity_log     enable row level security;
alter table public.allowed_non_gmail enable row level security;

-- Nobody signed out can read or write anything.
revoke all on all tables in schema public from anon;

-- profiles: names and courses are visible to signed-in users;
-- email, student number, is_admin flag changes go through functions.
revoke all on public.profiles from authenticated;
grant select (id, full_name, course, year_level, role, avatar_url, cover_url, cover_preset, status, is_admin, id_verified, created_at)
  on public.profiles to authenticated;
grant update (full_name, course, year_level, role, avatar_url, cover_url, cover_preset) on public.profiles to authenticated;
create policy "profiles: read"       on public.profiles for select to authenticated using (true);
create policy "profiles: update own" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- subjects: read-only catalog
create policy "subjects: read" on public.subjects for select to authenticated using (true);

-- mentor_profiles: anyone signed in can read; you manage your own (not "verified")
revoke insert, update on public.mentor_profiles from authenticated;
grant insert (id, bio, rate_php, available_days, available_from, available_to, availability, status_note) on public.mentor_profiles to authenticated;
grant update (bio, rate_php, available_days, available_from, available_to, availability, status_note)     on public.mentor_profiles to authenticated;
create policy "mentors: read"       on public.mentor_profiles for select to authenticated using (true);
create policy "mentors: create own" on public.mentor_profiles for insert to authenticated with check (id = auth.uid());
create policy "mentors: update own" on public.mentor_profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "mentors: delete own or admin" on public.mentor_profiles for delete to authenticated
  using (id = auth.uid() or public.is_admin());

-- mentor_subjects
create policy "mentor_subjects: read"       on public.mentor_subjects for select to authenticated using (true);
create policy "mentor_subjects: add own"    on public.mentor_subjects for insert to authenticated with check (mentor_id = auth.uid());
create policy "mentor_subjects: remove own" on public.mentor_subjects for delete to authenticated using (mentor_id = auth.uid());

-- credentials: titles and status are public; status changes only via admin_review_credential
revoke insert, update on public.credentials from authenticated;
grant insert (mentor_id, kind, title, file_path) on public.credentials to authenticated;
create policy "credentials: read"       on public.credentials for select to authenticated using (true);
create policy "credentials: upload own" on public.credentials for insert to authenticated with check (mentor_id = auth.uid());
create policy "credentials: delete own unverified or admin" on public.credentials for delete to authenticated
  using ((mentor_id = auth.uid() and status <> 'verified') or public.is_admin());

-- teaching_videos
create policy "videos: read"       on public.teaching_videos for select to authenticated using (true);
create policy "videos: upload own" on public.teaching_videos for insert to authenticated with check (mentor_id = auth.uid());
create policy "videos: delete own or admin" on public.teaching_videos for delete to authenticated
  using (mentor_id = auth.uid() or public.is_admin());

-- sessions: only the learner, the mentor, or an admin can see one
revoke insert, update on public.sessions from authenticated;
grant insert (learner_id, mentor_id, subject_id, starts_at, ends_at, arrangement, notes, zoom_url) on public.sessions to authenticated;
grant update (status, zoom_url, recording_url, notes) on public.sessions to authenticated;
create policy "sessions: participants or admin read" on public.sessions for select to authenticated
  using (auth.uid() in (learner_id, mentor_id) or public.is_admin());
create policy "sessions: learner books" on public.sessions for insert to authenticated
  with check (learner_id = auth.uid());
create policy "sessions: participants update" on public.sessions for update to authenticated
  using (auth.uid() in (learner_id, mentor_id)) with check (auth.uid() in (learner_id, mentor_id));

-- reviews: one per completed session, written by that session's learner
create policy "reviews: read" on public.reviews for select to authenticated using (true);
create policy "reviews: learner after completed session" on public.reviews for insert to authenticated
  with check (
    learner_id = auth.uid()
    and exists (
      select 1 from public.sessions s
      where s.id = reviews.session_id
        and s.learner_id = auth.uid()
        and s.mentor_id = reviews.mentor_id
        and s.status = 'completed'
    )
  );
create policy "reviews: delete by admin" on public.reviews for delete to authenticated using (public.is_admin());

-- posts and likes
create policy "posts: read"        on public.posts for select to authenticated using (true);
create policy "posts: create own"  on public.posts for insert to authenticated with check (author_id = auth.uid());
create policy "posts: update own"  on public.posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "posts: delete own or admin" on public.posts for delete to authenticated using (author_id = auth.uid() or public.is_admin());
create policy "likes: read"   on public.post_likes for select to authenticated using (true);
create policy "likes: add"    on public.post_likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes: remove" on public.post_likes for delete to authenticated using (user_id = auth.uid());

-- saved mentors (private to each user)
create policy "saved: own" on public.saved_mentors for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- notifications (created by triggers; users can only mark their own as read)
revoke insert, update on public.notifications from authenticated;
grant update (read) on public.notifications to authenticated;
create policy "notifications: read own"   on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "notifications: mark read"  on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "notifications: delete own" on public.notifications for delete to authenticated using (user_id = auth.uid());

-- reports: students file them; only admins see them all
revoke update on public.reports from authenticated;
create policy "reports: file"            on public.reports for insert to authenticated with check (reporter_id = auth.uid());
create policy "reports: own or admin"    on public.reports for select to authenticated using (reporter_id = auth.uid() or public.is_admin());

-- activity log: admins only
revoke insert, update, delete on public.activity_log from authenticated;

-- non-Gmail exception list: no app access at all (SQL Editor only)
revoke all on public.allowed_non_gmail from anon, authenticated;
create policy "activity: admin read" on public.activity_log for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------
-- Storage buckets
--   avatars      public   avatars/<user id>/photo.jpg
--   credentials  private  credentials/<user id>/<file>   (owner + admins)
--   videos       public   videos/<user id>/<file>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('avatars', 'avatars', true),
  ('credentials', 'credentials', false),
  ('videos', 'videos', true)
on conflict (id) do nothing;

create policy "avatars: upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "credentials: upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'credentials' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "credentials: owner or admin read" on storage.objects for select to authenticated
  using (bucket_id = 'credentials' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
create policy "credentials: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'credentials' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "videos: upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "videos: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- Subject catalog (not accounts — safe to keep)
-- ---------------------------------------------------------------------
insert into public.subjects (name, category, is_critical) values
  ('Calculus 1',                       'Math',        true),
  ('Calculus 2',                       'Math',        true),
  ('Differential Equations',           'Math',        true),
  ('Discrete Mathematics',             'Math',        false),
  ('Statistics and Probability',       'Math',        false),
  ('Physics for Engineers',            'Science',     true),
  ('Chemistry for Engineers',          'Science',     false),
  ('Engineering Mechanics (Statics)',  'Engineering', true),
  ('Electric Circuits 1',              'Engineering', true),
  ('Logic Circuits and Design',        'Engineering', false),
  ('Data Structures and Algorithms',   'Programming', true),
  ('Object-Oriented Programming',      'Programming', false),
  ('Web Development',                  'Programming', false),
  ('Database Systems',                 'Programming', false),
  ('Financial Accounting',             'Business',    true),
  ('Cost Accounting',                  'Business',    false)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- Protected fields enforced by triggers (from update 3)
-- ---------------------------------------------------------------------
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
-- Fixed roles + student/mentor messages (from update 5)
-- ---------------------------------------------------------------------
-- ---------- 1) Users can't change their own role (admins can, below)
create or replace function public.protect_profile_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.id := old.id;
    new.email := old.email;
    new.student_no := old.student_no;
    new.role := old.role;
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

-- New sign-ups can only choose student or mentor
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  wanted text := lower(coalesce(new.raw_user_meta_data ->> 'role', ''));
begin
  if new.email !~* '^[a-z0-9.+_-]+@gmail\.com$'
     and not exists (select 1 from public.allowed_non_gmail a where a.email = lower(new.email)) then
    raise exception 'Please sign up with a Gmail address (ending in @gmail.com).';
  end if;

  insert into public.profiles (id, email, full_name, student_no, course, year_level, role, avatar_url)
  values (
    new.id,
    lower(new.email),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''),
             nullif(new.raw_user_meta_data ->> 'name', ''),
             split_part(new.email, '@', 1)),
    nullif(new.raw_user_meta_data ->> 'student_no', ''),
    coalesce(new.raw_user_meta_data ->> 'course', ''),
    coalesce(new.raw_user_meta_data ->> 'year_level', ''),
    (case when wanted = 'mentor' then 'mentor' else 'learner' end)::public.user_role,
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  );

  insert into public.activity_log (actor_id, action) values (new.id, 'signed up');
  return new;
end;
$$;

-- Admin-only: change someone's role
create or replace function public.admin_set_role(target uuid, new_role public.user_role)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  update public.profiles set role = new_role where id = target;
  insert into public.activity_log (actor_id, action) values (auth.uid(), 'set role of ' || target || ' to ' || new_role);
end;
$$;
revoke execute on function public.admin_set_role(uuid, public.user_role) from public, anon;
grant  execute on function public.admin_set_role(uuid, public.user_role) to authenticated;

-- ---------- 2) Only mentors create mentor profiles; only students book
drop policy if exists "mentors: create own" on public.mentor_profiles;
create policy "mentors: create own" on public.mentor_profiles for insert to authenticated
  with check (
    id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('mentor', 'both'))
  );

drop policy if exists "sessions: learner books" on public.sessions;
create policy "sessions: learner books" on public.sessions for insert to authenticated
  with check (
    learner_id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('learner', 'both'))
  );

-- ---------- 3) Messages between students and mentors
create table if not exists public.messages (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references public.profiles (id) on delete cascade,
  recipient_id  uuid not null references public.profiles (id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 2000),
  read          boolean not null default false,
  created_at    timestamptz not null default now(),
  constraint messages_not_self check (sender_id <> recipient_id)
);
create index if not exists messages_pair_time on public.messages (sender_id, recipient_id, created_at);
create index if not exists messages_unread on public.messages (recipient_id, read);

alter table public.messages enable row level security;
grant select, insert, update on public.messages to authenticated;

drop policy if exists "messages: read own" on public.messages;
create policy "messages: read own" on public.messages for select to authenticated
  using (auth.uid() in (sender_id, recipient_id));

-- A student can message a mentor and a mentor can message a student (and anyone can message/receive from an admin)
drop policy if exists "messages: send" on public.messages;
create policy "messages: send" on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1
      from public.profiles a, public.profiles b
      where a.id = auth.uid() and b.id = messages.recipient_id
        and a.status = 'active' and b.status = 'active'
        and (a.is_admin or b.is_admin
             or (a.role in ('learner', 'both') and b.role in ('mentor', 'both'))
             or (a.role in ('mentor', 'both') and b.role in ('learner', 'both')))
    )
  );

drop policy if exists "messages: mark read" on public.messages;
create policy "messages: mark read" on public.messages for update to authenticated
  using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- Recipients may only flip "read"; everything else stays as sent
create or replace function public.protect_message_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.id := old.id;
    new.sender_id := old.sender_id;
    new.recipient_id := old.recipient_id;
    new.body := old.body;
    new.created_at := old.created_at;
  end if;
  return new;
end;
$$;
drop trigger if exists messages_protect on public.messages;
create trigger messages_protect
  before update on public.messages
  for each row execute function public.protect_message_fields();

-- Live delivery of new messages (Supabase Realtime)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- =====================================================================
-- MAKE ADMIN (run separately, after the admin account exists)
-- If the admin email is NOT Gmail, first allow it:
--
--   insert into public.allowed_non_gmail (email, note) values ('admin@example.com', 'KnowHow admin');
--
-- then create the user in Authentication > Users > Add user (tick Auto Confirm).
-- Replace the email below with the admin's address:
--
--   update public.profiles
--      set is_admin = true, id_verified = true
--    where email = 'your.admin.account@gmail.com';
--
-- Admins see the Admin Panel; everyone else never does.
-- =====================================================================
