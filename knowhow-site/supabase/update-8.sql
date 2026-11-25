-- =====================================================================
-- KnowHow · update 8 (run ONCE in Supabase > SQL Editor, after update 7)
--   * No double-booking: a mentor (or a student) can't have two sessions at the same time.
--   * Reschedule: suggest a new time; the other person accepts or declines.
--   * Mentors' private details: backup Zoom link and GCash number, shown only to their students.
--   * Payment tracking: students mark "I've paid", mentors confirm "Paid". No money moves through KnowHow.
-- Safe to run more than once. The last query prints a health report.
-- =====================================================================

-- ---------- 1) No double-booking
create or replace function public.check_session_overlap()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.status not in ('pending', 'confirmed') then return new; end if;
  if tg_op = 'UPDATE' and new.starts_at = old.starts_at and new.ends_at = old.ends_at and new.status = old.status then
    return new;
  end if;
  if exists (
    select 1 from public.sessions s
    where s.mentor_id = new.mentor_id and s.id <> new.id and s.status in ('pending', 'confirmed')
      and tstzrange(s.starts_at, s.ends_at) && tstzrange(new.starts_at, new.ends_at)
  ) then
    raise exception 'That time is already booked with this mentor. Please pick another time.' using errcode = '23P01';
  end if;
  if new.learner_id is not null and exists (
    select 1 from public.sessions s
    where s.id <> new.id and s.status in ('pending', 'confirmed')
      and (s.learner_id = new.learner_id
           or exists (select 1 from public.session_members m where m.session_id = s.id and m.user_id = new.learner_id))
      and tstzrange(s.starts_at, s.ends_at) && tstzrange(new.starts_at, new.ends_at)
  ) then
    raise exception 'You already have another session at that time.' using errcode = '23P01';
  end if;
  return new;
end;
$$;
drop trigger if exists sessions_no_overlap on public.sessions;
create trigger sessions_no_overlap
  before insert or update on public.sessions
  for each row execute function public.check_session_overlap();

-- Busy times of a mentor on one day (times only, no names) so the booking form can grey them out
create or replace function public.mentor_busy(mid uuid, day date)
returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.starts_at, s.ends_at
  from public.sessions s
  where s.mentor_id = mid and s.status in ('pending', 'confirmed')
    and s.starts_at < ((day + 1)::timestamp at time zone 'Asia/Manila')
    and s.ends_at   > (day::timestamp at time zone 'Asia/Manila');
$$;
revoke execute on function public.mentor_busy(uuid, date) from public, anon;
grant  execute on function public.mentor_busy(uuid, date) to authenticated;

-- ---------- 2) Reschedule
alter table public.sessions add column if not exists proposed_starts_at timestamptz;
alter table public.sessions add column if not exists proposed_ends_at timestamptz;
alter table public.sessions add column if not exists proposed_by uuid references public.profiles (id) on delete set null;

create or replace function public.propose_reschedule(sid uuid, new_start timestamptz, new_end timestamptz)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  me   uuid := auth.uid();
  subj text;
  who  text;
  r    uuid;
  whn  text;
begin
  select * into s from public.sessions where id = sid for update;
  if not found then raise exception 'That session no longer exists.'; end if;
  if s.status not in ('pending', 'confirmed') then raise exception 'Only upcoming sessions can be moved.'; end if;
  if new_end <= new_start then raise exception 'The new end time must be after the start time.'; end if;
  if new_start < now() then raise exception 'Pick a time in the future.'; end if;
  if me is distinct from s.mentor_id and me is distinct from s.learner_id then
    raise exception 'Only the mentor or the student who booked can move this session.';
  end if;
  select name into subj from public.subjects where id = s.subject_id;
  select full_name into who from public.profiles where id = me;
  whn := to_char(new_start at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM');

  if s.kind = 'group' and me = s.mentor_id then
    update public.sessions
       set starts_at = new_start, ends_at = new_end, proposed_starts_at = null, proposed_ends_at = null, proposed_by = null
     where id = sid;
    for r in select x from (select s.learner_id as x union select user_id from public.session_members where session_id = sid) q where x is not null loop
      insert into public.notifications (user_id, body)
        values (r, coalesce(who, 'Your mentor') || ' moved the ' || coalesce(subj, 'group') || ' class to ' || whn || '.');
    end loop;
    return 'moved';
  end if;

  update public.sessions set proposed_starts_at = new_start, proposed_ends_at = new_end, proposed_by = me where id = sid;
  insert into public.notifications (user_id, body)
    values (case when me = s.mentor_id then s.learner_id else s.mentor_id end,
            coalesce(who, 'Someone') || ' suggested moving your ' || coalesce(subj, 'tutoring') || ' session to ' || whn || '. Open the session to accept or decline.');
  return 'proposed';
end;
$$;

create or replace function public.respond_reschedule(sid uuid, accept boolean)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  me   uuid := auth.uid();
  subj text;
  who  text;
  r    uuid;
begin
  select * into s from public.sessions where id = sid for update;
  if not found then raise exception 'That session no longer exists.'; end if;
  if s.proposed_by is null then raise exception 'There is no new time waiting for an answer.'; end if;
  if me is distinct from s.mentor_id and me is distinct from s.learner_id then raise exception 'You are not part of this session.'; end if;
  select name into subj from public.subjects where id = s.subject_id;
  select full_name into who from public.profiles where id = me;

  if accept then
    if me = s.proposed_by then raise exception 'The other person needs to accept your suggestion.'; end if;
    update public.sessions
       set starts_at = s.proposed_starts_at, ends_at = s.proposed_ends_at, proposed_starts_at = null, proposed_ends_at = null, proposed_by = null
     where id = sid;
    for r in select x from (select s.proposed_by as x union select user_id from public.session_members where session_id = sid) q where x is not null and x <> me loop
      insert into public.notifications (user_id, body)
        values (r, coalesce(who, 'Someone') || ' accepted the new time for ' || coalesce(subj, 'your') || ' session: '
                   || to_char(s.proposed_starts_at at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM') || '.');
    end loop;
    return 'accepted';
  end if;

  update public.sessions set proposed_starts_at = null, proposed_ends_at = null, proposed_by = null where id = sid;
  if me <> s.proposed_by then
    insert into public.notifications (user_id, body)
      values (s.proposed_by, coalesce(who, 'Someone') || ' kept the original time for ' || coalesce(subj, 'your') || ' session.');
  end if;
  return 'declined';
end;
$$;

revoke execute on function public.propose_reschedule(uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.respond_reschedule(uuid, boolean) from public, anon;
grant  execute on function public.propose_reschedule(uuid, timestamptz, timestamptz) to authenticated;
grant  execute on function public.respond_reschedule(uuid, boolean) to authenticated;

-- ---------- 3) Mentors' private details (backup Zoom link, GCash)
create table if not exists public.mentor_private (
  mentor_id     uuid primary key references public.mentor_profiles (id) on delete cascade,
  zoom_url      text check (zoom_url is null or zoom_url ~* '^https://([a-z0-9-]+\.)*zoom\.us/\S+$'),
  gcash_number  text check (gcash_number is null or gcash_number ~ '^(09|\+639)[0-9]{9}$'),
  gcash_name    text check (gcash_name is null or char_length(gcash_name) <= 80),
  updated_at    timestamptz not null default now()
);
alter table public.mentor_private enable row level security;
grant select, insert, update on public.mentor_private to authenticated;
drop policy if exists "mentor private: own" on public.mentor_private;
create policy "mentor private: own" on public.mentor_private for all to authenticated
  using (mentor_id = auth.uid()) with check (mentor_id = auth.uid());

-- Students in a session (and its mentor) can read that mentor's backup link and GCash details
create or replace function public.session_extras(sid uuid)
returns table (zoom_url text, gcash_number text, gcash_name text)
language sql stable security definer set search_path = public
as $$
  select mp.zoom_url, mp.gcash_number, mp.gcash_name
  from public.sessions s
  join public.mentor_private mp on mp.mentor_id = s.mentor_id
  where s.id = sid and public.is_session_member(sid);
$$;
revoke execute on function public.session_extras(uuid) from public, anon;
grant  execute on function public.session_extras(uuid) to authenticated;

-- ---------- 4) Payment tracking (each student pays the mentor's full rate)
create table if not exists public.session_payments (
  session_id  uuid not null references public.sessions (id) on delete cascade,
  student_id  uuid not null references public.profiles (id) on delete cascade,
  amount_php  numeric(10, 2) not null check (amount_php >= 0),
  status      text not null default 'unpaid' check (status in ('unpaid', 'sent', 'paid')),
  reference   text check (reference is null or char_length(reference) <= 60),
  updated_at  timestamptz not null default now(),
  primary key (session_id, student_id)
);
alter table public.session_payments enable row level security;
grant select on public.session_payments to authenticated;     -- changes only through the functions below
drop policy if exists "payments: student, mentor or admin read" on public.session_payments;
create policy "payments: student, mentor or admin read" on public.session_payments for select to authenticated
  using (
    student_id = auth.uid()
    or exists (select 1 from public.sessions s where s.id = session_id and s.mentor_id = auth.uid())
    or public.is_admin()
  );

create or replace function public.session_price(sid uuid)
returns numeric
language sql stable security definer set search_path = public
as $$
  select round(coalesce(m.rate_php, 0) * extract(epoch from (s.ends_at - s.starts_at)) / 3600, 2)
  from public.sessions s join public.mentor_profiles m on m.id = s.mentor_id
  where s.id = sid;
$$;

create or replace function public.mark_payment_sent(sid uuid, ref text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  me   uuid := auth.uid();
  amt  numeric;
  who  text;
  subj text;
begin
  select * into s from public.sessions where id = sid;
  if not found then raise exception 'That session no longer exists.'; end if;
  if not (s.learner_id = me or exists (select 1 from public.session_members where session_id = sid and user_id = me)) then
    raise exception 'Only students in this session can mark a payment.';
  end if;
  if s.status not in ('confirmed', 'completed') then raise exception 'You can pay once the session is confirmed.'; end if;
  amt := public.session_price(sid);
  insert into public.session_payments (session_id, student_id, amount_php, status, reference, updated_at)
    values (sid, me, amt, 'sent', nullif(trim(ref), ''), now())
    on conflict (session_id, student_id) do update
      set status = case when public.session_payments.status = 'paid' then 'paid' else 'sent' end,
          reference = coalesce(nullif(trim(excluded.reference), ''), public.session_payments.reference),
          amount_php = excluded.amount_php, updated_at = now();
  select full_name into who from public.profiles where id = me;
  select name into subj from public.subjects where id = s.subject_id;
  insert into public.notifications (user_id, body)
    values (s.mentor_id, coalesce(who, 'A student') || ' says they paid ₱' || to_char(amt, 'FM999,990') || ' for ' || coalesce(subj, 'a')
                         || ' session' || coalesce(' (ref ' || nullif(trim(ref), '') || ')', '') || '. Check your GCash and mark it paid.');
end;
$$;

create or replace function public.set_payment_status(sid uuid, student uuid, new_status text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  amt  numeric;
  who  text;
  subj text;
begin
  if new_status not in ('unpaid', 'paid') then raise exception 'Choose paid or unpaid.'; end if;
  select * into s from public.sessions where id = sid;
  if not found then raise exception 'That session no longer exists.'; end if;
  if auth.uid() is distinct from s.mentor_id then raise exception 'Only the mentor can confirm payments.'; end if;
  if not (s.learner_id = student or exists (select 1 from public.session_members where session_id = sid and user_id = student)) then
    raise exception 'That student is not in this session.';
  end if;
  amt := public.session_price(sid);
  insert into public.session_payments (session_id, student_id, amount_php, status, updated_at)
    values (sid, student, amt, new_status, now())
    on conflict (session_id, student_id) do update set status = excluded.status, updated_at = now();
  if new_status = 'paid' then
    select full_name into who from public.profiles where id = s.mentor_id;
    select name into subj from public.subjects where id = s.subject_id;
    insert into public.notifications (user_id, body)
      values (student, coalesce(who, 'Your mentor') || ' confirmed your payment for ' || coalesce(subj, 'your') || ' session. Thank you!');
  end if;
end;
$$;

revoke execute on function public.session_price(uuid) from public, anon;
revoke execute on function public.mark_payment_sent(uuid, text) from public, anon;
revoke execute on function public.set_payment_status(uuid, uuid, text) from public, anon;
grant  execute on function public.session_price(uuid) to authenticated;
grant  execute on function public.mark_payment_sent(uuid, text) to authenticated;
grant  execute on function public.set_payment_status(uuid, uuid, text) to authenticated;

-- ---------- 5) Comments on study feed posts
create table if not exists public.post_comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts (id) on delete cascade,
  author_id   uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index if not exists post_comments_post on public.post_comments (post_id, created_at);
alter table public.post_comments enable row level security;
grant select, insert, delete on public.post_comments to authenticated;

drop policy if exists "comments: read" on public.post_comments;
create policy "comments: read" on public.post_comments for select to authenticated using (true);
drop policy if exists "comments: write own" on public.post_comments;
create policy "comments: write own" on public.post_comments for insert to authenticated
  with check (
    author_id = auth.uid()
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active')
  );
drop policy if exists "comments: delete own or admin" on public.post_comments;
create policy "comments: delete own or admin" on public.post_comments for delete to authenticated
  using (author_id = auth.uid() or public.is_admin());

-- The time is set by the database, and the post's author gets a notification
create or replace function public.on_post_comment()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  owner uuid;
  who   text;
begin
  select author_id into owner from public.posts where id = new.post_id;
  if owner is not null and owner <> new.author_id then
    select full_name into who from public.profiles where id = new.author_id;
    insert into public.notifications (user_id, body)
      values (owner, coalesce(who, 'Someone') || ' commented on your post: “' || left(new.body, 60) || case when char_length(new.body) > 60 then '…' else '' end || '”');
  end if;
  return new;
end;
$$;
create or replace function public.protect_comment_fields()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated', 'anon') then new.created_at := now(); end if;
  return new;
end;
$$;
drop trigger if exists post_comments_protect on public.post_comments;
create trigger post_comments_protect before insert on public.post_comments
  for each row execute function public.protect_comment_fields();
drop trigger if exists post_comments_notify on public.post_comments;
create trigger post_comments_notify after insert on public.post_comments
  for each row execute function public.on_post_comment();

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'post_comments') then
    alter publication supabase_realtime add table public.post_comments;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Health report: nothing should say MISSING
-- ---------------------------------------------------------------------
select 'no double-booking check' as "check",
       case when exists (select 1 from pg_trigger where tgname = 'sessions_no_overlap') then 'OK' else 'MISSING' end as "status"
union all
select 'reschedule (columns + functions)',
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'sessions'
                  and column_name in ('proposed_starts_at', 'proposed_ends_at', 'proposed_by')) = 3
             and (select count(*) from pg_proc where proname in ('propose_reschedule', 'respond_reschedule')) = 2
            then 'OK' else 'MISSING' end
union all
select 'mentor private details',
       case when exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name = 'mentor_private' and grantee = 'authenticated')
            then 'OK' else 'MISSING' end
union all
select 'payment tracking',
       case when exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name = 'session_payments' and grantee = 'authenticated')
             and (select count(*) from pg_proc where proname in ('mark_payment_sent', 'set_payment_status')) = 2
            then 'OK' else 'MISSING' end
union all
select 'comments on posts',
       case when exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name = 'post_comments' and grantee = 'authenticated')
            then 'OK' else 'MISSING' end;
