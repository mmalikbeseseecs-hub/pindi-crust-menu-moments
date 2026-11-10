DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='place_order';
  d := replace(d, 'delete from _pc_lines;', 'delete from _pc_lines where true;');
  EXECUTE d;
END $do$;