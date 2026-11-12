-- =====================================================================
-- PINDI CRUST — update 001: menu sizes + working settings + image uploads
-- ---------------------------------------------------------------------
-- Run this ONCE in your own Supabase project if you installed
-- supabase/schema.sql before 12 Nov 2026:
--   Supabase → SQL Editor → New query → paste this whole file → Run.
-- It is safe to run again. (A fresh schema.sql already contains it.)
--
-- Adds:
--   • unlimited sizes per menu item (each size has its own price)
--   • the chosen size on every order line, priced by the database
--   • extra store / payment settings (free delivery above, account titles,
--     wallet QR images, checkout instructions)
--   • a public "brand-assets" storage bucket for logo, favicon, hero,
--     QR and menu photos (only staff can upload)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. MENU SIZES
-- ---------------------------------------------------------------------
alter table public.products add column if not exists sizes jsonb not null default '[]'::jsonb;
alter table public.order_items add column if not exists size text;

-- Cleans the size list an admin saves and keeps products.price equal to
-- the cheapest size, so menu cards can show "from Rs …".
create or replace function public.normalize_product_sizes() returns trigger
language plpgsql set search_path = public as $$
declare
  s          jsonb;
  cleaned    jsonb := '[]'::jsonb;
  v_name     text;
  v_price    numeric;
  v_id       text;
  seen_ids   text[] := '{}';
  seen_names text[] := '{}';
begin
  if new.sizes is null or jsonb_typeof(new.sizes) <> 'array' then
    new.sizes := '[]'::jsonb;
  end if;
  if jsonb_array_length(new.sizes) > 30 then
    raise exception 'PC: A menu item can have at most 30 sizes.';
  end if;
  for s in select * from jsonb_array_elements(new.sizes) loop
    if jsonb_typeof(s) <> 'object' then
      raise exception 'PC: Each size needs a name and a price.';
    end if;
    v_name := nullif(trim(coalesce(s ->> 'name', '')), '');
    if v_name is null then raise exception 'PC: Every size needs a name.'; end if;
    if length(v_name) > 40 then raise exception 'PC: Size names must be 40 characters or fewer.'; end if;
    if lower(v_name) = any (seen_names) then raise exception 'PC: The size "%" is listed twice.', v_name; end if;
    begin
      v_price := (s ->> 'price')::numeric;
    exception when others then
      raise exception 'PC: The size "%" needs a valid price.', v_name;
    end;
    if v_price is null or v_price <= 0 then
      raise exception 'PC: The size "%" needs a price greater than zero.', v_name;
    end if;
    v_id := nullif(trim(coalesce(s ->> 'id', '')), '');
    if v_id is null or v_id = any (seen_ids) then v_id := gen_random_uuid()::text; end if;
    seen_ids := seen_ids || v_id;
    seen_names := seen_names || lower(v_name);
    cleaned := cleaned || jsonb_build_object('id', v_id, 'name', v_name, 'price', round(v_price, 2));
  end loop;
  new.sizes := cleaned;
  if jsonb_array_length(cleaned) > 0 then
    new.price := (select min((x ->> 'price')::numeric) from jsonb_array_elements(cleaned) x);
  end if;
  return new;
end $$;

drop trigger if exists normalize_product_sizes on public.products;
create trigger normalize_product_sizes
  before insert or update on public.products
  for each row execute function public.normalize_product_sizes();

-- ---------------------------------------------------------------------
-- 2. EXTRA SETTINGS
-- ---------------------------------------------------------------------
alter table public.store_settings
  add column if not exists "freeDeliveryAbove" numeric(10,2),
  add column if not exists "prepTimeMinutes"   integer,
  add column if not exists "mapsUrl"           text not null default '';

alter table public.payment_settings
  add column if not exists "easypaisaAccountTitle" text not null default '',
  add column if not exists "jazzcashAccountTitle"  text not null default '',
  add column if not exists "easypaisaQrUrl"        text not null default '',
  add column if not exists "jazzcashQrUrl"         text not null default '',
  add column if not exists "instructions"          text not null default '';

-- ---------------------------------------------------------------------
-- 3. ORDER LOGIC — sizes + free delivery threshold
-- ---------------------------------------------------------------------
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

create or replace function public.place_order(
  p_customer_name text, p_phone text, p_address text, p_payment text, p_source text,
  p_notes text default null, p_transaction_id text default null, p_promo_code text default null,
  p_manual_discount_percent numeric default 0, p_items jsonb default '[]'::jsonb,
  p_idempotency_key text default null
) returns table (order_number text, subtotal numeric, discount numeric, delivery_fee numeric, tax numeric, total numeric)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  uid         uuid := auth.uid();
  staff       boolean := public.is_staff(auth.uid());
  st          public.store_settings%rowtype;
  ps          public.payment_settings%rowtype;
  line        jsonb;
  prod        public.products%rowtype;
  addon       public.add_ons%rowtype;
  addon_id    text;
  qty         integer;
  unit_price  numeric;
  addon_json  jsonb;
  v_size      jsonb;
  v_size_name text;
  lines       jsonb := '[]'::jsonb;
  v_sub       numeric := 0;
  v_disc      numeric := 0;
  v_fee       numeric := 0;
  v_tax       numeric := 0;
  promo       public.promo_codes%rowtype;
  v_promo     text := nullif(upper(trim(coalesce(p_promo_code, ''))), '');
  v_manual    numeric := coalesce(p_manual_discount_percent, 0);
  v_order     public.orders%rowtype;
  existing    public.orders%rowtype;
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

    -- Items with sizes are priced by the chosen size.
    unit_price := prod.price;
    v_size_name := null;
    if jsonb_array_length(coalesce(prod.sizes, '[]'::jsonb)) > 0 then
      select e.value into v_size
        from jsonb_array_elements(prod.sizes) e
       where e.value ->> 'id' = coalesce(line ->> 'size_id', '')
       limit 1;
      if v_size is null then
        raise exception 'PC: Please choose a size for %.', prod.name;
      end if;
      unit_price := (v_size ->> 'price')::numeric;
      v_size_name := v_size ->> 'name';
    end if;

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
    lines := lines || jsonb_build_object(
      'product_id', prod.id,
      'name', prod.name || coalesce(' (' || v_size_name || ')', ''),
      'size', v_size_name, 'qty', qty, 'price', unit_price, 'addons', addon_json);
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
  -- Delivery is free when the items total reaches "free delivery above".
  if p_source = 'online' and st.id is not null then
    v_fee := coalesce(st."deliveryFee", 0);
    if st."freeDeliveryAbove" is not null and v_sub >= st."freeDeliveryAbove" then
      v_fee := 0;
    end if;
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

  insert into public.order_items (order_id, product_id, name, size, qty, price, addons)
  select v_order.id, (l ->> 'product_id')::uuid, l ->> 'name', l ->> 'size', (l ->> 'qty')::integer,
         (l ->> 'price')::numeric, l -> 'addons'
    from jsonb_array_elements(lines) l;

  return query select v_order.order_number, v_order.subtotal, v_order.discount,
                      v_order.delivery_fee, v_order.tax, v_order.total;
end $$;

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

revoke execute on function public.place_order(text, text, text, text, text, text, text, text, numeric, jsonb, text) from public, anon, authenticated;
revoke execute on function public.normalize_product_sizes() from public, anon, authenticated;
grant execute on function public.place_order_with_payment_details(text, text, text, text, text, text, text, text, numeric, jsonb, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. IMAGE UPLOADS — public "brand-assets" bucket, staff-only uploads
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-assets', 'brand-assets', true, 5242880,
        array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/svg+xml',
              'image/x-icon', 'image/vnd.microsoft.icon'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "brand-assets: staff upload" on storage.objects;
create policy "brand-assets: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'brand-assets' and public.is_staff((select auth.uid())));
-- Staff can see the files (needed to create links); customers just open
-- the public image links, so there is no public "list files" rule.
drop policy if exists "brand-assets: staff read" on storage.objects;
create policy "brand-assets: staff read" on storage.objects for select to authenticated
  using (bucket_id = 'brand-assets' and public.is_staff((select auth.uid())));
drop policy if exists "brand-assets: staff update" on storage.objects;
create policy "brand-assets: staff update" on storage.objects for update to authenticated
  using (bucket_id = 'brand-assets' and public.is_staff((select auth.uid())))
  with check (bucket_id = 'brand-assets' and public.is_staff((select auth.uid())));
drop policy if exists "brand-assets: admin delete" on storage.objects;
create policy "brand-assets: admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'brand-assets' and public.is_admin((select auth.uid())));

-- Done. Refresh the website; the new menu sizes and settings are ready.
