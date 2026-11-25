-- =====================================================================
-- KnowHow · allow a non-Gmail admin email
-- Run this ONCE in Supabase > SQL Editor (your schema is already installed).
--
-- Students must still sign up with Gmail. Emails on this list are the only
-- exception. The list can only be changed here in the SQL Editor; the app
-- and students cannot read or change it.
-- =====================================================================

-- 1) The exception list
create table if not exists public.allowed_non_gmail (
  email       text primary key check (email = lower(email)),
  note        text,
  created_at  timestamptz not null default now()
);
alter table public.allowed_non_gmail enable row level security;
revoke all on public.allowed_non_gmail from anon, authenticated;

-- 2) Sign-up rule: Gmail, or an email on the exception list
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
             nullif(new.raw_user_meta_data ->> 'name', ''),
             split_part(new.email, '@', 1)),
    nullif(new.raw_user_meta_data ->> 'student_no', ''),
    coalesce(new.raw_user_meta_data ->> 'course', ''),
    coalesce(new.raw_user_meta_data ->> 'year_level', ''),
    coalesce(nullif(lower(new.raw_user_meta_data ->> 'role'), '')::public.user_role, 'learner'),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  );

  insert into public.activity_log (actor_id, action) values (new.id, 'signed up');
  return new;
end;
$$;

-- 3) Put the admin's email on the list (change it to the real one, lowercase)
insert into public.allowed_non_gmail (email, note)
values ('admin@example.com', 'KnowHow admin')
on conflict (email) do nothing;

-- =====================================================================
-- NEXT STEPS (not part of this script)
--   a) Authentication > Users > Add user > Create new user
--      Email: the same email as above · Password: your choice · tick "Auto Confirm User"
--   b) Then run:
--        update public.profiles
--           set is_admin = true, id_verified = true, full_name = 'KnowHow Admin'
--         where email = 'admin@example.com';
--   c) Log in on the site with that email and password.
-- =====================================================================
