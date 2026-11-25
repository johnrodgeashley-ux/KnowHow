// KnowHow · Supabase Edge Function: push
//
// Sends push notifications to phones and computers, even when KnowHow is closed.
//   GET  ?action=key  -> the public key browsers need to subscribe (created on first use)
//   POST              -> deliver one notification; only accepted from the KnowHow database,
//                        which signs each request with a secret stored in public.push_config.
//
// Nothing to configure: keys are created here and kept in the database (public.push_config,
// readable only by the server). Deploy with "Verify JWT" turned OFF, because the database calls it.

import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import webpush from 'npm:web-push@3.6.7';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-kh-secret',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const SUBJECT = 'https://knowhow-eight.vercel.app';

type Config = { vapid_public: string | null; vapid_private: string | null; hook_secret: string | null };

async function config(): Promise<Config> {
  const { data, error } = await admin.from('push_config').select('vapid_public,vapid_private,hook_secret').eq('id', 1).maybeSingle();
  if (error) throw new Error('push_config: ' + error.message);
  let cfg = (data || { vapid_public: null, vapid_private: null, hook_secret: null }) as Config;
  if (!cfg.vapid_public || !cfg.vapid_private) {
    const keys = webpush.generateVAPIDKeys();
    const { error: upErr } = await admin.from('push_config')
      .upsert({ id: 1, vapid_public: keys.publicKey, vapid_private: keys.privateKey }, { onConflict: 'id' });
    if (upErr) throw new Error('push_config save: ' + upErr.message);
    cfg = { ...cfg, vapid_public: keys.publicKey, vapid_private: keys.privateKey };
  }
  return cfg;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const cfg = await config();
    if (req.method === 'GET') return json({ publicKey: cfg.vapid_public });

    if (!cfg.hook_secret || req.headers.get('x-kh-secret') !== cfg.hook_secret) return json({ error: 'forbidden' }, 403);
    const { user_id, title, body, tag, url } = await req.json();
    if (!user_id) return json({ error: 'user_id is required' }, 400);

    webpush.setVapidDetails(SUBJECT, cfg.vapid_public!, cfg.vapid_private!);
    const { data: subs, error } = await admin.from('push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', user_id);
    if (error) throw new Error(error.message);

    const payload = JSON.stringify({ title: title || 'KnowHow', body: body || '', tag: tag || undefined, url: url || '/' });
    let sent = 0;
    for (const s of subs || []) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600, urgency: 'high' });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await admin.from('push_subscriptions').delete().eq('id', s.id); // device unsubscribed
      }
    }
    return json({ sent });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
