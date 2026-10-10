// My Angel Country Lodge: STAFF-ONLY one-email-per-booking PDF delivery.
// Called only after manual payment was independently verified in the admin portal.
// env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY, RESEND_FROM, SITE_URL
import { createClient } from 'npm:@supabase/supabase-js@2.58.0';
import { PDFDocument, StandardFonts, rgb, degrees } from 'npm:pdf-lib@1.17.1';
import QRCode from 'npm:qrcode@1.5.4';

const hdr={ 'content-type':'application/json', 'access-control-allow-origin':'*', 'access-control-allow-headers':'authorization,content-type,apikey,x-client-info', 'access-control-allow-methods':'POST,OPTIONS' };
const json=(obj:unknown,status=200)=>new Response(JSON.stringify(obj),{status,headers:hdr});
const esc=(s:unknown)=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
const money=(cents:number)=>'R'+(cents/100).toFixed(2);
const tdate=(value:string)=>new Intl.DateTimeFormat('en-ZA',{timeZone:'Africa/Johannesburg',day:'2-digit',month:'long',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(value))+' SAST';
const C={orange:rgb(.906,.427,.133),dark:rgb(.15,.14,.13),muted:rgb(.45,.4,.36),white:rgb(1,1,1),cream:rgb(1,.973,.94)};
const hex=/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i;
function short(str:string,font:any,size:number,max:number){let s=String(str||'-').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').replace(/[^\x20-\x7E]/g,' ');while(s.length>1&&font.widthOfTextAtSize(s,size)>max)s=s.slice(0,-1);return s;}
async function optionalImage(base:string,raw:string,doc:PDFDocument){
 try{
   // Public event images only; never fetch private URLs/IPs from the database.
   const url=new URL(raw,base);
   if(url.protocol!=='https:'&&url.hostname!=='localhost')return null;
   if(['127.0.0.1','169.254.169.254','0.0.0.0','localhost'].includes(url.hostname)&&url.hostname!=='localhost')return null;
   const res=await fetch(url,{signal:AbortSignal.timeout(4500)});
   if(!res.ok)return null;
   const len=Number(res.headers.get('content-length')||0);if(len>2000000)return null;
   const bytes=new Uint8Array(await res.arrayBuffer());if(bytes.byteLength>2000000)return null;
   const type=res.headers.get('content-type')||'';
   if(type.includes('png')||/\.png$/i.test(url.pathname))return await doc.embedPng(bytes);
   if(type.includes('jpeg')||/\.jpe?g$/i.test(url.pathname))return await doc.embedJpg(bytes);
   return null;
 }catch{return null;}
}
function drawImageContain(page:any,img:any,x:number,y:number,w:number,h:number){
 const iw=img.width,ih=img.height,ratio=Math.min(w/iw,h/ih),dw=iw*ratio,dh=ih*ratio;
 page.drawImage(img,{x:x+(w-dw)/2,y:y+(h-dh)/2,width:dw,height:dh});
}
function drawImageCover(page:any,img:any,x:number,y:number,w:number,h:number){
 const ratio=Math.max(w/img.width,h/img.height),dw=img.width*ratio,dh=img.height*ratio;
 // draw image as cover in a clipped region; PDF content clipping is avoided by
 // using a square poster for the 310x310 presentation.
 page.drawImage(img,{x:x+(w-dw)/2,y:y+(h-dh)/2,width:dw,height:dh});
}
async function pdfTickets(book:any,event:any,tier:any,tickets:any[],base:string){
 const doc=await PDFDocument.create();
 const normal=await doc.embedFont(StandardFonts.Helvetica),bold=await doc.embedFont(StandardFonts.HelveticaBold);
 const logo=await optionalImage(base,'assets/myangel-logo.png',doc);
 const poster=await optionalImage(base,event.cover_image_url||'assets/gogo-square.jpg',doc);
 for(const [i,t] of tickets.entries()){
  const p=doc.addPage([1120,720]);
  p.drawRectangle({x:0,y:0,width:1120,height:720,color:C.cream});
  p.drawRectangle({x:22,y:28,width:1076,height:665,color:C.white,borderColor:C.orange,borderWidth:2});
  p.drawRectangle({x:23,y:185,width:1074,height:167,color:C.orange});
  if(logo)drawImageContain(p,logo,48,585,410,94);
  else {p.drawText('MY ANGEL',{x:60,y:631,font:bold,size:39,color:C.dark});p.drawText('COUNTRY LODGE - EVENTS & TICKETING',{x:62,y:610,font:bold,size:12,color:C.orange});}
  p.drawText('OFFICIAL EVENT ADMISSION',{x:820,y:660,font:bold,size:13,color:C.muted});
  p.drawText(short(t.serial,bold,12,250),{x:829,y:638,font:normal,size:12,color:C.muted});
  p.drawRectangle({x:53,y:218,width:324,height:324,color:C.white,borderColor:C.white,borderWidth:4});
  if(poster)drawImageContain(p,poster,57,222,316,316);
  else {p.drawText('MY ANGEL',{x:100,y:403,font:bold,size:30,color:C.orange});p.drawText('EVENT ADMISSION',{x:100,y:376,font:bold,size:15,color:C.dark});}
  p.drawRectangle({x:397,y:348,width:2,height:205,color:rgb(.73,.66,.60)});
  p.drawText('DO NOT DUPLICATE',{x:417,y:377,rotate:degrees(90),font:bold,size:12,color:C.orange});
  p.drawText(short(event.title.toUpperCase(),bold,26,606),{x:460,y:558,font:bold,size:26,color:C.dark});
  p.drawText('MY ANGEL COUNTRY LODGE | ADMISSION PASS',{x:460,y:534,font:bold,size:11,color:C.orange});
  const fields:[string,string][]=[['GUEST',book.buyer_name],['EMAIL',book.buyer_email],['PHONE',book.buyer_phone],['DATE & TIME',tdate(event.starts_at)],['AGE RESTRICTION',event.age_restriction||'Confirm with lodge'],['AREA / TICKET',tier.name],['PRICE',money(book.unit_price_cents)]];
  let fy=513;
  for(const [label,value] of fields){p.drawText(label,{x:460,y:fy,font:bold,size:10,color:C.muted});p.drawText(short(String(value),normal,14,410),{x:620,y:fy-1,font:label==='PRICE'?bold:normal,size:14,color:C.dark});fy-=27;}
  p.drawText('ONE NIGHT. ONE TICKET.',{x:424,y:283,font:bold,size:20,color:C.white});
  p.drawText(short(event.venue_name+'  |  '+event.venue_area,normal,13,427),{x:424,y:253,font:normal,size:13,color:C.white});
  p.drawText(short('Booking: '+book.reference+'  |  Serial: '+t.serial,normal,10.5,428),{x:424,y:231,font:normal,size:10.5,color:C.white});
  p.drawText('2026 My Angel Country Lodge. All rights reserved.',{x:424,y:198,font:normal,size:10,color:C.white});
  const qrValue=new URL('ticket.html?code='+encodeURIComponent(t.scan_code),base).href;
  const qrData=await QRCode.toDataURL(qrValue,{errorCorrectionLevel:'M',width:470,margin:1});
  const qr=await doc.embedPng(Uint8Array.from(atob(qrData.split(',')[1]),c=>c.charCodeAt(0)));
  p.drawRectangle({x:854,y:195,width:204,height:205,color:C.white,borderColor:C.white,borderWidth:2});
  p.drawImage(qr,{x:866,y:208,width:178,height:178});
  p.drawText('ADMIT ONE',{x:873,y:158,font:bold,size:27,color:C.dark});
  p.drawText('IMPORTANT ENTRY INSTRUCTIONS',{x:56,y:137,font:bold,size:17,color:C.dark});
  const instr=['Present QR at the gate','One-time scan, no duplicates','Keep this ticket private'];
  for(let k=0;k<3;k++){const xx=58+k*338;p.drawText('0'+(k+1),{x:xx,y:97,font:bold,size:15,color:C.orange});p.drawText(instr[k],{x:xx+30,y:97,font:normal,size:13,color:C.dark});}
  p.drawText('Ticket '+(i+1)+' of '+tickets.length,{x:978,y:53,font:normal,size:11,color:C.muted});
 }
 return await doc.save();
}
function b64(bytes:Uint8Array){let out='';const size=8192;for(let i=0;i<bytes.length;i+=size)out+=String.fromCharCode(...bytes.subarray(i,i+size));return btoa(out);}
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{headers:hdr});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 const base=(Deno.env.get('SITE_URL')||'').replace(/\/?$/,'/');
 const from=Deno.env.get('RESEND_FROM')||'',key=Deno.env.get('RESEND_API_KEY')||'';
 const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'',endpoint=Deno.env.get('SUPABASE_URL')||'';
 if(!base||!base.startsWith('https://')||!from||!key||!service||!endpoint)return json({error:'Missing SITE_URL, RESEND_FROM, RESEND_API_KEY or Supabase secrets'},503);
 const token=req.headers.get('Authorization')?.replace(/^Bearer\s+/i,'')||'';
 if(!token)return json({error:'Staff sign-in required'},401);
 const db=createClient(endpoint,service,{auth:{autoRefreshToken:false,persistSession:false}});
 const {data:person,error:authError}=await db.auth.getUser(token);
 if(authError||!person.user)return json({error:'Staff sign-in expired'},401);
 const {data:staff,error:staffError}=await db.from('staff_users').select('role').eq('user_id',person.user.id).maybeSingle();
 if(staffError||!staff)return json({error:'Only My Angel staff can send tickets'},403);
 let body:any;try{body=await req.json();}catch{return json({error:'Invalid request'},400);}
 if(body?.demo_email===true){
   // Staff-only sender verification: send to the already authenticated staff email only.
   // This never issues a DB ticket and its QR points to a NONEXISTENT random code.
   if(!person.user.email)return json({error:'Staff email address is missing'},400);
   try {
     const demoBooking={buyer_name:'My Angel Demo Guest',buyer_email:person.user.email,buyer_phone:'DEMO ONLY',unit_price_cents:0,reference:'DEMO-NOT-VALID'};
     const demoEvent={title:'MY ANGEL COMEDY FEST',starts_at:'2026-12-04T18:00:00+02:00',venue_name:'My Angel Country Lodge',venue_area:'Mjejane, Nkomazi',cover_image_url:'assets/gogo-square.jpg',age_restriction:'Confirm with the lodge'};
     const demoTier={name:'SAMPLE - NO ADMISSION'};
     const demoTickets=[{serial:'SAMPLE-NOT-VALID',scan_code:crypto.randomUUID()}];
     const original=await pdfTickets(demoBooking,demoEvent,demoTier,demoTickets,base);
     const watermarked=await PDFDocument.load(original);
     const page=watermarked.getPages()[0],font=await watermarked.embedFont(StandardFonts.HelveticaBold);
     page.drawRectangle({x:0,y:0,width:1120,height:720,color:rgb(1,1,1),opacity:.10});
     for(const y of [150,355,560])page.drawText('SAMPLE - NOT VALID',{x:130,y,font,size:69,rotate:degrees(-14),color:rgb(.7,.09,.07),opacity:.58});
     const attachment=b64(await watermarked.save());
     const result=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+key,'content-type':'application/json'},body:JSON.stringify({from,to:[person.user.email],subject:'MY ANGEL EVENTS - DEMO PDF TICKET (NOT VALID)',html:`<div style="font-family:Arial,sans-serif;max-width:580px;margin:auto;color:#29231f"><h1 style="color:#dd6b27">My Angel Country Lodge</h1><h2>Ticket email demonstration</h2><p>This is a <b>REAL TEST EMAIL</b> to confirm our ticket delivery system. The attached PDF shows the official design but is clearly watermarked <b>SAMPLE - NOT VALID</b> and will not admit anyone.</p><p>No payment has been recorded or requested. No entry ticket has been issued.</p><p>My Angel Events Team</p></div>`,attachments:[{filename:'MY-ANGEL-DEMO-NOT-VALID.pdf',content:attachment,content_type:'application/pdf'}]})});
     const resultBody=await result.json().catch(()=>({}));
     if(!result.ok||!resultBody.id)throw Error('Resend rejected demo email: '+String(resultBody.message||result.status));
     return json({status:'demo_sent',recipient:person.user.email,email_id:resultBody.id});
   }catch(err){console.error('My Angel demo email error',err);return json({error:String((err as Error).message||err)},500);}
 }
 const bookingId=String(body?.booking_id||'');if(!hex.test(bookingId))return json({error:'Invalid booking ID'},400);
 const {data:claim,error:claimErr}=await db.rpc('myangel_claim_ticket_email',{p_booking_id:bookingId});
 if(claimErr)return json({error:claimErr.message},400);
 if(claim==='already_sent')return json({status:'already_sent'});
 if(claim==='in_progress')return json({status:'in_progress'});
 try{
  const {data:booking,error:be}=await db.from('bookings').select('*').eq('id',bookingId).single();if(be||!booking)throw Error('Booking not found');
  const [{data:event,error:ee},{data:tier,error:te},{data:tickets,error:ti}]=await Promise.all([
   db.from('events').select('*').eq('id',booking.event_id).single(),
   db.from('ticket_types').select('name').eq('id',booking.ticket_type_id).single(),
   db.from('tickets').select('serial,scan_code,status').eq('booking_id',bookingId).order('issued_at')
  ]);
  if(ee||te||ti||!event||!tier||!tickets||tickets.length!==booking.quantity||tickets.some(t=>t.status!=='valid'))throw Error('Issued tickets are incomplete, used, or void');
  const pdf=await pdfTickets(booking,event,tier,tickets,base);
  const name=esc(booking.buyer_name),eventName=esc(event.title),ref=esc(booking.reference);
  const html=`<!doctype html><html><body style="margin:0;padding:36px 12px;background:#fff8ee;color:#2b261f;font-family:Arial,sans-serif"><div style="max-width:620px;background:#fff;margin:auto;border:1px solid #f2dfc9;border-radius:16px;overflow:hidden"><div style="padding:32px 34px;background:#fff"><div style="font-size:25px;font-weight:900;letter-spacing:-1px">MY ANGEL <span style="color:#e76d22">EVENTS</span></div><div style="letter-spacing:3px;font-size:11px;color:#9b725a;margin-top:6px">COUNTRY LODGE</div></div><div style="padding:10px 34px 36px"><div style="color:#d7652b;font-weight:700;font-size:12px;letter-spacing:2px">PAYMENT CONFIRMED · TICKETS ATTACHED</div><h1 style="font-size:31px;line-height:1.2;margin:16px 0">Your tickets are ready.</h1><p style="line-height:1.75">Hello ${name},<br>My Angel Country Lodge has confirmed your payment for <b>${eventName}</b>. Attached is your official admission PDF containing <b>${tickets.length} individual QR ticket${tickets.length>1?'s':''}</b>.</p><div style="padding:20px;background:#fff7ed;border-left:4px solid #e76d22;line-height:1.8"><b>Booking:</b> ${ref}<br><b>Event:</b> ${eventName}<br><b>When:</b> ${esc(tdate(event.starts_at))}<br><b>Venue:</b> ${esc(event.venue_name+', '+event.venue_area)}<br><b>Quantity:</b> ${tickets.length}<br><b>Total paid:</b> ${money(booking.total_cents)}</div><p style="line-height:1.75;margin-top:22px">Show each ticket's QR code at the entrance. Every QR code is valid for <b>one entry only</b>; please do not forward your ticket to others.</p><p style="line-height:1.7">See you at My Angel!<br><b>My Angel Events Team</b></p></div><div style="background:#e76d22;color:white;padding:22px 34px;font-size:12px">My Angel Country Lodge · Mjejane, Nkomazi · +27 79 868 2198</div></div></body></html>`;
  const res=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+key,'content-type':'application/json','Idempotency-Key':'myangel-pdf-v1-'+bookingId},body:JSON.stringify({from,to:[booking.buyer_email],subject:'Your My Angel tickets are ready | '+event.title,html,attachments:[{filename:'MyAngel-Tickets-'+booking.reference+'.pdf',content:b64(pdf),content_type:'application/pdf'}]})});
  const out=await res.json().catch(()=>({}));
  if(!res.ok||!out.id)throw Error('Resend rejected email: '+String(out.message||res.status));
  const {error:doneErr}=await db.rpc('myangel_finish_ticket_email',{p_booking_id:bookingId,p_ok:true,p_provider_id:out.id});
  if(doneErr)throw Error('Resend accepted the email but saving delivery status failed. Check logs before retrying: '+doneErr.message);
  return json({status:'sent',email_id:out.id,tickets:tickets.length});
 }catch(err){
  const message=String((err as Error).message||err);
  console.error('My Angel ticket-email error',message);
  await db.rpc('myangel_finish_ticket_email',{p_booking_id:bookingId,p_ok:false,p_error:message});
  return json({error:message},500);
 }
});
