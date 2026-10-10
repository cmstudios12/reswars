export const json = (data: unknown, status = 200, headers: Record<string,string> = {}) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json; charset=utf-8', ...headers } });

export function corsHeaders(origin: string | null): Record<string,string> {
  const site = Deno.env.get('SITE_URL') || '';
  let allowed = '';
  try {
    const siteOrigin = new URL(site).origin;
    if (origin === siteOrigin) allowed = siteOrigin;
    else if (origin && /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) allowed = origin;
  } catch { /* require SITE_URL setup */ }
  return {
    ...(allowed ? {'access-control-allow-origin': allowed} : {}),
    'access-control-allow-headers': 'apikey, authorization, content-type, x-client-info',
    'access-control-allow-methods': 'POST, OPTIONS',
    'vary': 'origin',
  };
}

export function serverClient() {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('Supabase server credentials not configured');
  return { url, key };
}
