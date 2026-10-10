import {createClient} from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/+esm';
const CFG=window.MYANGEL_CONFIG;
const db=createClient(CFG.supabaseUrl,CFG.supabasePublishableKey);
const $=id=>document.getElementById(id);
const params=new URLSearchParams(location.search),booking=params.get('booking')||'',reference=params.get('ref')||'';
const valid=/^[0-9a-f]{8}-[0-9a-f-]{27,40}$/i.test(booking)&&/^MYA-[0-9A-F]+$/.test(reference);
$('orderRef').textContent=valid?reference:'Booking not found';
function state(s){$('paymentState').textContent=s;}
function tickets(codes){const list=$('ticketResults');list.replaceChildren();codes.forEach((code,i)=>{const a=document.createElement('a');a.href=`ticket.html?code=${encodeURIComponent(code)}`;a.target='_blank';a.rel='noopener';a.textContent=`Ticket ${i+1} · Open your QR pass`;list.append(a);});list.hidden=!codes.length;}
let busy=false;
async function refresh(){if(!valid||busy)return;busy=true;$('retryPay').disabled=true;
 try{const {data,error}=await db.rpc('myangel_receipt_status',{p_booking_id:booking,p_booking_reference:reference});if(error)throw error;const b=data?.[0];if(!b)throw Error('Reservation not found. Check your link.');
 if(b.booking_status==='paid'){state('Payment confirmed. Your PDF tickets are being emailed to you. The individual QR passes are also available below.');tickets(b.ticket_codes||[]);}
 else if(b.booking_status==='pending'){state('Reservation saved. Payment is awaiting confirmation by My Angel staff. Contact the lodge with your reference for official payment instructions. Your PDF tickets will be emailed only after confirmation.');}
 else if(b.booking_status==='expired'){state('Reservation has expired. Contact My Angel to arrange a new reservation; do not pay an expired one.');}
 else{state('Booking status: '+b.booking_status+'. Contact the lodge if you need assistance.');}
 }catch(ex){state(ex.message||'Could not load booking status.');}
 finally{busy=false;$('retryPay').disabled=false;}
}
$('retryPay').addEventListener('click',refresh);
if(!valid)state('This booking link is missing its reference. Use the link you received after reserving.');else refresh();
