-- =====================================================================
-- KnowHow · update 7 (run ONCE in Supabase > SQL Editor, after update 6)
--   * Group sessions: up to 8 students in one session.
--     - Mentors can open a group class; students join until it's full.
--     - Students can add classmates (by Gmail) to a session they're in.
--     - Each student pays the mentor's full rate.
--   * Every student in a session can see it, join the call and leave a review.
-- Safe to run more than once. The last query prints a health report.
-- =====================================================================

-- ---------- 1) Sessions can be groups
alter table public.sessions alter column learner_id drop not null;
alter table public.sessions add column if not exists kind text not null default 'one';
alter table public.sessions add column if not exists capacity smallint not null default 1;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sessions_kind_check') then
    alter table public.sessions add constraint sessions_kind_check check (kind in ('one', 'group'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sessions_capacity_check') then
    alter table public.sessions add constraint sessions_capacity_check check (capacity between 1 and 8);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sessions_has_student') then
    alter table public.sessions add constraint sessions_has_student check (learner_id is not null or kind = 'group');
  end if;
end $$;

-- Extra students in a session (the student who booked stays in sessions.learner_id)
create table if not exists public.session_members (
  session_id  uuid not null references public.sessions (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  invited_by  uuid references public.profiles (id) on delete set null,
  joined_at   timestamptz not null default now(),
  primary key (session_id, user_id)
);
create index if not exists session_members_user on public.session_members (user_id);
alter table public.session_members enable row level security;
grant select on public.session_members to authenticated;   -- changes only through the functions below

-- ---------- 2) Helpers
create or replace function public.is_session_member(sid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.sessions s where s.id = sid and auth.uid() in (s.mentor_id, s.learner_id))
      or exists (select 1 from public.session_members m where m.session_id = sid and m.user_id = auth.uid());
$$;

create or replace function public.is_open_group(sid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.sessions s
    where s.id = sid and s.kind = 'group' and s.learner_id is null and s.status = 'confirmed' and s.ends_at > now()
  );
$$;

create or replace function public.session_seats_taken(sid uuid)
returns integer
language sql stable security definer set search_path = public
as $$
  select (select count(*) from public.session_members where session_id = sid)::integer
       + coalesce((select case when learner_id is null then 0 else 1 end from public.sessions where id = sid), 0);
$$;

revoke execute on function public.is_session_member(uuid) from public, anon;
revoke execute on function public.is_open_group(uuid) from public, anon;
revoke execute on function public.session_seats_taken(uuid) from public, anon;
grant  execute on function public.is_session_member(uuid) to authenticated;
grant  execute on function public.is_open_group(uuid) to authenticated;
grant  execute on function public.session_seats_taken(uuid) to authenticated;

-- ---------- 3) Who can see / create sessions
drop policy if exists "sessions: participants or admin read" on public.sessions;
drop policy if exists "sessions: members, open groups or admin read" on public.sessions;
create policy "sessions: members, open groups or admin read" on public.sessions for select to authenticated
  using (
    auth.uid() in (learner_id, mentor_id)
    or public.is_admin()
    or public.is_session_member(id)
    or (kind = 'group' and learner_id is null and status = 'confirmed' and ends_at > now())
  );

drop policy if exists "sessions: mentor opens group" on public.sessions;
create policy "sessions: mentor opens group" on public.sessions for insert to authenticated
  with check (
    mentor_id = auth.uid() and learner_id is null and kind = 'group'
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('mentor', 'both') and p.status = 'active')
  );

drop policy if exists "session members: read" on public.session_members;
create policy "session members: read" on public.session_members for select to authenticated
  using (public.is_session_member(session_id) or public.is_open_group(session_id) or public.is_admin());

-- New bookings by students are always 1-on-1 and pending; a mentor's own group class starts confirmed
create or replace function public.protect_session_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.recording_url := null;
      if new.learner_id is null and new.kind = 'group' and new.mentor_id = auth.uid() then
        new.status := 'confirmed';
        new.capacity := greatest(2, least(8, coalesce(new.capacity, 8)));
      else
        new.status := 'pending';
        new.kind := 'one';
        new.capacity := 1;
      end if;
    else
      new.learner_id := old.learner_id;
      new.mentor_id := old.mentor_id;
      new.subject_id := old.subject_id;
      new.created_at := old.created_at;
      new.kind := old.kind;
      new.capacity := old.capacity;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists sessions_protect on public.sessions;
create trigger sessions_protect
  before insert or update on public.sessions
  for each row execute function public.protect_session_fields();

-- ---------- 4) Notifications reach every student in the session
create or replace function public.on_session_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  subj text;
  who  text;
  r    uuid;
begin
  select coalesce(name, 'tutoring') into subj from public.subjects where id = new.subject_id;
  subj := coalesce(subj, 'tutoring');

  if tg_op = 'INSERT' then
    if new.learner_id is null then
      insert into public.activity_log (actor_id, action) values (new.mentor_id, 'opened a ' || subj || ' group class');
    else
      select full_name into who from public.profiles where id = new.learner_id;
      who := coalesce(who, 'A student');
      insert into public.notifications (user_id, body) values (new.mentor_id, who || ' requested a ' || subj || ' session.');
      insert into public.activity_log (actor_id, action) values (new.learner_id, 'requested a ' || subj || ' session');
    end if;

  elsif new.status is distinct from old.status then
    if new.status = 'confirmed' then
      select full_name into who from public.profiles where id = new.mentor_id;
      who := coalesce(who, 'Your mentor');
      for r in select x from (select new.learner_id as x union select user_id from public.session_members where session_id = new.id) q where x is not null loop
        insert into public.notifications (user_id, body) values (r, who || ' confirmed your ' || subj || ' session.');
      end loop;
    elsif new.status = 'cancelled' then
      if auth.uid() = new.mentor_id then
        for r in select x from (select new.learner_id as x union select user_id from public.session_members where session_id = new.id) q where x is not null loop
          insert into public.notifications (user_id, body) values (r, 'Your ' || subj || ' session was cancelled.');
        end loop;
      else
        insert into public.notifications (user_id, body) values (new.mentor_id, 'Your ' || subj || ' session was cancelled.');
        for r in select user_id from public.session_members where session_id = new.id and user_id <> auth.uid() loop
          insert into public.notifications (user_id, body) values (r, 'Your ' || subj || ' session was cancelled.');
        end loop;
      end if;
    elsif new.status = 'completed' then
      update public.mentor_profiles set sessions_taught = sessions_taught + 1 where id = new.mentor_id;
      for r in select x from (select new.learner_id as x union select user_id from public.session_members where session_id = new.id) q where x is not null loop
        insert into public.notifications (user_id, body) values (r, 'How was ' || subj || '? Leave a rating for your mentor.');
      end loop;
    end if;
  end if;
  return new;
end;
$$;

-- ---------- 5) Join, leave and invite
create or replace function public.join_group_session(sid uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  me   uuid := auth.uid();
  who  text;
  subj text;
begin
  select * into s from public.sessions where id = sid for update;
  if not found then raise exception 'That session no longer exists.'; end if;
  if s.kind <> 'group' or s.learner_id is not null then raise exception 'You can only join open group classes.'; end if;
  if s.status <> 'confirmed' or s.ends_at <= now() then raise exception 'This group class is no longer open.'; end if;
  if me = s.mentor_id then raise exception 'You are the mentor of this class.'; end if;
  if not exists (select 1 from public.profiles where id = me and role in ('learner', 'both') and status = 'active') then
    raise exception 'Only student accounts can join group classes.';
  end if;
  if exists (select 1 from public.session_members where session_id = sid and user_id = me) then return; end if;
  if public.session_seats_taken(sid) >= s.capacity then raise exception 'This group class is full.'; end if;
  insert into public.session_members (session_id, user_id) values (sid, me);
  select full_name into who from public.profiles where id = me;
  select name into subj from public.subjects where id = s.subject_id;
  insert into public.notifications (user_id, body)
    values (s.mentor_id, coalesce(who, 'A student') || ' joined your ' || coalesce(subj, 'group') || ' class.');
end;
$$;

create or replace function public.leave_group_session(sid uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  who  text;
  subj text;
begin
  select * into s from public.sessions where id = sid;
  if not found then return; end if;
  delete from public.session_members where session_id = sid and user_id = auth.uid();
  if found then
    select full_name into who from public.profiles where id = auth.uid();
    select name into subj from public.subjects where id = s.subject_id;
    insert into public.notifications (user_id, body)
      values (s.mentor_id, coalesce(who, 'A student') || ' left your ' || coalesce(subj, 'group') || ' session.');
  end if;
end;
$$;

create or replace function public.invite_to_session(sid uuid, invitee_email text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  s       public.sessions%rowtype;
  me      uuid := auth.uid();
  t       public.profiles%rowtype;
  inviter text;
  subj    text;
  cap     integer;
begin
  select * into s from public.sessions where id = sid for update;
  if not found then raise exception 'That session no longer exists.'; end if;
  if not public.is_session_member(sid) then raise exception 'Only people in this session can add classmates.'; end if;
  if s.status not in ('pending', 'confirmed') or s.ends_at <= now() then raise exception 'You can only add classmates to upcoming sessions.'; end if;
  select * into t from public.profiles where email = lower(trim(invitee_email));
  if not found then raise exception 'No KnowHow account uses that Gmail yet. Ask your classmate to sign up first.'; end if;
  if t.role not in ('learner', 'both') or t.status <> 'active' then raise exception 'That account is not an active student account.'; end if;
  if t.id in (s.mentor_id, coalesce(s.learner_id, '00000000-0000-0000-0000-000000000000'::uuid))
     or exists (select 1 from public.session_members where session_id = sid and user_id = t.id) then
    raise exception '% is already in this session.', split_part(t.full_name, ' ', 1);
  end if;
  cap := s.capacity;
  if s.kind = 'one' then
    update public.sessions set kind = 'group', capacity = 8 where id = sid;
    cap := 8;
  end if;
  if public.session_seats_taken(sid) >= cap then raise exception 'This session is full (% students).', cap; end if;
  insert into public.session_members (session_id, user_id, invited_by) values (sid, t.id, me);
  select full_name into inviter from public.profiles where id = me;
  select name into subj from public.subjects where id = s.subject_id;
  insert into public.notifications (user_id, body)
    values (t.id, coalesce(inviter, 'A classmate') || ' added you to a ' || coalesce(subj, 'tutoring') || ' session on '
                  || to_char(s.starts_at at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM') || '.');
  return t.full_name;
end;
$$;

revoke execute on function public.join_group_session(uuid) from public, anon;
revoke execute on function public.leave_group_session(uuid) from public, anon;
revoke execute on function public.invite_to_session(uuid, text) from public, anon;
grant  execute on function public.join_group_session(uuid) to authenticated;
grant  execute on function public.leave_group_session(uuid) to authenticated;
grant  execute on function public.invite_to_session(uuid, text) to authenticated;

-- ---------- 6) One review per student (group sessions get a review from each student)
alter table public.reviews drop constraint if exists reviews_session_id_key;
create unique index if not exists reviews_one_per_student on public.reviews (session_id, learner_id);
drop policy if exists "reviews: learner after completed session" on public.reviews;
create policy "reviews: learner after completed session" on public.reviews for insert to authenticated
  with check (
    learner_id = auth.uid()
    and exists (
      select 1 from public.sessions s
      where s.id = reviews.session_id
        and s.mentor_id = reviews.mentor_id
        and s.status = 'completed'
        and (s.learner_id = auth.uid()
             or exists (select 1 from public.session_members m where m.session_id = s.id and m.user_id = auth.uid()))
    )
  );

-- ---------------------------------------------------------------------
-- Health report: nothing should say MISSING
-- ---------------------------------------------------------------------
select 'session_members table' as "check",
       case when exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name = 'session_members' and grantee = 'authenticated')
            then 'OK' else 'MISSING' end as "status"
union all
select 'sessions.kind / capacity',
       case when (select count(*) from information_schema.columns
                  where table_schema = 'public' and table_name = 'sessions' and column_name in ('kind', 'capacity')) = 2
            then 'OK' else 'MISSING' end
union all
select 'join / leave / invite functions',
       case when (select count(*) from pg_proc where proname in ('join_group_session', 'leave_group_session', 'invite_to_session')) = 3
            then 'OK' else 'MISSING' end
union all
select 'one review per student',
       case when exists (select 1 from pg_indexes where indexname = 'reviews_one_per_student') then 'OK' else 'MISSING' end;
