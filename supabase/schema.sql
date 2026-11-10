-- =====================================================================
-- PINDI CRUST — complete Supabase database design
-- ---------------------------------------------------------------------
-- How to use:
--   Supabase dashboard → SQL Editor → New query → paste this whole file
--   → Run. It is safe to run again later (it updates what already exists).
--
-- Contains: roles, all tables, security rules (RLS), order/pricing logic,
-- order tracking, payment verification, notifications, analytics, reports,
-- activity log, realtime for live orders, and sign-up profile creation
-- (email + Google).
--
-- Roles:  customer  – normal shopper (everyone who signs up)
--         manager   – staff: orders, POS, kitchen, menu edits
--         admin     – owner: everything above + deleting, settings,
--                     blocking customers, promoting staff
--         developer – full access, incl. managing admins/developers
-- The real permission check is the user_roles table. profiles.role is a
-- read-only mirror the app displays; changing it goes through guarded
-- rules below and automatically updates user_roles.
-- =====================================================================

-- Supabase API roles must be able to use the schema.
grant usage on schema public to anon, authenticated, service_role;

-- Timezone used for "per day" / "per hour" analytics.
create or replace function public.store_tz() returns text
language sql immutable set search_path = public as $$ select 'Asia/Karachi'::text $$;

-- Generic "updated_at = now()" trigger.
create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- =====================================================================
-- 1. ROLES & PROFILES
-- =====================================================================
do $$ begin
  create type public.app_role as enum ('customer', 'manager', 'admin', 'developer');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null default '',
  name        text,
  phone       text,
  role        text not null default 'customer'
              check (role in ('customer', 'manager', 'admin', 'developer')),
  is_blocked  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists profiles_email_idx on public.profiles (lower(email));
create index if not exists profiles_role_idx on public.profiles (role);

create table if not exists public.user_roles (
  id       uuid primary key default gen_random_uuid(),
  user_id  uuid not null references auth.users(id) on delete cascade,
  role     public.app_role not null,
  unique (user_id, role)
);

-- Role checks. SECURITY DEFINER so they can read user_roles without
-- triggering RLS recursion. Blocked accounts lose staff powers.
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

create or replace function public.is_staff(_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select _user_id is not null
     and exists (select 1 from public.user_roles
                 where user_id = _user_id and role in ('manager', 'admin', 'developer'))
     and not exists (select 1 from public.profiles where id = _user_id and is_blocked)
$$;

create or replace function public.is_admin(_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select _user_id is not null
     and exists (select 1 from public.user_roles
                 where user_id = _user_id and role in ('admin', 'developer'))
     and not exists (select 1 from public.profiles where id = _user_id and is_blocked)
$$;

-- New sign-up (email or Google) → profile row with role 'customer'.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, phone, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''),
             nullif(new.raw_user_meta_data ->> 'full_name', '')),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    'customer'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep profiles.email in step when a user changes their login email.
create or replace function public.handle_user_email_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = coalesce(new.email, '') where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- Guard profile edits made through the app (SECURITY INVOKER on purpose:
-- current_user tells us whether the change comes from the app or from
-- the Supabase dashboard / SQL editor, which is always allowed).
create or replace function public.guard_profile_update() returns trigger
language plpgsql set search_path = public as $$
declare
  uid uuid := auth.uid();
begin
  if current_user not in ('anon', 'authenticated') then
    new.updated_at := now();
    return new;
  end if;

  if new.id is distinct from old.id then
    raise exception 'PC: That change is not allowed.';
  end if;
  if new.email is distinct from old.email then
    raise exception 'PC: Email can only be changed from account settings.';
  end if;

  if new.role is distinct from old.role then
    if uid = old.id then
      raise exception 'PC: You can''t change your own role.';
    elsif public.is_admin(uid) and public.has_role(uid, 'developer') then
      null; -- developers can assign any role
    elsif public.is_admin(uid) then
      if old.role in ('admin', 'developer') or new.role = 'developer' then
        raise exception 'PC: Only a developer can change admin or developer accounts.';
      end if;
    else
      raise exception 'PC: You don''t have permission to change roles.';
    end if;
  end if;

  if new.is_blocked is distinct from old.is_blocked then
    if uid = old.id then
      raise exception 'PC: You can''t block your own account.';
    elsif not public.is_admin(uid) then
      raise exception 'PC: Only an admin can block or unblock customers.';
    elsif old.role in ('admin', 'developer') and not public.has_role(uid, 'developer') then
      raise exception 'PC: Only a developer can block an admin.';
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists guard_profile_update on public.profiles;
create trigger guard_profile_update
  before update on public.profiles
  for each row execute function public.guard_profile_update();

-- profiles.role → user_roles (the table the permission checks read).
create or replace function public.sync_user_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.role is distinct from old.role then
    delete from public.user_roles where user_id = new.id;
    insert into public.user_roles (user_id, role) values (new.id, new.role::public.app_role);
  end if;
  return new;
end $$;

drop trigger if exists sync_user_role on public.profiles;
create trigger sync_user_role
  after insert or update of role on public.profiles
  for each row execute function public.sync_user_role();

-- =====================================================================
-- 2. MENU & STOREFRONT CONTENT
-- =====================================================================
create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  icon        text not null default 'Pizza',
  image_url   text,
  is_visible  boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.products (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique,
  name               text not null,
  category_id        uuid references public.categories(id),
  price              numeric(10,2) not null check (price >= 0),
  old_price          numeric(10,2) check (old_price is null or old_price >= 0),
  image_url          text,
  gallery            text[] not null default '{}',
  short_description  text not null default '',
  description        text not null default '',
  ingredients        text[] not null default '{}',
  nutrition          jsonb not null default '[]'::jsonb,
  badges             text[] not null default '{}',
  popular            boolean not null default false,
  recommended        boolean not null default false,
  rating             numeric(2,1) not null default 0,
  review_count       integer not null default 0,
  is_available       boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists products_category_idx on public.products (category_id);

create table if not exists public.add_ons (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  price       numeric(10,2) not null check (price >= 0),
  group_name  text not null default 'General',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.offers (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  subtitle     text not null default '',
  tag          text not null default '',
  cta          text not null default '',
  image_url    text,
  is_active    boolean not null default true,
  link_type    text not null default 'product' check (link_type in ('product', 'external')),
  link_target  text not null default '',
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint offers_external_https check (link_type <> 'external' or link_target ~* '^https://')
);

create table if not exists public.branches (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  address     text not null default '',
  phone       text not null default '',
  hours       text not null default '',
  is_active   boolean not null default true,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.reviews (
  id            uuid primary key default gen_random_uuid(),
  author        text not null check (length(trim(author)) between 1 and 80),
  rating        integer not null check (rating between 1 and 5),
  body          text not null check (length(trim(body)) between 1 and 2000),
  product_name  text not null default 'General',
  status        text not null default 'pending' check (status in ('approved', 'pending', 'hidden')),
  featured      boolean not null default false,
  created_at    timestamptz not null default now()
);
create index if not exists reviews_status_idx on public.reviews (status, product_name);

-- Keep products.rating / review_count in step with approved reviews.
create or replace function public.refresh_product_rating() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  names text[] := array[]::text[];
begin
  if tg_op <> 'INSERT' then names := names || old.product_name; end if;
  if tg_op <> 'DELETE' then names := names || new.product_name; end if;
  update public.products p
     set rating = coalesce((select round(avg(r.rating)::numeric, 1) from public.reviews r
                             where r.status = 'approved' and r.product_name = p.name), 0),
         review_count = (select count(*) from public.reviews r
                          where r.status = 'approved' and r.product_name = p.name)
   where p.name = any (names);
  return null;
end $$;

drop trigger if exists refresh_product_rating on public.reviews;
create trigger refresh_product_rating
  after insert or update or delete on public.reviews
  for each row execute function public.refresh_product_rating();

-- =====================================================================
-- 3. STORE SETTINGS (single row each, id = 1)
-- =====================================================================
create table if not exists public.store_settings (
  id                  integer primary key default 1 check (id = 1),
  "storeName"         text not null default '',
  phone               text not null default '',
  whatsapp            text not null default '',
  email               text not null default '',
  address             text not null default '',
  hours               text not null default '',
  "deliveryFee"       numeric(10,2) check ("deliveryFee" is null or "deliveryFee" >= 0),
  "taxRate"           numeric(6,4) check ("taxRate" is null or ("taxRate" >= 0 and "taxRate" < 1)),
  "minOrder"          numeric(10,2) check ("minOrder" is null or "minOrder" >= 0),
  "deliveryRadiusKm"  numeric(6,2),
  "acceptingOrders"   boolean not null default true,
  updated_at          timestamptz not null default now()
);
comment on column public.store_settings."taxRate" is 'Fraction, e.g. 0.05 = 5%';

create table if not exists public.payment_settings (
  id                  integer primary key default 1 check (id = 1),
  "codEnabled"        boolean not null default true,
  "easypaisaEnabled"  boolean not null default false,
  "easypaisaNumber"   text not null default '',
  "jazzcashEnabled"   boolean not null default false,
  "jazzcashNumber"    text not null default '',
  "cardEnabled"       boolean not null default false,
  updated_at          timestamptz not null default now()
);

create table if not exists public.maintenance_settings (
  id          integer primary key default 1 check (id = 1),
  enabled     boolean not null default false,
  message     text not null default '',
  eta         text not null default '',
  updated_at  timestamptz not null default now()
);

create table if not exists public.brand_settings (
  id          integer primary key default 1 check (id = 1),
  settings    jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- =====================================================================
-- 4. PROMO CODES
-- =====================================================================
create table if not exists public.promo_codes (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  discount_type   text not null check (discount_type in ('percent', 'flat')),
  discount_value  numeric(10,2) not null check (discount_value > 0),
  active          boolean not null default true,
  usage_count     integer not null default 0,
  usage_limit     integer check (usage_limit is null or usage_limit > 0),
  expires_at      timestamptz,
  created_at      timestamptz not null default now(),
  constraint promo_percent_max check (discount_type <> 'percent' or discount_value <= 100)
);
create unique index if not exists promo_codes_code_key on public.promo_codes (upper(code));

-- =====================================================================
-- 5. ORDERS
-- =====================================================================
create sequence if not exists public.order_number_seq start 10001;

create table if not exists public.orders (
  id                     uuid primary key default gen_random_uuid(),
  order_number           text not null unique
                         default ('PC-' || nextval('public.order_number_seq')::text),
  customer_id            uuid references auth.users(id) on delete set null,
  customer_name          text not null,
  phone                  text,
  address                text,
  notes                  text,
  payment                text not null default 'cod' check (payment in ('cod', 'easypaisa', 'jazzcash')),
  payment_status         text not null default 'unpaid',
  transaction_id         text,
  payment_account_name   text,
  payment_verified_at    timestamptz,
  payment_verified_by    uuid,
  source                 text not null default 'online' check (source in ('online', 'pos')),
  status                 text not null default 'pending'
                         check (status in ('pending', 'preparing', 'baking', 'out_for_delivery', 'delivered', 'cancelled')),
  promo_code             text,
  idempotency_key        text,
  subtotal               numeric(10,2) not null default 0,
  discount               numeric(10,2) not null default 0,
  delivery_fee           numeric(10,2) not null default 0,
  tax                    numeric(10,2) not null default 0,
  total                  numeric(10,2) not null default 0,
  alarm_acknowledged_at  timestamptz,
  alarm_acknowledged_by  uuid,
  placed_at              timestamptz not null default now(),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check
  check (payment_status in ('unpaid', 'paid', 'refunded', 'pending_verification', 'verified'));
create unique index if not exists orders_idempotency_key on public.orders (idempotency_key) where idempotency_key is not null;
create index if not exists orders_customer_idx on public.orders (customer_id, placed_at desc);
create index if not exists orders_placed_idx on public.orders (placed_at desc);

create table if not exists public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  product_id  uuid,
  name        text not null,
  qty         integer not null check (qty > 0),
  price       numeric(10,2) not null,
  addons      jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists order_items_order_idx on public.order_items (order_id);

-- =====================================================================
-- 6. CUSTOMER DATA
-- =====================================================================
create table if not exists public.saved_addresses (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references auth.users(id) on delete cascade,
  label        text not null check (length(label) <= 60),
  line         text not null check (length(line) <= 300),
  is_default   boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists saved_addresses_customer_idx on public.saved_addresses (customer_id);

create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references auth.users(id) on delete cascade,
  title        text not null,
  body         text not null default '',
  type         text not null default 'order' check (type in ('order', 'promo', 'review', 'news')),
  unread       boolean not null default true,
  created_at   timestamptz not null default now()
);
create index if not exists notifications_customer_idx on public.notifications (customer_id, created_at desc);

create table if not exists public.customer_notes (
  customer_id  uuid primary key references public.profiles(id) on delete cascade,
  note         text not null default '',
  updated_at   timestamptz not null default now()
);

create table if not exists public.contact_messages (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 100),
  email       text not null check (length(email) <= 254),
  subject     text not null check (length(subject) <= 200),
  message     text not null check (length(trim(message)) between 1 and 5000),
  created_at  timestamptz not null default now()
);

create table if not exists public.newsletter_subscribers (
  id          uuid primary key default gen_random_uuid(),
  email       text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  created_at  timestamptz not null default now()
);
create unique index if not exists newsletter_email_key on public.newsletter_subscribers (lower(email));

-- =====================================================================
-- 7. STAFF TOOLS
-- =====================================================================
create table if not exists public.inventory_items (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  "group"              text not null default 'General',
  unit                 text not null default 'pcs' check (unit in ('kg', 'g', 'l', 'ml', 'pcs', 'pack')),
  quantity             numeric(12,3) not null default 0,
  "lowStockThreshold"  numeric(12,3) not null default 0,
  "updatedAt"          timestamptz not null default now(),
  created_at           timestamptz not null default now()
);

create or replace function public.touch_inventory_updated() returns trigger
language plpgsql set search_path = public as $$
begin new."updatedAt" := now(); return new; end $$;
drop trigger if exists touch_inventory_updated on public.inventory_items;
create trigger touch_inventory_updated before insert or update on public.inventory_items
  for each row execute function public.touch_inventory_updated();

create table if not exists public.reports (
  id               text primary key,
  type             text not null,
  format           text not null,
  range            text not null,
  status           text not null default 'processing' check (status in ('processing', 'ready', 'failed')),
  created_by_name  text not null default '',
  created_at       timestamptz not null default now()
);

create table if not exists public.activity_logs (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid,
  actor_name  text not null default 'System',
  action      text not null,
  target      text not null default '',
  module      text not null default 'general',
  level       text not null default 'info' check (level in ('info', 'warning', 'critical')),
  created_at  timestamptz not null default now()
);
create index if not exists activity_logs_created_idx on public.activity_logs (created_at desc);

-- updated_at triggers
do $$
declare t text;
begin
  foreach t in array array['categories', 'products', 'add_ons', 'offers', 'orders',
                           'store_settings', 'payment_settings', 'maintenance_settings',
                           'brand_settings', 'customer_notes']
  loop
    execute format('drop trigger if exists touch_updated_at on public.%I', t);
    execute format('create trigger touch_updated_at before update on public.%I
                    for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- =====================================================================
-- 8. ACTIVITY LOG (manual + automatic)
-- =====================================================================
create or replace function public.actor_display_name(_uid uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(name, ''), email) from public.profiles where id = _uid), 'System')
$$;

create or replace function public.log_activity(
  p_action text, p_target text default '', p_module text default 'general', p_level text default 'info'
) returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if not public.is_staff(uid) then return; end if;   -- only staff actions are logged
  insert into public.activity_logs (actor_id, actor_name, action, target, module, level)
  values (uid, public.actor_display_name(uid), left(p_action, 300), left(coalesce(p_target, ''), 300),
          left(coalesce(p_module, 'general'), 50),
          case when p_level in ('info', 'warning', 'critical') then p_level else 'info' end);
end $$;

-- Automatic log of staff changes. TG_ARGV[0] = module name.
create or replace function public.audit_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  rec jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end);
  label text;
  verb text := case tg_op when 'INSERT' then 'Created' when 'UPDATE' then 'Updated' else 'Deleted' end;
  action_text text;
begin
  if uid is null then return null; end if;      -- dashboard / system changes aren't logged
  if pg_trigger_depth() > 1 then return null; end if;  -- side effects of another change
  if not public.is_staff(uid) then return null; end if; -- only staff actions are logged
  action_text := verb || ' ' || replace(tg_table_name, '_', ' ');
  if tg_table_name = 'orders' then
    if tg_op <> 'UPDATE' then return null; end if;
    if new.payment_status is distinct from old.payment_status then
      action_text := 'Payment marked ' || new.payment_status;
    elsif new.status is distinct from old.status then
      action_text := 'Order status → ' || new.status;
    else
      return null;
    end if;
  elsif tg_table_name = 'profiles' then
    if tg_op <> 'UPDATE' then return null; end if;
    if new.role is distinct from old.role then
      action_text := 'Role changed ' || old.role || ' → ' || new.role;
    elsif new.is_blocked is distinct from old.is_blocked then
      action_text := case when new.is_blocked then 'Blocked account' else 'Unblocked account' end;
    else
      return null;
    end if;
  end if;
  label := coalesce(nullif(rec ->> 'order_number', ''), nullif(rec ->> 'name', ''),
                    nullif(rec ->> 'title', ''), nullif(rec ->> 'code', ''), nullif(rec ->> 'email', ''),
                    nullif(rec ->> 'storeName', ''), replace(tg_table_name, '_', ' '));
  insert into public.activity_logs (actor_id, actor_name, action, target, module, level)
  values (uid, public.actor_display_name(uid), action_text,
          left(label, 300), tg_argv[0],
          case when tg_op = 'DELETE' or tg_table_name in ('profiles', 'payment_settings') then 'warning' else 'info' end);
  return null;
end $$;

do $$
declare
  pair text[];
begin
  foreach pair slice 1 in array array[
    array['categories', 'menu'], array['products', 'menu'], array['add_ons', 'menu'],
    array['offers', 'promotions'], array['promo_codes', 'promotions'], array['branches', 'store'],
    array['store_settings', 'settings'], array['payment_settings', 'payments'],
    array['maintenance_settings', 'maintenance'], array['brand_settings', 'brand'],
    array['inventory_items', 'inventory'], array['orders', 'orders'], array['profiles', 'users'],
    array['reviews', 'reviews']]
  loop
    execute format('drop trigger if exists audit_change on public.%I', pair[1]);
    execute format('create trigger audit_change after insert or update or delete on public.%I
                    for each row execute function public.audit_change(%L)', pair[1], pair[2]);
  end loop;
end $$;

-- =====================================================================
-- 9. ORDER LOGIC
-- =====================================================================

-- Online wallet payments need a transaction id + account name and start
-- as "pending_verification" until an admin verifies them.
create or replace function public.validate_manual_payment_details() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.payment <> 'cod' then
    new.payment_account_name := coalesce(nullif(trim(new.payment_account_name), ''),
                                         nullif(trim(current_setting('pindi.payment_account_name', true)), ''));
    if nullif(trim(new.transaction_id), '') is null then
      raise exception 'PC: Transaction ID is required.';
    end if;
    if new.payment_account_name is null then
      raise exception 'PC: Online account name or username is required.';
    end if;
    if length(new.transaction_id) > 40 or length(new.payment_account_name) > 100 then
      raise exception 'PC: Payment details are too long.';
    end if;
    new.payment_status := 'pending_verification';
  end if;
  return new;
end $$;

drop trigger if exists validate_manual_payment_before_insert on public.orders;
create trigger validate_manual_payment_before_insert
  before insert on public.orders
  for each row execute function public.validate_manual_payment_details();

-- Only admins may change payment_status; verifying stamps who/when.
-- SECURITY INVOKER so dashboard edits (not anon/authenticated) are allowed.
create or replace function public.guard_payment_verification() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.payment_status is distinct from old.payment_status then
    if current_user in ('anon', 'authenticated') and not public.is_admin(auth.uid()) then
      raise exception 'PC: Only an admin can verify payment.';
    end if;
    if new.payment_status = 'verified' then
      if new.payment = 'cod' or nullif(trim(new.transaction_id), '') is null
         or nullif(trim(new.payment_account_name), '') is null then
        raise exception 'PC: Payment details are incomplete.';
      end if;
      new.payment_verified_at := now();
      new.payment_verified_by := auth.uid();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists guard_payment_status on public.orders;
create trigger guard_payment_status
  before update on public.orders
  for each row execute function public.guard_payment_verification();

-- Core order placement. Prices, promo, tax and delivery are calculated
-- here from live data — nothing price-related from the browser is trusted.
create or replace function public.place_order(
  p_customer_name text, p_phone text, p_address text, p_payment text, p_source text,
  p_notes text default null, p_transaction_id text default null, p_promo_code text default null,
  p_manual_discount_percent numeric default 0, p_items jsonb default '[]'::jsonb,
  p_idempotency_key text default null
) returns table (order_number text, subtotal numeric, discount numeric, delivery_fee numeric, tax numeric, total numeric)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  uid        uuid := auth.uid();
  staff      boolean := public.is_staff(auth.uid());
  st         public.store_settings%rowtype;
  ps         public.payment_settings%rowtype;
  line       jsonb;
  prod       public.products%rowtype;
  addon      public.add_ons%rowtype;
  addon_id   text;
  qty        integer;
  unit_price numeric;
  addon_json jsonb;
  lines      jsonb := '[]'::jsonb;
  v_sub      numeric := 0;
  v_disc     numeric := 0;
  v_fee      numeric := 0;
  v_tax      numeric := 0;
  promo      public.promo_codes%rowtype;
  v_promo    text := nullif(upper(trim(coalesce(p_promo_code, ''))), '');
  v_manual   numeric := coalesce(p_manual_discount_percent, 0);
  v_order    public.orders%rowtype;
  existing   public.orders%rowtype;
begin
  -- Same checkout submitted twice → return the first order.
  if nullif(trim(coalesce(p_idempotency_key, '')), '') is not null then
    select * into existing from public.orders o where o.idempotency_key = trim(p_idempotency_key);
    if found then
      if existing.customer_id is distinct from uid and not staff then
        raise exception 'PC: Your order couldn''t be created. Please try again.';
      end if;
      return query select existing.order_number, existing.subtotal, existing.discount,
                          existing.delivery_fee, existing.tax, existing.total;
      return;
    end if;
  end if;

  if p_source not in ('online', 'pos') then raise exception 'PC: Unknown order source.'; end if;
  if p_source = 'pos' and not staff then raise exception 'PC: Only staff can place in-store orders.'; end if;
  if p_payment not in ('cod', 'easypaisa', 'jazzcash') then raise exception 'PC: Choose a payment method.'; end if;

  if uid is not null and exists (select 1 from public.profiles where id = uid and is_blocked) then
    raise exception 'PC: Your account is blocked. Please contact the store.';
  end if;
  if not staff and exists (select 1 from public.maintenance_settings where enabled) then
    raise exception 'PC: We''re closed for maintenance right now. Please try again later.';
  end if;

  select * into st from public.store_settings where id = 1;
  select * into ps from public.payment_settings where id = 1;

  if p_source = 'online' then
    if st.id is not null and not st."acceptingOrders" then
      raise exception 'PC: We''re not accepting online orders right now.';
    end if;
    if ps.id is not null and (
         (p_payment = 'cod' and not ps."codEnabled") or
         (p_payment = 'easypaisa' and not ps."easypaisaEnabled") or
         (p_payment = 'jazzcash' and not ps."jazzcashEnabled")) then
      raise exception 'PC: That payment method isn''t available right now.';
    end if;
    if nullif(trim(coalesce(p_phone, '')), '') is null then raise exception 'PC: Please enter your phone number.'; end if;
    if nullif(trim(coalesce(p_address, '')), '') is null then raise exception 'PC: Please enter your delivery address.'; end if;
  end if;
  if nullif(trim(coalesce(p_customer_name, '')), '') is null then raise exception 'PC: Please enter your name.'; end if;
  if length(p_customer_name) > 100 or length(coalesce(p_phone, '')) > 30
     or length(coalesce(p_address, '')) > 500 or length(coalesce(p_notes, '')) > 1000 then
    raise exception 'PC: Some details are too long.';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'PC: Your cart is empty.';
  end if;
  if jsonb_array_length(p_items) > 100 then raise exception 'PC: Too many items in one order.'; end if;

  for line in select * from jsonb_array_elements(p_items) loop
    qty := coalesce((line ->> 'qty')::integer, 0);
    if qty < 1 or qty > 50 then raise exception 'PC: Item quantity must be between 1 and 50.'; end if;

    select * into prod from public.products where id = (line ->> 'product_id')::uuid;
    if not found or not prod.is_available then
      raise exception 'PC: % is no longer available. Please remove it from your cart.',
        coalesce(prod.name, 'An item');
    end if;

    unit_price := prod.price;
    addon_json := '[]'::jsonb;
    for addon_id in select * from jsonb_array_elements_text(coalesce(line -> 'addon_ids', '[]'::jsonb)) loop
      select * into addon from public.add_ons where id = addon_id::uuid;
      if not found or not addon.is_active then
        raise exception 'PC: An extra you picked for % is no longer available.', prod.name;
      end if;
      unit_price := unit_price + addon.price;
      addon_json := addon_json || jsonb_build_object('id', addon.id, 'name', addon.name, 'price', addon.price);
    end loop;

    v_sub := v_sub + unit_price * qty;
    lines := lines || jsonb_build_object('product_id', prod.id, 'name', prod.name, 'qty', qty,
                                         'price', unit_price, 'addons', addon_json);
  end loop;

  if p_source = 'online' and st.id is not null and st."minOrder" is not null and v_sub < st."minOrder" then
    raise exception 'PC: The minimum order is Rs %.', to_char(st."minOrder", 'FM999,999,990');
  end if;

  -- Promo code (locked so usage limits can't be exceeded by parallel orders).
  if v_promo is not null then
    select * into promo from public.promo_codes pc
     where upper(pc.code) = v_promo and pc.active
       and (pc.expires_at is null or pc.expires_at > now())
       and (pc.usage_limit is null or pc.usage_count < pc.usage_limit)
     for update;
    if not found then raise exception 'PC: That promo code is invalid or has expired.'; end if;
    v_disc := round(case when promo.discount_type = 'percent'
                         then v_sub * promo.discount_value / 100 else promo.discount_value end);
    update public.promo_codes set usage_count = usage_count + 1 where id = promo.id;
  end if;

  -- POS manual discount (staff only).
  if v_manual <> 0 then
    if not staff or p_source <> 'pos' then raise exception 'PC: Manual discounts are for in-store orders only.'; end if;
    if v_manual < 0 or v_manual > 50 then raise exception 'PC: Manual discount must be between 0 and 50%%.'; end if;
    v_disc := v_disc + round(v_sub * v_manual / 100);
  end if;
  v_disc := least(v_disc, v_sub);

  -- Online orders pay delivery + tax; in-store (POS) orders don't.
  if p_source = 'online' and st.id is not null then
    v_fee := coalesce(st."deliveryFee", 0);
    v_tax := round((v_sub - v_disc) * coalesce(st."taxRate", 0));
  end if;

  insert into public.orders (customer_id, customer_name, phone, address, notes, payment,
                             transaction_id, payment_account_name, source, promo_code,
                             idempotency_key, subtotal, discount, delivery_fee, tax, total)
  values (case when p_source = 'online' then uid end, trim(p_customer_name), nullif(trim(p_phone), ''),
          nullif(trim(p_address), ''), nullif(trim(p_notes), ''), p_payment,
          nullif(trim(p_transaction_id), ''), null, p_source, v_promo,
          nullif(trim(coalesce(p_idempotency_key, '')), ''),
          v_sub, v_disc, v_fee, v_tax, v_sub - v_disc + v_fee + v_tax)
  returning * into v_order;

  insert into public.order_items (order_id, product_id, name, qty, price, addons)
  select v_order.id, (l ->> 'product_id')::uuid, l ->> 'name', (l ->> 'qty')::integer,
         (l ->> 'price')::numeric, l -> 'addons'
    from jsonb_array_elements(lines) l;

  return query select v_order.order_number, v_order.subtotal, v_order.discount,
                      v_order.delivery_fee, v_order.tax, v_order.total;
end $$;

-- What the app calls at checkout / POS.
create or replace function public.place_order_with_payment_details(
  p_customer_name text, p_phone text, p_address text, p_payment text, p_source text,
  p_notes text default null, p_transaction_id text default null, p_promo_code text default null,
  p_manual_discount_percent numeric default 0, p_items jsonb default '[]'::jsonb,
  p_idempotency_key text default null, p_payment_account_name text default null
) returns table (order_number text, subtotal numeric, discount numeric, delivery_fee numeric, tax numeric, total numeric)
language plpgsql security definer set search_path = public as $$
begin
  if p_payment in ('easypaisa', 'jazzcash') then
    if nullif(trim(p_transaction_id), '') is null then raise exception 'PC: Transaction ID is required.'; end if;
    if nullif(trim(p_payment_account_name), '') is null then raise exception 'PC: Online account name or username is required.'; end if;
    if length(p_transaction_id) > 40 or length(p_payment_account_name) > 100 then raise exception 'PC: Payment details are too long.'; end if;
  end if;
  perform set_config('pindi.payment_account_name', coalesce(trim(p_payment_account_name), ''), true);
  return query select * from public.place_order(p_customer_name, p_phone, p_address, p_payment, p_source,
    p_notes, p_transaction_id, p_promo_code, p_manual_discount_percent, p_items, p_idempotency_key);
end $$;

-- Promo preview at checkout (place_order re-checks it).
create or replace function public.validate_promo(p_code text)
returns table (code text, discount_type text, discount_value numeric)
language sql stable security definer set search_path = public as $$
  select pc.code, pc.discount_type, pc.discount_value
    from public.promo_codes pc
   where upper(pc.code) = upper(trim(p_code)) and pc.active
     and (pc.expires_at is null or pc.expires_at > now())
     and (pc.usage_limit is null or pc.usage_count < pc.usage_limit)
   limit 1
$$;

-- Order tracking / receipt. Returns the order only to its owner, staff,
-- or someone who knows the phone number it was placed with.
create or replace function public.track_order(p_order_number text, p_phone text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  o public.orders%rowtype;
  uid uuid := auth.uid();
  digits_given text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  digits_order text;
begin
  select * into o from public.orders where upper(order_number) = upper(trim(p_order_number));
  if not found then return null; end if;
  digits_order := regexp_replace(coalesce(o.phone, ''), '\D', '', 'g');
  if not (
       (uid is not null and o.customer_id = uid)
    or public.is_staff(uid)
    or (length(digits_given) >= 7 and length(digits_order) >= 7
        and right(digits_given, 10) = right(digits_order, 10))
  ) then
    return null;
  end if;
  return jsonb_build_object(
    'order_number', o.order_number, 'customer_name', o.customer_name, 'phone', o.phone,
    'address', o.address, 'notes', o.notes, 'payment', o.payment, 'payment_status', o.payment_status,
    'transaction_id', o.transaction_id, 'payment_account_name', o.payment_account_name,
    'source', o.source, 'status', o.status, 'promo_code', o.promo_code,
    'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee,
    'tax', o.tax, 'total', o.total, 'placed_at', o.placed_at,
    'alarm_acknowledged_at', o.alarm_acknowledged_at,
    'order_items', coalesce((select jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty,
                               'price', i.price, 'product_id', i.product_id, 'addons', i.addons)
                               order by i.created_at)
                             from public.order_items i where i.order_id = o.id), '[]'::jsonb));
end $$;

create or replace function public.acknowledge_order_alarm(p_order_number text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(auth.uid()) then raise exception 'PC: Staff access is required.'; end if;
  update public.orders set alarm_acknowledged_at = now(), alarm_acknowledged_by = auth.uid()
   where order_number = p_order_number and alarm_acknowledged_at is null;
end $$;

create or replace function public.verify_order_payment(p_order_number text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'PC: Only an admin can verify payment.'; end if;
  update public.orders set payment_status = 'verified'
   where order_number = p_order_number and payment <> 'cod' and payment_status <> 'verified';
  if not found and not exists (select 1 from public.orders
                                where order_number = p_order_number and payment_status = 'verified') then
    raise exception 'PC: No online payment to verify.';
  end if;
end $$;

-- Customer notifications on status / payment changes.
create or replace function public.notify_order_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  label text;
begin
  if new.customer_id is null then return null; end if;
  if new.status is distinct from old.status then
    label := case new.status
      when 'pending' then 'received' when 'preparing' then 'being prepared'
      when 'baking' then 'in the oven' when 'out_for_delivery' then 'out for delivery'
      when 'delivered' then 'delivered' when 'cancelled' then 'cancelled' else new.status end;
    insert into public.notifications (customer_id, title, body, type)
    values (new.customer_id, 'Order ' || new.order_number || ' is ' || label,
            'Your order ' || new.order_number || ' is now ' || label || '.', 'order');
  end if;
  if new.payment_status = 'verified' and old.payment_status is distinct from new.payment_status then
    insert into public.notifications (customer_id, title, body, type)
    values (new.customer_id, 'Payment verified — ' || new.order_number,
            'The admin has verified your online payment for order ' || new.order_number || '.', 'order');
  end if;
  return null;
end $$;

drop trigger if exists payment_verification_notification on public.orders;
drop trigger if exists on_order_status_change on public.orders;
create trigger on_order_status_change
  after update on public.orders
  for each row execute function public.notify_order_change();

create or replace function public.send_customer_message(p_customer_id uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(auth.uid()) then raise exception 'PC: Staff access is required.'; end if;
  if nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'PC: Message can''t be empty.'; end if;
  if length(p_body) > 1000 then raise exception 'PC: Message is too long (max 1000 characters).'; end if;
  if not exists (select 1 from public.profiles where id = p_customer_id) then
    raise exception 'PC: Customer not found.';
  end if;
  insert into public.notifications (customer_id, title, body, type)
  values (p_customer_id, 'Message from PINDI CRUST', trim(p_body), 'news');
end $$;

-- =====================================================================
-- 10. ANALYTICS & REPORTS (staff only)
-- =====================================================================
create or replace function public.require_staff() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff(auth.uid()) then raise exception 'PC: Staff access is required.'; end if;
end $$;

create or replace function public.analytics_revenue_trend(p_days integer)
returns table (day text, revenue numeric, orders bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return query
  with days as (
    select generate_series((now() at time zone public.store_tz())::date - (greatest(p_days, 1) - 1),
                           (now() at time zone public.store_tz())::date, interval '1 day')::date as d
  )
  select to_char(days.d, 'YYYY-MM-DD'), coalesce(sum(o.total), 0)::numeric, count(o.id)
    from days
    left join public.orders o
      on (o.placed_at at time zone public.store_tz())::date = days.d and o.status <> 'cancelled'
   group by days.d order by days.d;
end $$;

create or replace function public.analytics_category_sales(p_days integer)
returns table (name text, value numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return query
  select coalesce(c.name, 'Other'), sum(i.price * i.qty)::numeric
    from public.order_items i
    join public.orders o on o.id = i.order_id
    left join public.products p on p.id = i.product_id
    left join public.categories c on c.id = p.category_id
   where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
   group by 1 order by 2 desc;
end $$;

create or replace function public.analytics_peak_hours(p_days integer)
returns table (hour text, orders bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return query
  select to_char(make_time(h, 0, 0), 'FMHH12 AM'), count(o.id)
    from generate_series(0, 23) h
    left join public.orders o
      on extract(hour from o.placed_at at time zone public.store_tz())::int = h
     and o.status <> 'cancelled'
     and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
   group by h order by h;
end $$;

create or replace function public.analytics_customer_growth()
returns table (month text, "newCustomers" bigint, "returning" bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return query
  with months as (
    select generate_series(date_trunc('month', now() at time zone public.store_tz()) - interval '5 months',
                           date_trunc('month', now() at time zone public.store_tz()), interval '1 month') as m
  )
  select to_char(months.m, 'Mon'),
         (select count(*) from public.profiles p
           where p.role = 'customer'
             and date_trunc('month', p.created_at at time zone public.store_tz()) = months.m),
         (select count(distinct o.customer_id) from public.orders o
            join public.profiles p on p.id = o.customer_id
           where o.status <> 'cancelled'
             and date_trunc('month', o.placed_at at time zone public.store_tz()) = months.m
             and (p.created_at at time zone public.store_tz()) < months.m)
    from months order by months.m;
end $$;

create or replace function public.analytics_payment_split(p_days integer)
returns table (name text, value bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return query
  select case o.payment when 'cod' then 'Cash on Delivery' when 'easypaisa' then 'EasyPaisa'
                        when 'jazzcash' then 'JazzCash' else o.payment end,
         count(*)
    from public.orders o
   where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
   group by o.payment order by 2 desc;
end $$;

create or replace function public.analytics_top_products(p_days integer, p_direction text, p_limit integer)
returns table (name text, sold bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  if p_direction = 'slow' then
    return query
    select p.name, coalesce(sum(i.qty) filter (where o.id is not null), 0)::bigint
      from public.products p
      left join public.order_items i on i.product_id = p.id
      left join public.orders o on o.id = i.order_id and o.status <> 'cancelled'
                                and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
     where p.is_available
     group by p.id, p.name order by 2 asc, p.name limit greatest(p_limit, 1);
  else
    return query
    select i.name, sum(i.qty)::bigint
      from public.order_items i
      join public.orders o on o.id = i.order_id
     where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
     group by i.name order by 2 desc, i.name limit greatest(p_limit, 1);
  end if;
end $$;

create or replace function public.report_orders(p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'order_id', o.order_number, 'created_at', o.placed_at, 'status', o.status,
      'total', o.total, 'payment_method', o.payment) order by o.placed_at desc)
    from public.orders o where o.placed_at >= now() - make_interval(days => greatest(p_days, 1))), '[]'::jsonb);
end $$;

create or replace function public.report_items(p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('product_name', t.name, 'quantity_sold', t.qty,
                                                       'revenue', t.revenue) order by t.qty desc)
    from (select i.name, sum(i.qty) as qty, sum(i.qty * i.price) as revenue
            from public.order_items i join public.orders o on o.id = i.order_id
           where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
           group by i.name) t), '[]'::jsonb);
end $$;

create or replace function public.report_payments(p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('payment_method', t.payment, 'orders', t.n,
                                                       'total', t.total) order by t.total desc)
    from (select o.payment, count(*) as n, sum(o.total) as total from public.orders o
           where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
           group by o.payment) t), '[]'::jsonb);
end $$;

create or replace function public.report_taxes(p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('day', t.d, 'tax_collected', t.tax,
                                                       'taxable_revenue', t.taxable) order by t.d)
    from (select to_char((o.placed_at at time zone public.store_tz())::date, 'YYYY-MM-DD') as d,
                 sum(o.tax) as tax, sum(o.subtotal - o.discount) as taxable
            from public.orders o
           where o.status <> 'cancelled' and o.placed_at >= now() - make_interval(days => greatest(p_days, 1))
           group by 1) t), '[]'::jsonb);
end $$;

-- =====================================================================
-- 11. ROW LEVEL SECURITY
-- =====================================================================
do $$
declare t text; pol text;
begin
  foreach t in array array['profiles', 'user_roles', 'categories', 'products', 'add_ons', 'offers',
    'branches', 'reviews', 'store_settings', 'payment_settings', 'maintenance_settings',
    'brand_settings', 'promo_codes', 'orders', 'order_items', 'saved_addresses', 'notifications',
    'customer_notes', 'contact_messages', 'newsletter_subscribers', 'inventory_items', 'reports',
    'activity_logs']
  loop
    execute format('alter table public.%I enable row level security', t);
    -- drop every existing policy so this file can be re-run cleanly
    for pol in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy if exists %I on public.%I', pol, t);
    end loop;
  end loop;
end $$;

-- profiles
create policy "profiles: read own or staff" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_staff((select auth.uid())));
create policy "profiles: update own or admin" on public.profiles for update to authenticated
  using (id = (select auth.uid()) or public.is_admin((select auth.uid())))
  with check (id = (select auth.uid()) or public.is_admin((select auth.uid())));

-- user_roles (read-only for the app; changed only through profiles.role)
create policy "user_roles: read own or staff" on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff((select auth.uid())));

-- Public catalogue: everyone reads visible items, staff read/edit all,
-- only admins delete.
create policy "categories: read" on public.categories for select to anon, authenticated
  using (is_visible or public.is_staff((select auth.uid())));
create policy "categories: staff insert" on public.categories for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "categories: staff update" on public.categories for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "categories: admin delete" on public.categories for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "products: read" on public.products for select to anon, authenticated
  using (is_available or public.is_staff((select auth.uid())));
create policy "products: staff insert" on public.products for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "products: staff update" on public.products for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "products: admin delete" on public.products for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "add_ons: read" on public.add_ons for select to anon, authenticated
  using (is_active or public.is_staff((select auth.uid())));
create policy "add_ons: staff insert" on public.add_ons for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "add_ons: staff update" on public.add_ons for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "add_ons: admin delete" on public.add_ons for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "offers: read" on public.offers for select to anon, authenticated
  using (is_active or public.is_staff((select auth.uid())));
create policy "offers: staff insert" on public.offers for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "offers: staff update" on public.offers for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "offers: admin delete" on public.offers for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "branches: read" on public.branches for select to anon, authenticated
  using (is_active or public.is_staff((select auth.uid())));
create policy "branches: admin write" on public.branches for all to authenticated
  using (public.is_admin((select auth.uid()))) with check (public.is_admin((select auth.uid())));

-- reviews: anyone may submit (always pending); public sees approved only.
create policy "reviews: read" on public.reviews for select to anon, authenticated
  using (status = 'approved' or public.is_staff((select auth.uid())));
create policy "reviews: submit pending" on public.reviews for insert to anon, authenticated
  with check (status = 'pending' and featured = false);
create policy "reviews: staff moderate" on public.reviews for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "reviews: admin delete" on public.reviews for delete to authenticated
  using (public.is_admin((select auth.uid())));

-- settings: public read (storefront needs them), admin write.
create policy "store_settings: read" on public.store_settings for select to anon, authenticated using (true);
create policy "store_settings: admin write" on public.store_settings for all to authenticated
  using (public.is_admin((select auth.uid()))) with check (public.is_admin((select auth.uid())));
create policy "payment_settings: read" on public.payment_settings for select to anon, authenticated using (true);
create policy "payment_settings: admin write" on public.payment_settings for all to authenticated
  using (public.is_admin((select auth.uid()))) with check (public.is_admin((select auth.uid())));
create policy "maintenance_settings: read" on public.maintenance_settings for select to anon, authenticated using (true);
create policy "maintenance_settings: admin write" on public.maintenance_settings for all to authenticated
  using (public.is_admin((select auth.uid()))) with check (public.is_admin((select auth.uid())));
create policy "brand_settings: read" on public.brand_settings for select to anon, authenticated using (true);
create policy "brand_settings: admin write" on public.brand_settings for all to authenticated
  using (public.is_admin((select auth.uid()))) with check (public.is_admin((select auth.uid())));

-- promo codes: staff manage, admin delete (customers use validate_promo()).
create policy "promo_codes: staff read" on public.promo_codes for select to authenticated
  using (public.is_staff((select auth.uid())));
create policy "promo_codes: staff insert" on public.promo_codes for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "promo_codes: staff update" on public.promo_codes for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "promo_codes: admin delete" on public.promo_codes for delete to authenticated
  using (public.is_admin((select auth.uid())));

-- orders: customers see their own; staff see all and change status.
-- New orders are created only through place_order_with_payment_details().
create policy "orders: read own or staff" on public.orders for select to authenticated
  using (customer_id = (select auth.uid()) or public.is_staff((select auth.uid())));
create policy "orders: staff update" on public.orders for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "orders: admin delete" on public.orders for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "order_items: read with order" on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                   and (o.customer_id = (select auth.uid()) or public.is_staff((select auth.uid())))));

-- saved addresses: owner only.
create policy "saved_addresses: owner" on public.saved_addresses for all to authenticated
  using (customer_id = (select auth.uid())) with check (customer_id = (select auth.uid()));

-- notifications: owner reads and marks read.
create policy "notifications: read own" on public.notifications for select to authenticated
  using (customer_id = (select auth.uid()));
create policy "notifications: mark own read" on public.notifications for update to authenticated
  using (customer_id = (select auth.uid())) with check (customer_id = (select auth.uid()));

-- staff-only tables
create policy "customer_notes: staff" on public.customer_notes for all to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));

create policy "inventory: staff read" on public.inventory_items for select to authenticated
  using (public.is_staff((select auth.uid())));
create policy "inventory: staff insert" on public.inventory_items for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "inventory: staff update" on public.inventory_items for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "inventory: admin delete" on public.inventory_items for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "reports: staff read" on public.reports for select to authenticated
  using (public.is_staff((select auth.uid())));
create policy "reports: staff insert" on public.reports for insert to authenticated
  with check (public.is_staff((select auth.uid())));
create policy "reports: staff update" on public.reports for update to authenticated
  using (public.is_staff((select auth.uid()))) with check (public.is_staff((select auth.uid())));
create policy "reports: admin delete" on public.reports for delete to authenticated
  using (public.is_admin((select auth.uid())));

create policy "activity_logs: staff read" on public.activity_logs for select to authenticated
  using (public.is_staff((select auth.uid())));

-- contact form & newsletter: anyone can submit, staff can read.
create policy "contact_messages: submit" on public.contact_messages for insert to anon, authenticated with check (true);
create policy "contact_messages: staff read" on public.contact_messages for select to authenticated
  using (public.is_staff((select auth.uid())));
create policy "contact_messages: admin delete" on public.contact_messages for delete to authenticated
  using (public.is_admin((select auth.uid())));
create policy "newsletter: subscribe" on public.newsletter_subscribers for insert to anon, authenticated with check (true);
create policy "newsletter: staff read" on public.newsletter_subscribers for select to authenticated
  using (public.is_staff((select auth.uid())));
create policy "newsletter: admin delete" on public.newsletter_subscribers for delete to authenticated
  using (public.is_admin((select auth.uid())));

-- =====================================================================
-- 12. TABLE PRIVILEGES (RLS above decides which rows)
-- =====================================================================
revoke all on all tables in schema public from anon, authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

grant select on public.categories, public.products, public.add_ons, public.offers, public.branches,
               public.reviews, public.store_settings, public.payment_settings,
               public.maintenance_settings, public.brand_settings to anon, authenticated;
grant insert on public.reviews, public.contact_messages, public.newsletter_subscribers to anon, authenticated;

grant select on public.profiles, public.user_roles, public.orders, public.order_items,
               public.saved_addresses, public.notifications, public.customer_notes,
               public.inventory_items, public.reports, public.activity_logs, public.promo_codes,
               public.contact_messages, public.newsletter_subscribers to authenticated;
grant insert, update, delete on public.categories, public.products, public.add_ons, public.offers,
               public.branches, public.store_settings, public.payment_settings,
               public.maintenance_settings, public.brand_settings, public.promo_codes,
               public.saved_addresses, public.customer_notes, public.inventory_items,
               public.reports to authenticated;
grant update, delete on public.reviews to authenticated;
grant delete on public.orders, public.contact_messages, public.newsletter_subscribers to authenticated;

-- Column-limited updates.
grant update (name, phone, role, is_blocked) on public.profiles to authenticated;
grant update (status) on public.orders to authenticated;
grant update (unread) on public.notifications to authenticated;

-- =====================================================================
-- 13. FUNCTION PRIVILEGES
-- =====================================================================
revoke execute on all functions in schema public from public, anon, authenticated;

-- used inside security rules → must be callable by everyone
grant execute on function public.has_role(uuid, public.app_role) to anon, authenticated;
grant execute on function public.is_staff(uuid) to anon, authenticated;
grant execute on function public.is_admin(uuid) to anon, authenticated;
grant execute on function public.store_tz() to anon, authenticated;

-- storefront
grant execute on function public.place_order_with_payment_details(text, text, text, text, text, text, text, text, numeric, jsonb, text, text) to anon, authenticated;
grant execute on function public.validate_promo(text) to anon, authenticated;
grant execute on function public.track_order(text, text) to anon, authenticated;

-- staff (each function checks the role itself)
grant execute on function public.acknowledge_order_alarm(text) to authenticated;
grant execute on function public.verify_order_payment(text) to authenticated;
grant execute on function public.send_customer_message(uuid, text) to authenticated;
grant execute on function public.log_activity(text, text, text, text) to authenticated;
grant execute on function public.analytics_revenue_trend(integer) to authenticated;
grant execute on function public.analytics_category_sales(integer) to authenticated;
grant execute on function public.analytics_peak_hours(integer) to authenticated;
grant execute on function public.analytics_customer_growth() to authenticated;
grant execute on function public.analytics_payment_split(integer) to authenticated;
grant execute on function public.analytics_top_products(integer, text, integer) to authenticated;
grant execute on function public.report_orders(integer) to authenticated;
grant execute on function public.report_items(integer) to authenticated;
grant execute on function public.report_payments(integer) to authenticated;
grant execute on function public.report_taxes(integer) to authenticated;

grant execute on all functions in schema public to service_role;

-- =====================================================================
-- 14. REALTIME (live orders in admin / kitchen, live notifications)
-- =====================================================================
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['orders', 'order_items', 'notifications'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- =====================================================================
-- 15. BACKFILL — anyone who signed up before this file was run
-- =====================================================================
insert into public.profiles (id, email, name, phone, role)
select u.id, coalesce(u.email, ''),
       coalesce(nullif(u.raw_user_meta_data ->> 'name', ''), nullif(u.raw_user_meta_data ->> 'full_name', '')),
       nullif(u.raw_user_meta_data ->> 'phone', ''), 'customer'
  from auth.users u
on conflict (id) do nothing;

insert into public.user_roles (user_id, role)
select p.id, p.role::public.app_role from public.profiles p
on conflict (user_id, role) do nothing;

-- Done. Next: run make-admin.sql with your email after you sign up once.
