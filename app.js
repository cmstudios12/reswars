import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/+esm';
const CFG=window.MYANGEL_CONFIG;
const db=createClient(CFG.supabaseUrl,CFG.supabasePublishableKey,{auth:{persistSession:true}});
const $=id=>document.getElementById(id);
const ico=name=>`<svg class="ico" aria-hidden="true"><use href="#ic-${name}"></use></svg>`;
const money=cents=>'R'+(cents/100).toLocaleString('en-ZA',{minimumFractionDigits:0,maximumFractionDigits:2});
const clean=s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
const safeImage=url=>{const s=String(url||'');return (/^assets\/[\w./-]+$/.test(s)||/^https:\/\/[\w.-]+(?:[:0-9]+)?\/[\w%!?#=&+.,/@~-]*$/.test(s))?s:'assets/gogo-square.jpg';};
const dateOf=iso=>new Intl.DateTimeFormat('en-ZA',{timeZone:'Africa/Johannesburg',weekday:'long',day:'2-digit',month:'long',year:'numeric'}).format(new Date(iso));
const shortDate=iso=>new Intl.DateTimeFormat('en-ZA',{timeZone:'Africa/Johannesburg',day:'2-digit',month:'short',year:'numeric'}).format(new Date(iso));
const timeOf=iso=>new Intl.DateTimeFormat('en-ZA',{timeZone:'Africa/Johannesburg',hour:'numeric',minute:'2-digit',hour12:true}).format(new Date(iso));
const today=()=>new Date();
let events=[],current=null,posterIndex=0,format='portrait',selectedTier=null,availability={},loadingBooking=false;
const posterList=()=>[...(current?.event_posters||[])].sort((a,b)=>a.sort_order-b.sort_order);
const tiers=()=>[...(current?.ticket_types||[])].sort((a,b)=>a.sort_order-b.sort_order);
const bookable=t=>!!(current&&current.status==='published'&&new Date(current.starts_at)>today()&&t.active&&t.is_online&&new Date(t.sale_starts_at)<=today()&&new Date(t.sale_ends_at)>today()&&(availability[t.id]===undefined||availability[t.id]===null||availability[t.id]>0));
const imageFor=e=>safeImage(e.cover_image_url||e.event_posters?.[0]?.square_url);
const lowestPrice=e=>{const available=(e.ticket_types||[]).filter(x=>x.active&&x.is_online&&new Date(x.sale_ends_at)>today());return available.length?money(Math.min(...available.map(x=>x.price_cents))):'See event';};
function toast(msg){$('toast').textContent=msg;$('toast').hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>$('toast').hidden=true,4200);}
function renderEventCards(){
 $('eventCount').textContent=`${events.length} ${events.length===1?'upcoming event':'upcoming events'}`;
 if(!events.length){$('eventsGrid').innerHTML='<div class="empty-events"><h3>Something wonderful is coming.</h3><p>There are no published upcoming events right now. Check back soon.</p></div>';return;}
 $('eventsGrid').innerHTML=events.map((e,i)=>`<article class="event-card"><a class="event-poster" href="#event/${encodeURIComponent(e.slug)}" aria-label="View ${clean(e.title)}"><img loading="${i?'lazy':'eager'}" src="${clean(imageFor(e))}" alt="${clean(e.title)} event poster"><span class="status-chip">${i===0?'FEATURED EVENT':'UPCOMING EVENT'}</span></a><div class="event-body"><div class="event-category">${clean(e.category)}</div><h3>${clean(e.title)}</h3><p>${clean(e.subtitle||e.description||'Discover a memorable live experience at My Angel Country Lodge.')}</p><div class="event-facts"><span>${ico('cal')}${clean(shortDate(e.starts_at))}</span><span>${ico('clock')}${clean(timeOf(e.starts_at))} SAST</span><span>${ico('pin')}${clean(e.venue_name)}</span></div><div class="event-bottom"><div><small>Tickets from</small><strong>${clean(lowestPrice(e))}</strong></div><a class="button button-primary" href="#event/${encodeURIComponent(e.slug)}">Explore event ${ico('arrow')}</a></div></div></article>`).join('');
}
async function fetchEvents(){
 $('eventsError').hidden=true;
 const {data,error}=await db.from('events').select('*,event_posters(*),ticket_types(*)').eq('status','published').gte('starts_at',new Date().toISOString()).order('starts_at',{ascending:true});
 if(error){$('eventsGrid').innerHTML='';$('eventsError').hidden=false;$('eventsError').textContent='Unable to load live events. The Supabase database may not be configured yet. Please try again or contact My Angel.';console.error(error);return;}
 events=data||[];renderEventCards();renderRoute();
}
function routeName(){const h=decodeURIComponent(location.hash.replace(/^#/,''));return h||'home';}
function renderRoute(){const r=routeName();$('mobileLinks').classList.remove('open');$('menuToggle').setAttribute('aria-expanded','false');if(r.startsWith('event/')){
 const slug=r.slice(6);const e=events.find(x=>x.slug===slug);if(!e){$('homeView').hidden=false;$('detailView').hidden=true;$('stickyBar').hidden=true;toast('Event not found or not published');return;}
 if(current?.id!==e.id){current=e;availability={};selectedTier=null;posterIndex=0;format='portrait';loadAvailability(e.id);}
 $('homeView').hidden=true;$('detailView').hidden=false;renderDetail();$('stickyBar').hidden=false;window.scrollTo({top:0,behavior:'instant'});
 }else{
 current=null;$('homeView').hidden=false;$('detailView').hidden=true;$('stickyBar').hidden=true;
 if(['events','about','faq'].includes(r))requestAnimationFrame(()=>$(r)?.scrollIntoView({behavior:'smooth'}));else window.scrollTo({top:0,behavior:'instant'});
 }}
async function loadAvailability(eventId){const {data,error}=await db.rpc('myangel_availability',{p_event_id:eventId});if(error){console.warn('Live availability unavailable',error);return;}if(current?.id!==eventId)return;availability=Object.fromEntries((data||[]).map(t=>[t.ticket_type_id,t.remaining]));renderTickets();}
function renderDetail(){if(!current)return;
 const e=current;$('crumbName').textContent=e.title;$('detailCover').src=imageFor(e);$('detailCover').alt=e.title+' poster';$('detailCategory').textContent=(e.category||'Live event').toUpperCase()+' · MY ANGEL EXCLUSIVE';$('detailTitle').textContent=e.title;$('detailSummary').textContent=e.description||e.subtitle||'';$('detailDate').textContent=dateOf(e.starts_at);$('detailTime').textContent=timeOf(e.starts_at);$('detailVenue').textContent=e.venue_name;$('detailArea').textContent=e.venue_area;$('detailFrom').textContent=lowestPrice(e);$('stickyPrice').textContent='From '+lowestPrice(e);$('eventVenueName').textContent=e.venue_name;$('eventVenueArea').textContent=e.venue_area;$('directionsLink').href='https://www.google.com/maps/search/?api=1&query='+encodeURIComponent(`${e.venue_name}, ${e.venue_area}`);
 $('artistGrid').innerHTML=posterList().map((p,i)=>`<button type="button" class="artist-card" data-artist="${i}"><img src="${clean(safeImage(p.square_url))}" loading="lazy" alt="${clean(p.artist_name)} event poster"><strong>${clean(p.artist_name)} ${ico('arrow')}</strong></button>`).join('')||'<p>The full lineup will be announced soon.</p>';
 $('artistGrid').querySelectorAll('[data-artist]').forEach(btn=>btn.addEventListener('click',()=>{posterIndex=Number(btn.dataset.artist);format='portrait';renderGallery();$('gallery').scrollIntoView({behavior:'smooth'});}));
 renderGallery();renderTickets();
}
function renderGallery(){const ps=posterList();const empty=!ps.length;$('galleryStage').hidden=empty;$('galleryDots').hidden=empty;document.querySelector('.gallery-bottom').hidden=empty;if(empty){$('galleryCounter').textContent='No posters';return;}posterIndex=(posterIndex+ps.length)%ps.length;const p=ps[posterIndex];$('galleryImage').src=safeImage(format==='portrait'?p.portrait_url:p.square_url);$('galleryImage').alt=p.artist_name+' '+format+' poster';$('galleryArtist').textContent=p.artist_name;$('galleryCounter').textContent=String(posterIndex+1).padStart(2,'0')+' / '+String(ps.length).padStart(2,'0');$('galleryDots').innerHTML=ps.map((x,i)=>`<button aria-label="View ${clean(x.artist_name)}" data-dot="${i}" class="${i===posterIndex?'active':''}"></button>`).join('');document.querySelectorAll('[data-format]').forEach(b=>b.classList.toggle('selected',b.dataset.format===format));}
function movePoster(n){const count=posterList().length;if(count){posterIndex=(posterIndex+n+count)%count;renderGallery();}}
function tierStatus(t){if(!t.active)return 'Unavailable';if(!t.is_online)return 'At the gate';if(new Date(t.sale_starts_at)>today())return 'Coming soon';if(new Date(t.sale_ends_at)<=today())return 'Sales closed';if(current&&new Date(current.starts_at)<=today())return 'Event finished';if(availability[t.id]===0)return 'Sold out';return 'On sale';}
function renderTickets(){if(!current)return;const ts=tiers();$('tierList').innerHTML=ts.map(t=>{const status=tierStatus(t);return `<div class="tier-row"><div><strong>${clean(t.name)}<span class="tier-badge ${status==='On sale'?'':'off'}">${clean(status)}</span></strong><small>${clean(t.description)}${availability[t.id]!=null&&t.is_online?' · '+availability[t.id]+' left':''}</small></div><span>${money(t.price_cents)}</span></div>`;}).join('')||'<p>Tickets have not been released yet.</p>';
 const canBuy=ts.some(bookable);for(const id of ['heroBook','bottomBook','stickyBook'])$(id).disabled=!canBuy;
 selectedTier=ts.find(x=>x.id===selectedTier&&bookable(x))?.id||ts.find(bookable)?.id||null;
}
function openBooking(){if(!current)return;const ts=tiers().filter(bookable);if(!ts.length){toast('Tickets are not currently available online.');return;}$('bookingStep').hidden=false;$('bookingSuccess').hidden=true;$('bookingError').hidden=true;$('successPaymentIssue').hidden=true;$('bookingQty').value='1';$('bookingTier').innerHTML=ts.map(t=>`<option value="${t.id}">${clean(t.name)} — ${money(t.price_cents)}</option>`).join('');$('bookingTier').value=ts.some(x=>x.id===selectedTier)?selectedTier:ts[0].id;updateTotal();$('bookingOverlay').hidden=false;document.body.classList.add('locked');$('bookingTier').focus();}
function closeBooking(){$('bookingOverlay').hidden=true;document.body.classList.remove('locked');if(!loadingBooking){$('bookingForm').reset();}}
function updateTotal(){const t=tiers().find(x=>x.id===$('bookingTier').value);$('bookingTotal').textContent=money((t?.price_cents||0)*Number($('bookingQty').value||1));}
async function submitBooking(ev){
 ev.preventDefault();if(loadingBooking)return;
 const form=$('bookingForm');if(!form.reportValidity())return;
 const t=tiers().find(x=>x.id===$('bookingTier').value);
 if(!t||!bookable(t)){$('bookingError').textContent='This ticket type is not currently on sale. Please refresh.';$('bookingError').hidden=false;return;}
 const button=$('submitBooking');loadingBooking=true;button.disabled=true;button.textContent='Reserving your tickets…';$('bookingError').hidden=true;
 try{
  const {data,error}=await db.rpc('create_myangel_booking',{
   p_ticket_type_id:t.id,p_buyer_name:$('bookingName').value.trim(),p_buyer_email:$('bookingEmail').value.trim(),
   p_buyer_phone:$('bookingPhone').value.trim(),p_quantity:Number($('bookingQty').value),p_website:$('websiteField').value
  });
  if(error)throw error;
  const b=data?.[0];if(!b)throw Error('No booking details returned. Please contact the lodge before retrying.');
  $('successReference').textContent=b.booking_reference;
  $('successAmount').textContent=`${money(b.amount_cents)} · ${$('bookingQty').value} ticket(s) · ${t.name}`;
  $('successExpiry').textContent='Reservation held until '+new Intl.DateTimeFormat('en-ZA',{timeZone:'Africa/Johannesburg',day:'numeric',month:'short',hour:'numeric',minute:'2-digit'}).format(new Date(b.expires_at))+' (SAST). The lodge must verify payment before then.';
  const msg=`Hello My Angel Country Lodge. I reserved ${$('bookingQty').value} ticket(s) for ${current.title}. Booking reference: ${b.booking_reference}, amount: ${money(b.amount_cents)}. Please share the official payment instructions.`;
  $('reservationStatusLink').href=`payment.html?booking=${encodeURIComponent(b.booking_id)}&ref=${encodeURIComponent(b.booking_reference)}`;
  $('successWhatsapp').href=`https://wa.me/${CFG.whatsapp}?text=${encodeURIComponent(msg)}`;
  $('bookingStep').hidden=true;$('bookingSuccess').hidden=false;
  $('successPaymentIssue').hidden=true;
  loadAvailability(current.id);
 }catch(ex){$('bookingError').textContent=ex.message||'Unable to create booking.';$('bookingError').hidden=false;console.error(ex);}
 finally{loadingBooking=false;button.disabled=false;button.textContent='Reserve my tickets';}
}
$('bookingForm').addEventListener('submit',submitBooking);$('bookingTier').addEventListener('change',updateTotal);$('bookingQty').addEventListener('change',updateTotal);
for(const id of ['heroBook','bottomBook','stickyBook'])$(id).addEventListener('click',openBooking);
$('closeBooking').addEventListener('click',closeBooking);$('successClose').addEventListener('click',closeBooking);$('bookingOverlay').addEventListener('click',e=>{if(e.target===$('bookingOverlay')&&!loadingBooking)closeBooking();});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('bookingOverlay').hidden&&!loadingBooking)closeBooking();if(e.key==='ArrowRight'&&document.activeElement===$('galleryStage'))movePoster(1);if(e.key==='ArrowLeft'&&document.activeElement===$('galleryStage'))movePoster(-1);});
$('menuToggle').addEventListener('click',()=>{const b=$('mobileLinks');b.classList.toggle('open');$('menuToggle').setAttribute('aria-expanded',String(b.classList.contains('open')));});
$('galleryPrev').addEventListener('click',()=>movePoster(-1));$('galleryNext').addEventListener('click',()=>movePoster(1));$('galleryDots').addEventListener('click',e=>{const dot=e.target.closest('[data-dot]');if(dot){posterIndex=Number(dot.dataset.dot);renderGallery();}});document.querySelectorAll('[data-format]').forEach(b=>b.addEventListener('click',()=>{format=b.dataset.format;renderGallery();}));
let pointerStart=null;$('galleryStage').addEventListener('pointerdown',e=>{pointerStart={x:e.clientX,y:e.clientY};});$('galleryStage').addEventListener('pointerup',e=>{if(!pointerStart)return;const dx=e.clientX-pointerStart.x,dy=e.clientY-pointerStart.y;pointerStart=null;if(Math.abs(dx)>45&&Math.abs(dx)>Math.abs(dy)*1.25)movePoster(dx<0?1:-1);});
document.querySelectorAll('.detail-tabs a').forEach(a=>a.addEventListener('click',ev=>{ev.preventDefault();const id=a.getAttribute('href').slice(1);document.getElementById(id)?.scrollIntoView({behavior:'smooth',block:'start'});}));
window.addEventListener('hashchange',renderRoute);fetchEvents();
