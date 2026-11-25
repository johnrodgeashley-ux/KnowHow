-- =====================================================================
-- KnowHow · update 5 (run ONCE in Supabase > SQL Editor)
--   * Roles are fixed: students stay students, mentors stay mentors.
--     Only an admin can change someone's role.
--   * Only mentors can create a mentor profile; only students can book.
--   * Messages: private chat between students and mentors, with live updates.
-- Safe to run more than once. The last query prints a health report.
-- =====================================================================

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

-- ---------------------------------------------------------------------
-- Health report: nothing should say MISSING
-- ---------------------------------------------------------------------
select t.table_name as "table",
       coalesce(string_agg(distinct g.privilege_type, ', '), 'MISSING') as "website can"
from (values ('subjects'),('profiles'),('mentor_profiles'),('mentor_subjects'),('credentials'),
             ('teaching_videos'),('sessions'),('reviews'),('posts'),('post_likes'),('saved_mentors'),
             ('notifications'),('reports'),('activity_log'),('mentor_directory'),('messages')) as t(table_name)
left join information_schema.role_table_grants g
  on g.table_schema = 'public' and g.table_name = t.table_name and g.grantee = 'authenticated'
group by t.table_name
order by 1;
