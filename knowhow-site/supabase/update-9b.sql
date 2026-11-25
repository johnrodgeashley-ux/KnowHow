-- =====================================================================
-- KnowHow · update 9b (run ONCE in Supabase > SQL Editor, after update 9)
--   * Lets the push function (server role) read its settings and the device list.
--   * Points the database at the deployed function's address.
--   * Lets the website read the public push key from the database (no fixed function name needed).
-- Safe to run more than once.
-- =====================================================================

-- The server role needs table access too (this project doesn't grant new tables automatically)
grant select, insert, update on public.push_config to service_role;
grant select, delete on public.push_subscriptions to service_role;

-- The push function was deployed at /functions/v1/swift-worker
update public.push_config
   set function_url = 'https://ltskaojuutggtiabzqbr.supabase.co/functions/v1/swift-worker'
 where id = 1;

-- The website asks the database for the public key (safe to share; the private key never leaves the server)
create or replace function public.push_public_key()
returns text
language sql stable security definer set search_path = public
as $$
  select vapid_public from public.push_config where id = 1;
$$;
revoke execute on function public.push_public_key() from public, anon;
grant  execute on function public.push_public_key() to authenticated;

select 'server role can read push settings' as "check",
       case when has_table_privilege('service_role', 'public.push_config', 'SELECT') then 'OK' else 'MISSING' end as "status"
union all
select 'function address', coalesce((select function_url from public.push_config where id = 1), 'MISSING');
