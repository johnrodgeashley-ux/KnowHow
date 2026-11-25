// KnowHow · Supabase Edge Function: turn-credentials  (OPTIONAL)
//
// Gives the video call a relay (TURN) server, so calls still connect on networks that block
// direct device-to-device connections (some school Wi-Fi, mobile data with carrier NAT).
// Without this function the call uses direct connections only (Google STUN).
//
// Set ONE of these as Edge Function secrets (Supabase > Edge Functions > Secrets):
//   Cloudflare (free tier):  CF_TURN_KEY_ID, CF_TURN_API_TOKEN
//   Metered.ca:              METERED_DOMAIN (e.g. knowhow.metered.live), METERED_API_KEY
//   Any TURN server:         TURN_URLS (comma separated), TURN_USERNAME, TURN_CREDENTIAL
//
// Keys stay on the server; the website only receives short-lived credentials.
// Callers must be logged in to KnowHow (Supabase checks the JWT before this runs).

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

type Ice = { urls: string | string[]; username?: string; credential?: string };

async function cloudflare(id: string, token: string): Promise<Ice[]> {
  const r = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${id}/credentials/generate-ice-servers`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ttl: 4 * 3600 }),
  });
  if (!r.ok) throw new Error(`Cloudflare TURN ${r.status}`);
  const d = await r.json();
  const list = Array.isArray(d.iceServers) ? d.iceServers : [d.iceServers];
  return list.filter(Boolean);
}

async function metered(domain: string, key: string): Promise<Ice[]> {
  const r = await fetch(`https://${domain}/api/v1/turn/credentials?apiKey=${encodeURIComponent(key)}`);
  if (!r.ok) throw new Error(`Metered TURN ${r.status}`);
  const d = await r.json();
  return Array.isArray(d) ? d : [];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const env = (k: string) => Deno.env.get(k) || '';
    let iceServers: Ice[] = [];
    if (env('CF_TURN_KEY_ID') && env('CF_TURN_API_TOKEN')) {
      iceServers = await cloudflare(env('CF_TURN_KEY_ID'), env('CF_TURN_API_TOKEN'));
    } else if (env('METERED_DOMAIN') && env('METERED_API_KEY')) {
      iceServers = await metered(env('METERED_DOMAIN'), env('METERED_API_KEY'));
    } else if (env('TURN_URLS')) {
      iceServers = [{
        urls: env('TURN_URLS').split(',').map((u) => u.trim()).filter(Boolean),
        username: env('TURN_USERNAME'),
        credential: env('TURN_CREDENTIAL'),
      }];
    }
    return json({ iceServers });
  } catch (e) {
    return json({ iceServers: [], error: String((e as Error).message || e) }, 200);
  }
});
