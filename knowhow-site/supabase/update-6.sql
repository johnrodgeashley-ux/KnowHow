-- =====================================================================
-- KnowHow · update 6 (run ONCE in Supabase > SQL Editor, after update 5)
--   * "Seen" time on messages (read_at)
--   * Emoji reactions on messages, with live updates
-- Safe to run more than once. The last query prints a health report.
-- =====================================================================

-- ---------- 1) Seen time
alter table public.messages add column if not exists read_at timestamptz;

-- Recipients may only flip "read"; the database stamps when it was seen
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
  if new.read and not old.read then
    new.read_at := now();
  elsif not new.read then
    new.read_at := null;
  else
    new.read_at := old.read_at;
  end if;
  return new;
end;
$$;
drop trigger if exists messages_protect on public.messages;
create trigger messages_protect
  before update on public.messages
  for each row execute function public.protect_message_fields();

-- ---------- 2) Reactions (one per person per message; change or remove it any time)
create table if not exists public.message_reactions (
  message_id  uuid not null references public.messages (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  emoji       text not null check (char_length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  primary key (message_id, user_id)
);

alter table public.message_reactions enable row level security;
grant select, insert, update, delete on public.message_reactions to authenticated;

-- Only the two people in the conversation can see or react
create or replace function public.in_message(mid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.messages m
    where m.id = mid and auth.uid() in (m.sender_id, m.recipient_id)
  );
$$;
revoke execute on function public.in_message(uuid) from public, anon;
grant  execute on function public.in_message(uuid) to authenticated;

drop policy if exists "reactions: read in my chats" on public.message_reactions;
create policy "reactions: read in my chats" on public.message_reactions for select to authenticated
  using (public.in_message(message_id));

drop policy if exists "reactions: add own" on public.message_reactions;
create policy "reactions: add own" on public.message_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.in_message(message_id));

drop policy if exists "reactions: change own" on public.message_reactions;
create policy "reactions: change own" on public.message_reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.in_message(message_id));

drop policy if exists "reactions: remove own" on public.message_reactions;
create policy "reactions: remove own" on public.message_reactions for delete to authenticated
  using (user_id = auth.uid());

-- Live updates (Supabase Realtime)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end $$;

-- ---------- 3) Verified credentials can be viewed by any logged-in user
-- (pending or rejected files stay private to the mentor and admins)
drop policy if exists "credentials: verified files readable" on storage.objects;
create policy "credentials: verified files readable" on storage.objects for select to authenticated
  using (
    bucket_id = 'credentials'
    and exists (
      select 1 from public.credentials c
      where c.file_path = storage.objects.name and c.status = 'verified'
    )
  );

-- ---------- 4) Admins manage the subject list (add, rename, category, critical, remove)
alter type public.subject_category add value if not exists 'General Education';
alter type public.subject_category add value if not exists 'Other';

grant insert, update, delete on public.subjects to authenticated;
do $$
declare seq text := pg_get_serial_sequence('public.subjects', 'id');
begin
  if seq is not null then execute format('grant usage on sequence %s to authenticated', seq); end if;
end $$;

drop policy if exists "subjects: admin add" on public.subjects;
create policy "subjects: admin add" on public.subjects for insert to authenticated
  with check (public.is_admin());
drop policy if exists "subjects: admin edit" on public.subjects;
create policy "subjects: admin edit" on public.subjects for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists "subjects: admin remove" on public.subjects;
create policy "subjects: admin remove" on public.subjects for delete to authenticated
  using (public.is_admin());

-- ---------------------------------------------------------------------
-- Health report: nothing should say MISSING
-- ---------------------------------------------------------------------
select t.table_name as "table",
       coalesce(string_agg(distinct g.privilege_type, ', '), 'MISSING') as "website can"
from (values ('messages'),('message_reactions'),('subjects')) as t(table_name)
left join information_schema.role_table_grants g
  on g.table_schema = 'public' and g.table_name = t.table_name and g.grantee = 'authenticated'
group by t.table_name
union all
select 'messages.read_at',
       case when exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'messages' and column_name = 'read_at')
            then 'OK' else 'MISSING' end
union all
select 'verified credentials viewable',
       case when exists (select 1 from pg_policies
                         where schemaname = 'storage' and tablename = 'objects'
                           and policyname = 'credentials: verified files readable')
            then 'OK' else 'MISSING' end
union all
select 'live reactions',
       case when exists (select 1 from pg_publication_tables
                         where pubname = 'supabase_realtime' and tablename = 'message_reactions')
            then 'OK' else 'MISSING' end
order by 1;
