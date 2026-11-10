# Backend build roadmap (PINDI CRUST)

- [x] 1. Database schema: 23 tables + user_roles, grants, RLS, triggers (migration 0000)
- [x] 2. Order RPCs: place_order, validate_promo, track_order, log_activity, send_customer_message, notification trigger (0001)
- [x] 3. Analytics/report RPCs (0002)
- [x] 4. Realtime publication for orders/order_items/notifications (0003)
- [x] 5. Email/password auth enabled; supabaseClient reads Cloud publishable key
- [x] 6. Types regenerated; typecheck + build + 8 tests pass; pages load against live DB
- [x] 7. Restored missing signup profile trigger and granted requested developer/admin access to msamek271@gmail.com
- [ ] 8. Real menu data: added by user via admin panel (no fabricated products)
- [ ] 9. E2E order test once products exist (customer order → admin realtime → kitchen)
- [x] Google sign-in on login and registration, without extra Google profile fields; provider enabled and buttons checked
- [x] Persistent realtime admin order alarm with click acknowledgement; sound and acknowledgement filtering tests pass
- [x] Manual online-payment account name and transaction ID, admin verification, customer notification; server validations and access checks added
- [x] Live Google account sign-in: successful Google signup/login confirmed in hosted auth logs
- [x] Verified real staff session: admin and developer pages accessible, sound enabled, refresh retains access
- [ ] Two-session alarm and payment verification test: requires real admin/customer accounts and menu items; user will test orders
- [ ] Later: wire published settings into storefront (store-config/pricing), payment gateway (needs credentials)
