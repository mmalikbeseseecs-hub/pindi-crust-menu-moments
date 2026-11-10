ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_account_name text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS alarm_acknowledged_at timestamptz;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS alarm_acknowledged_by uuid;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_verified_at timestamptz;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_verified_by uuid;
CREATE OR REPLACE FUNCTION public.validate_manual_payment_details() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NEW.payment <> 'cod' THEN
  NEW.payment_account_name := nullif(trim(current_setting('pindi.payment_account_name',true)), '');
  IF nullif(trim(NEW.transaction_id),'') IS NULL THEN RAISE EXCEPTION 'PC: Transaction ID is required.'; END IF;
  IF NEW.payment_account_name IS NULL THEN RAISE EXCEPTION 'PC: Online account name or username is required.'; END IF;
  IF length(NEW.transaction_id)>40 OR length(NEW.payment_account_name)>100 THEN RAISE EXCEPTION 'PC: Payment details are too long.'; END IF;
  NEW.payment_status := 'pending_verification';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER validate_manual_payment_before_insert BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.validate_manual_payment_details();
CREATE OR REPLACE FUNCTION public.place_order_with_payment_details(p_customer_name text,p_phone text,p_address text,p_payment text,p_source text,p_notes text DEFAULT NULL,p_transaction_id text DEFAULT NULL,p_promo_code text DEFAULT NULL,p_manual_discount_percent numeric DEFAULT 0,p_items jsonb DEFAULT '[]',p_idempotency_key text DEFAULT NULL,p_payment_account_name text DEFAULT NULL)
RETURNS TABLE(order_number text,subtotal numeric,discount numeric,delivery_fee numeric,tax numeric,total numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 PERFORM set_config('pindi.payment_account_name',coalesce(p_payment_account_name,''),true);
 RETURN QUERY SELECT * FROM public.place_order(p_customer_name,p_phone,p_address,p_payment,p_source,p_notes,p_transaction_id,p_promo_code,p_manual_discount_percent,p_items,p_idempotency_key);
END $$;
REVOKE ALL ON FUNCTION public.place_order_with_payment_details(text,text,text,text,text,text,text,text,numeric,jsonb,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_order_with_payment_details(text,text,text,text,text,text,text,text,numeric,jsonb,text,text) TO anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.acknowledge_order_alarm(p_order_number text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'PC: Staff access is required.'; END IF;
 UPDATE public.orders SET alarm_acknowledged_at=now(),alarm_acknowledged_by=auth.uid() WHERE order_number=p_order_number AND alarm_acknowledged_at IS NULL;
END $$;
REVOKE ALL ON FUNCTION public.acknowledge_order_alarm(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.acknowledge_order_alarm(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.guard_payment_verification() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
  IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'PC: Only an admin can verify payment.'; END IF;
  IF NEW.payment_status='verified' THEN
   IF NEW.payment='cod' OR nullif(trim(NEW.transaction_id),'') IS NULL OR nullif(trim(NEW.payment_account_name),'') IS NULL THEN RAISE EXCEPTION 'PC: Payment details are incomplete.'; END IF;
   NEW.payment_verified_at:=now(); NEW.payment_verified_by:=auth.uid();
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_payment_status BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.guard_payment_verification();
CREATE OR REPLACE FUNCTION public.verify_order_payment(p_order_number text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT public.is_admin(auth.uid()) THEN RAISE EXCEPTION 'PC: Only an admin can verify payment.'; END IF;
 UPDATE public.orders SET payment_status='verified' WHERE order_number=p_order_number AND payment<>'cod' AND payment_status<>'verified';
 IF NOT FOUND AND NOT EXISTS(SELECT 1 FROM public.orders WHERE order_number=p_order_number AND payment_status='verified') THEN RAISE EXCEPTION 'PC: No online payment to verify.'; END IF;
END $$;
REVOKE ALL ON FUNCTION public.verify_order_payment(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_order_payment(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.notify_payment_verified() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NEW.payment_status='verified' AND OLD.payment_status IS DISTINCT FROM NEW.payment_status AND NEW.customer_id IS NOT NULL THEN
 INSERT INTO public.notifications(customer_id,title,body,type) VALUES(NEW.customer_id,'Payment verified — '||NEW.order_number,'The admin has verified your online payment for order '||NEW.order_number||'.','order');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER payment_verification_notification AFTER UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.notify_payment_verified();