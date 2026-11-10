-- =====================================================================
-- PINDI CRUST — give an account admin access
-- ---------------------------------------------------------------------
-- 1. The person must sign up on the website first (email or Google).
-- 2. Supabase → SQL Editor → New query → paste this → change the email
--    and role on the two lines marked  <-- CHANGE  → Run.
--
-- Roles: 'developer' (full access, can manage admins)
--        'admin'     (owner: everything incl. settings, deleting, staff)
--        'manager'   (staff: orders, POS, kitchen, menu)
--        'customer'  (removes staff access)
-- =====================================================================
do $$
declare
  v_email text := 'you@example.com';   -- <-- CHANGE: the email they signed up with
  v_role  text := 'admin';             -- <-- CHANGE: developer / admin / manager / customer
  v_id    uuid;
begin
  if v_role not in ('customer', 'manager', 'admin', 'developer') then
    raise exception 'Role must be customer, manager, admin or developer (you typed "%").', v_role;
  end if;

  select id into v_id from auth.users where lower(email) = lower(trim(v_email));
  if v_id is null then
    raise exception 'No account found for "%". Sign up on the website with this email first, then run this again.', v_email;
  end if;

  -- Create the profile if the sign-up happened before the database design was installed.
  insert into public.profiles (id, email, role)
  values (v_id, lower(trim(v_email)), 'customer')
  on conflict (id) do nothing;

  -- Setting profiles.role automatically updates user_roles (used for all permission checks).
  update public.profiles set role = v_role, is_blocked = false where id = v_id;

  raise notice 'Done: % is now %.', v_email, v_role;
end $$;

-- Check the result (both columns should show the new role):
select p.email, p.role as profile_role,
       (select string_agg(r.role::text, ', ') from public.user_roles r where r.user_id = p.id) as permission_role
  from public.profiles p
 where p.role <> 'customer'
 order by p.email;
