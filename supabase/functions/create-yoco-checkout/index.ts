// Public Edge Function: starts a Yoco-hosted checkout against an existing protected booking.
// Deploy with verify_jwt=false and keep the Yoco secret ONLY in Supabase Edge Function secrets.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders, json, serverClient } from '../_shared/http.ts';

Deno.serve(async req => {
  const headers = corsHeaders(req.headers.get('origin'));
  if (req.method === 'OPTIONS') return new Response(null, {status:204,headers});
  if (req.method !== 'POST') return json({error:'Method not allowed'},405,headers);
  const site = Deno.env.get('SITE_URL');
  const secret = Deno.env.get('YOCO_SECRET_KEY');
  if (!site || !secret) return json({error:'Online payments are not configured yet'},503,headers);
  const origin = req.headers.get('origin');
  if (origin && !headers['access-control-allow-origin']) return json({error:'Origin not permitted'},403,headers);
  try {
    const payload = await req.json();
    const bookingId = String(payload?.booking_id ?? '');
    if (!/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(bookingId))
      return json({error:'Invalid booking reference'},400,headers);
    const {url,key} = serverClient();
    const admin = createClient(url,key,{auth:{autoRefreshToken:false,persistSession:false}});
    const {data,error} = await admin.rpc('myangel_prepare_yoco_checkout',{p_booking_id:bookingId});
    if (error) return json({error:error.message},409,headers);
    const order = data?.[0];
    if (!order || !Number.isInteger(order.amount_cents) || order.amount_cents < 200)
      return json({error:'This booking cannot be paid online'},409,headers);
    if (order.checkout_url) return json({redirectUrl:order.checkout_url},200,headers);
    const root = new URL(site);
    if (root.protocol !== 'https:' && root.hostname !== 'localhost' && root.hostname !== '127.0.0.1')
      return json({error:'SITE_URL must use HTTPS'},503,headers);
    const page = (result:string) => {
      const u = new URL('payment.html',root);
      u.searchParams.set('booking',bookingId);
      u.searchParams.set('ref',String(order.booking_reference));
      u.searchParams.set('return',result);
      return u.toString();
    };
    const yocoRes = await fetch('https://payments.yoco.com/api/checkouts',{
      method:'POST',
      headers:{
        'Authorization':`Bearer ${secret}`,
        'Content-Type':'application/json',
        'Idempotency-Key': bookingId,
      },
      body:JSON.stringify({
        amount:order.amount_cents,
        currency:'ZAR',
        successUrl:page('success'),
        failureUrl:page('failure'),
        cancelUrl:page('cancel'),
        metadata:{bookingId,bookingReference:order.booking_reference},
      }),
    });
    if (!yocoRes.ok) {
      // Never log API credentials, Yoco body or buyer contact details.
      console.error('Yoco checkout creation failed with HTTP',yocoRes.status);
      return json({error:'Yoco could not start the payment. Please try again.'},502,headers);
    }
    const checkout = await yocoRes.json();
    const redirectUrl = String(checkout?.redirectUrl||'');
    const redirect = new URL(redirectUrl);
    if (redirect.protocol !== 'https:' ||
        (redirect.hostname !== 'yoco.com' && !redirect.hostname.endsWith('.yoco.com')) ||
        !checkout?.id) throw new Error('Invalid checkout redirect from payment provider');
    const {error:saveError} = await admin.rpc('myangel_attach_yoco_checkout',{
      p_booking_id:bookingId,p_checkout_id:String(checkout.id),p_redirect_url:redirectUrl,
    });
    if (saveError) {
      console.error('Checkout persist failed. Support reconciliation required:', saveError.code);
      return json({error:'Payment session could not be confirmed. Contact the lodge with your booking reference.'},503,headers);
    }
    return json({redirectUrl},200,headers);
  } catch(e) {
    console.error('Yoco checkout processing error:',e instanceof Error?e.name:'Unknown error');
    return json({error:'Unable to open secure payment right now. Please retry shortly.'},503,headers);
  }
});
