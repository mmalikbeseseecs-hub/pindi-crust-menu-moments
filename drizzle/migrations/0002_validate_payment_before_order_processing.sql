CREATE OR REPLACE FUNCTION public.place_order_with_payment_details(p_customer_name text,p_phone text,p_address text,p_payment text,p_source text,p_notes text DEFAULT NULL,p_transaction_id text DEFAULT NULL,p_promo_code text DEFAULT NULL,p_manual_discount_percent numeric DEFAULT 0,p_items jsonb DEFAULT '[]',p_idempotency_key text DEFAULT NULL,p_payment_account_name text DEFAULT NULL)
RETURNS TABLE(order_number text,subtotal numeric,discount numeric,delivery_fee numeric,tax numeric,total numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF p_payment IN ('easypaisa','jazzcash') THEN
  IF nullif(trim(p_transaction_id),'') IS NULL THEN RAISE EXCEPTION 'PC: Transaction ID is required.'; END IF;
  IF nullif(trim(p_payment_account_name),'') IS NULL THEN RAISE EXCEPTION 'PC: Online account name or username is required.'; END IF;
  IF length(p_transaction_id)>40 OR length(p_payment_account_name)>100 THEN RAISE EXCEPTION 'PC: Payment details are too long.'; END IF;
 END IF;
 PERFORM set_config('pindi.payment_account_name',coalesce(p_payment_account_name,''),true);
 RETURN QUERY SELECT * FROM public.place_order(p_customer_name,p_phone,p_address,p_payment,p_source,p_notes,p_transaction_id,p_promo_code,p_manual_discount_percent,p_items,p_idempotency_key);
END $$;