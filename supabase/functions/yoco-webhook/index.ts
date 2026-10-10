// Yoco webhook endpoint. Auth is via Standard Webhooks HMAC (NOT browser JWT).
// Deploy with verify_jwt=false. Never accept client-driven order completion.
import { createClient } from 'npm:@supabase/supabase-js@2';
import {json, serverClient} from '../_shared/http.ts';

function fromBase64(input:string):Uint8Array {
  const str=atob(input);
  return Uint8Array.from(str,c=>c.charCodeAt(0));
}
async function verifyWebhook(req:Request, raw:string, secret:string):Promise<boolean> {
  const id=req.headers.get('webhook-id')||'';
  const timestamp=req.headers.get('webhook-timestamp')||'';
  const signature=req.headers.get('webhook-signature')||'';
  if (!id || !/^\d{10}$/.test(timestamp) || !signature || !secret.startsWith('whsec_')) return false;
  if (Math.abs(Date.now()/1000-Number(timestamp))>300) return false;
  const key=await crypto.subtle.importKey('raw',fromBase64(secret.slice(6)),
    {name:'HMAC',hash:'SHA-256'},false,['verify']);
  const bytes=new TextEncoder().encode(`${id}.${timestamp}.${raw}`);
  for (const fragment of signature.split(/\s+/)) {
    const parts=fragment.split(',');
    if (parts[0]!=='v1'||!parts[1]) continue;
    try {if (await crypto.subtle.verify('HMAC',key,fromBase64(parts[1]),bytes)) return true;}
    catch { /* malformed signature */ }
  }
  return false;
}

Deno.serve(async req=>{
  if(req.method!=='POST') return json({error:'Method not allowed'},405);
  const secret=Deno.env.get('YOCO_WEBHOOK_SECRET');
  const mode=Deno.env.get('YOCO_MODE'); // required: test or live
  if(!secret || !['test','live'].includes(mode||'')) return json({error:'Webhook not configured'},503);
  const raw=await req.text();
  if(raw.length>100_000) return json({error:'Payload too large'},413);
  if(!(await verifyWebhook(req,raw,secret))) return json({error:'Invalid webhook signature'},401);
  try {
    const event=JSON.parse(raw);
    const payload=event?.payload;
    if (!['payment.succeeded','payment.failed','refund.succeeded','refund.failed'].includes(event?.type))
      return json({received:true,ignored:true});
    if(event.id!==req.headers.get('webhook-id')) return json({error:'Event identifier mismatch'},400);
    if(payload?.mode!==mode) return json({error:'Webhook environment mismatch'},400);
    const expectedMerchant=Deno.env.get('YOCO_MERCHANT_ID');
    if(expectedMerchant && payload?.merchantId!==expectedMerchant) return json({error:'Merchant mismatch'},400);
    if(payload?.status!==(event.type.endsWith('succeeded')?'succeeded':'failed'))
      return json({error:'Payment status mismatch'},400);
    const metadata=payload?.metadata||{};
    if(event.type.startsWith('refund.')){
      const checkoutId=String(metadata.checkoutId||'');
      const refundId=String(payload?.id||'');
      const amount=payload?.amount;
      if(checkoutId.length<5||refundId.length<3||!Number.isInteger(amount))
        return json({error:'Refund metadata missing'},400);
      const {url,key}=serverClient();
      const admin=createClient(url,key,{auth:{autoRefreshToken:false,persistSession:false}});
      const {data,error}=await admin.rpc('myangel_apply_yoco_refund',{
        p_event_id:String(event.id),p_event_type:String(event.type),p_checkout_id:checkoutId,
        p_refund_id:refundId,p_amount_cents:amount,p_currency:String(payload.currency||''),
      });
      if(error){console.error('Refund reconciliation failure',error.code);return json({error:'Refund processing failed'},500);}
      return json({received:true,outcome:data});
    }
    const bookingId=String(metadata.bookingId||'');
    const ref=String(metadata.bookingReference||'');
    const paymentId=String(payload?.id||'');
    const amount=payload?.amount;
    if(!/^[0-9a-f-]{36}$/i.test(bookingId)||ref.length<5||paymentId.length<3||!Number.isInteger(amount))
      return json({error:'Invalid Yoco payment metadata'},400);
    const {url,key}=serverClient();
    const admin=createClient(url,key,{auth:{autoRefreshToken:false,persistSession:false}});
    const {data,error}=await admin.rpc('myangel_apply_yoco_webhook',{
      p_event_id:String(event.id),p_event_type:String(event.type),
      p_booking_id:bookingId,p_booking_reference:ref,p_payment_id:paymentId,
      p_amount_cents:amount,p_currency:String(payload.currency||''),
    });
    if(error){console.error('Payment reconciliation error',error.code);return json({error:'Unable to process event'},500);}
    if(String(data).includes('review')||data==='amount_mismatch')console.error('Yoco payment needs operator review:',data,bookingId);
    return json({received:true,outcome:data});
  } catch(e){console.error('Malformed Yoco webhook:',e instanceof Error?e.name:'Unknown');return json({error:'Cannot process payment event'},400);}
});
