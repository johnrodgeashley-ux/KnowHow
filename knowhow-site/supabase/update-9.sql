-- =====================================================================
-- KnowHow · update 9 (run ONCE in Supabase > SQL Editor, after update 8)
--   * Push notifications: phones and computers get KnowHow notifications even when the app is closed.
--     Sent by the "push" Edge Function; its keys are created and kept inside your Supabase.
--   * Session reminders 15 minutes before each confirmed session (every 5 minutes, pg_cron).
--   * Admins can cancel any session.
-- Safe to run more than once. The last query prints a health report.
-- =====================================================================

create extension if not exists pg_net;

-- ---------- 1) Devices that want notifications
create table if not exists public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
grant select, delete on public.push_subscriptions to authenticated;
drop policy if exists "push: own devices" on public.push_subscriptions;
create policy "push: own devices" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists "push: remove own devices" on public.push_subscriptions;
create policy "push: remove own devices" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- A device belongs to whoever is logged in on it now (handles shared phones and computers)
create or replace function public.save_push_subscription(ep text, p256dh text, auth_key text, ua text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Log in first.'; end if;
  if ep !~ '^https://' or char_length(ep) > 1000 then raise exception 'That notification address is not valid.'; end if;
  delete from public.push_subscriptions where endpoint = ep;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
    values (auth.uid(), ep, p256dh, auth_key, left(ua, 200));
end;
$$;
create or replace function public.remove_push_subscription(ep text)
returns void
language sql security definer set search_path = public
as $$
  delete from public.push_subscriptions where endpoint = ep and user_id = auth.uid();
$$;
revoke execute on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke execute on function public.remove_push_subscription(text) from public, anon;
grant  execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant  execute on function public.remove_push_subscription(text) to authenticated;

-- ---------- 2) Settings only the server can read (keys are created by the push function)
create table if not exists public.push_config (
  id            integer primary key default 1 check (id = 1),
  vapid_public  text,
  vapid_private text,
  hook_secret   text,
  function_url  text
);
alter table public.push_config enable row level security;   -- no policies: only the server (service role) can read it
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id, hook_secret, function_url)
  values (1, replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
          'https://ltskaojuutggtiabzqbr.supabase.co/functions/v1/push')
  on conflict (id) do update
    set function_url = excluded.function_url,
        hook_secret = coalesce(public.push_config.hook_secret, excluded.hook_secret);

-- Ask the push function to deliver one notification (never blocks or breaks the original action)
create or replace function public.push_notify(target uuid, title text, msg text, tag text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  cfg public.push_config%rowtype;
begin
  if target is null then return; end if;
  if not exists (select 1 from public.push_subscriptions where user_id = target) then return; end if;
  select * into cfg from public.push_config where id = 1;
  if not found or cfg.function_url is null or cfg.hook_secret is null then return; end if;
  perform net.http_post(
    url := cfg.function_url,
    body := jsonb_build_object('user_id', target, 'title', title, 'body', msg, 'tag', tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-kh-secret', cfg.hook_secret)
  );
exception when others then
  null;
end;
$$;
revoke execute on function public.push_notify(uuid, text, text, text) from public, anon, authenticated;

-- Every KnowHow notification also goes out as a push notification
create or replace function public.on_notification_push()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform public.push_notify(new.user_id, 'KnowHow', new.body, 'n-' || new.id);
  return new;
end;
$$;
drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push after insert on public.notifications
  for each row execute function public.on_notification_push();

-- New chat messages too
create or replace function public.on_message_push()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  who text;
begin
  select full_name into who from public.profiles where id = new.sender_id;
  perform public.push_notify(new.recipient_id, coalesce(who, 'New message'),
                             left(new.body, 140) || case when char_length(new.body) > 140 then '…' else '' end,
                             'msg-' || new.sender_id);
  return new;
end;
$$;
drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages
  for each row execute function public.on_message_push();

-- ---------- 3) Reminders 15 minutes before confirmed sessions
alter table public.sessions add column if not exists reminded_at timestamptz;

create or replace function public.send_session_reminders()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  subj text;
  r    uuid;
  n    integer := 0;
begin
  for s in
    select * from public.sessions
    where status = 'confirmed' and reminded_at is null
      and starts_at between now() + interval '2 minutes' and now() + interval '20 minutes'
  loop
    update public.sessions set reminded_at = now() where id = s.id;
    select name into subj from public.subjects where id = s.subject_id;
    for r in select x from (select s.mentor_id as x union select s.learner_id union select user_id from public.session_members where session_id = s.id) q where x is not null loop
      insert into public.notifications (user_id, body)
        values (r, coalesce(subj, 'Your session') || ' starts at ' || to_char(s.starts_at at time zone 'Asia/Manila', 'HH12:MI AM')
                   || '. Open KnowHow and tap Join call.');
    end loop;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.send_session_reminders() from public, anon, authenticated;

-- Run it every 5 minutes (needs the pg_cron extension, which Supabase includes)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('knowhow-session-reminders', '*/5 * * * *', 'select public.send_session_reminders()');
exception when others then
  raise notice 'Could not schedule reminders automatically: %. Turn on pg_cron in Database > Extensions and run this file again.', sqlerrm;
end $$;

-- ---------- 4) Admins can cancel any session
create or replace function public.admin_cancel_session(sid uuid, reason text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  s    public.sessions%rowtype;
  subj text;
  r    uuid;
begin
  if not public.is_admin() then raise exception 'Admins only.'; end if;
  select * into s from public.sessions where id = sid for update;
  if not found then raise exception 'That session no longer exists.'; end if;
  if s.status not in ('pending', 'confirmed') then raise exception 'Only upcoming sessions can be cancelled.'; end if;
  update public.sessions set status = 'cancelled' where id = sid;
  select name into subj from public.subjects where id = s.subject_id;
  for r in select x from (select s.mentor_id as x union select s.learner_id union select user_id from public.session_members where session_id = sid) q where x is not null loop
    insert into public.notifications (user_id, body)
      values (r, 'A KnowHow admin cancelled your ' || coalesce(subj, 'tutoring') || ' session'
                 || coalesce(': ' || nullif(trim(reason), ''), '') || '.');
  end loop;
  insert into public.activity_log (actor_id, action) values (auth.uid(), 'cancelled a ' || coalesce(subj, '') || ' session');
end;
$$;
revoke execute on function public.admin_cancel_session(uuid, text) from public, anon;
grant  execute on function public.admin_cancel_session(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Health report: nothing should say MISSING
-- ---------------------------------------------------------------------
select 'push subscriptions' as "check",
       case when exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'push_subscriptions')
            then 'OK' else 'MISSING' end as "status"
union all
select 'pg_net (sends to the push function)',
       case when exists (select 1 from pg_extension where extname = 'pg_net') then 'OK' else 'MISSING' end
union all
select 'push triggers',
       case when (select count(*) from pg_trigger where tgname in ('notifications_push', 'messages_push')) = 2 then 'OK' else 'MISSING' end
union all
select 'reminders every 5 minutes (pg_cron)',
       case when exists (select 1 from pg_extension where extname = 'pg_cron') then 'OK' else 'MISSING — turn on pg_cron and run again' end
union all
select 'admin can cancel sessions',
       case when exists (select 1 from pg_proc where proname = 'admin_cancel_session') then 'OK' else 'MISSING' end;
