# js-push: sending push notifications

The database queues notifications (stale kanji, daily goal) and this function sends them.
Modelled on JALF's `ft-push`, but a **separate Supabase project**, so it needs its own keys
and its own secrets — nothing is shared between the two apps.

## One-time setup

1. **Keys.** Generate a VAPID keypair and save it to `Documents\JS secrets\push-keys.txt`
   (never committed). In any browser console:

   ```js
   (async () => {
     const kp = await crypto.subtle.generateKey({ name:'ECDSA', namedCurve:'P-256' }, true, ['sign','verify']);
     const b64u = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
     console.log('VAPID_PUBLIC_KEY  =', b64u(await crypto.subtle.exportKey('raw', kp.publicKey)));
     console.log('VAPID_PRIVATE_KEY =', (await crypto.subtle.exportKey('jwk', kp.privateKey)).d);
   })();
   ```

2. **Extensions.** Dashboard → Database → Extensions: enable **pg_cron** and **pg_net**.
   The migration needs both and will fail without them.

3. **Migration.** SQL Editor → run `supabase/migrations/001_push_notifications.sql`.

4. **Secrets.** Edge Functions → Secrets, add four:
   - `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` — from step 1
   - `VAPID_SUBJECT` — `https://haydenmquaill.github.io/japanese-study/` (a contact for the push service; a `mailto:` also works)
   - `JS_PUSH_SECRET` — any long random string; also goes in step 6

5. **Deploy.** Edge Functions → Deploy a new function → Via editor. Name it `js-push`,
   paste in `index.ts`, deploy. Then in its settings turn **Enforce JWT verification off** —
   the database authenticates with `JS_PUSH_SECRET` instead.

6. **Point the database at it.** SQL Editor:

   ```sql
   update js_config set value = 'https://nitchusgmixyrbqswdhe.supabase.co/functions/v1/js-push' where key = 'push_url';
   update js_config set value = '<the same string as JS_PUSH_SECRET>' where key = 'push_secret';
   ```

   Until both are set, messages just queue up (and are dropped after an hour).

7. **Public key in the page.** Paste `VAPID_PUBLIC_KEY` into `VAPID_PUBLIC` in `index.html`.
   It must match the secret, or every send fails silently. If you ever regenerate the
   keypair, update both places — every device then has to turn notifications on again.

8. **Turn it on.** Deploy the page, open it, Settings → Notifications → Turn on, then
   **Send test**.

## Checking it works

```sql
select * from js_push_subs;                  -- your devices (one row per device)
select * from js_push_queue;                 -- should empty within seconds of anything queueing
select js_write_stale_count(auth.uid());     -- what the stale notifications are counting
select js_unlocked_today(auth.uid());        -- what the daily goal is counting
select * from js_push_state;                 -- what's already been sent, and when
select * from cron.job where jobname = 'js-notify';
select * from cron.job_run_details order by start_time desc limit 10;
```

If the queue fills but never empties, `push_url` / `push_secret` are wrong or the function
is still enforcing JWT. The function's logs show how many messages were sent, dropped and
failed.

To replay a decision without waiting for the 15-minute cron: `select js_notify_tick();`

## Note on the Android PWA

The installed app caches `index.html` separately from the Chrome tab, so after deploying a
new `VAPID_PUBLIC` the app may still be running the old one. `sw.js` deliberately has no
`fetch` handler to limit this, but if the page looks stale, clear the app's data and cache.
