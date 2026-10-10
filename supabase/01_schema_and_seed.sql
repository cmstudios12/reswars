-- MY ANGEL EVENTS - initial production-shaped schema
-- Run once in Supabase SQL Editor (back up an existing project first).
-- This script creates its own objects; it does not drop existing objects.
create extension if not exists pgcrypto;

create table if not exists public.staff_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'staff' check (role in ('admin','staff')),
  created_at timestamptz not null default now()
);

create or replace function public.is_myangel_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.staff_users where user_id = (select auth.uid()));
$$;

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title text not null check (length(title) between 3 and 150),
  subtitle text not null default '',
  description text not null default '',
  category text not null default 'Live event',
  venue_name text not null default 'My Angel Country Lodge',
  venue_area text not null default 'Mjejane, Nkomazi, Mpumalanga',
  starts_at timestamptz not null,
  ends_at timestamptz,
  cover_image_url text,
  status text not null default 'draft' check (status in ('draft','published','cancelled')),
  featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.event_posters (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  artist_slug text not null,
  artist_name text not null,
  portrait_url text not null,
  square_url text not null,
  sort_order integer not null default 0,
  unique(event_id, artist_slug)
);

create table if not exists public.ticket_types (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  code text not null,
  name text not null,
  description text not null default '',
  price_cents integer not null check (price_cents >= 0),
  capacity integer check (capacity is null or capacity >= 0),
  sale_starts_at timestamptz not null,
  sale_ends_at timestamptz not null,
  is_online boolean not null default true,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique(event_id, code),
  check (sale_ends_at > sale_starts_at)
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  event_id uuid not null references public.events(id),
  ticket_type_id uuid not null references public.ticket_types(id),
  buyer_name text not null,
  buyer_email text not null,
  buyer_phone text not null,
  quantity integer not null check (quantity between 1 and 10),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  total_cents integer not null check (total_cents >= 0),
  status text not null default 'pending' check (status in ('pending','paid','cancelled','expired','refunded')),
  hold_expires_at timestamptz not null,
  payment_method text not null default 'manual' check (payment_method in ('manual','gateway')),
  payment_reference text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bookings_type_status_idx on public.bookings(ticket_type_id, status, hold_expires_at);
create index if not exists bookings_created_idx on public.bookings(created_at desc);
create index if not exists bookings_email_idx on public.bookings(lower(buyer_email), created_at desc);

create table if not exists public.tickets (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  event_id uuid not null references public.events(id),
  serial text not null unique,
  scan_code uuid not null default gen_random_uuid() unique,
  status text not null default 'valid' check (status in ('valid','used','void')),
  issued_at timestamptz not null default now(),
  used_at timestamptz,
  used_by uuid references auth.users(id)
);
create index if not exists tickets_booking_idx on public.tickets(booking_id);

create table if not exists public.event_audit (
  id bigint generated always as identity primary key,
  action text not null,
  actor_id uuid references auth.users(id),
  booking_id uuid references public.bookings(id),
  description text,
  created_at timestamptz not null default now()
);

-- The browser may read published events, active tiers and artwork only.
alter table public.staff_users enable row level security;
alter table public.events enable row level security;
alter table public.event_posters enable row level security;
alter table public.ticket_types enable row level security;
alter table public.bookings enable row level security;
alter table public.tickets enable row level security;
alter table public.event_audit enable row level security;

create policy "Staff see own role" on public.staff_users for select to authenticated using (user_id=(select auth.uid()));
create policy "Public published events" on public.events for select to anon, authenticated using (status='published' or (select public.is_myangel_staff()));
create policy "Staff create events" on public.events for insert to authenticated with check ((select public.is_myangel_staff()));
create policy "Staff edit events" on public.events for update to authenticated using ((select public.is_myangel_staff())) with check ((select public.is_myangel_staff()));
create policy "Staff delete events" on public.events for delete to authenticated using ((select public.is_myangel_staff()));
create policy "Published event posters" on public.event_posters for select to anon, authenticated using (exists(select 1 from public.events e where e.id=event_id and e.status='published') or (select public.is_myangel_staff()));
create policy "Staff manage posters" on public.event_posters for all to authenticated using ((select public.is_myangel_staff())) with check ((select public.is_myangel_staff()));
create policy "Published event ticket types" on public.ticket_types for select to anon, authenticated using (exists(select 1 from public.events e where e.id=event_id and e.status='published') or (select public.is_myangel_staff()));
create policy "Staff manage ticket types" on public.ticket_types for all to authenticated using ((select public.is_myangel_staff())) with check ((select public.is_myangel_staff()));
create policy "Staff read bookings" on public.bookings for select to authenticated using ((select public.is_myangel_staff()));
create policy "Staff read issued tickets" on public.tickets for select to authenticated using ((select public.is_myangel_staff()));
create policy "Staff read audit" on public.event_audit for select to authenticated using ((select public.is_myangel_staff()));

-- Dedicated public bucket; only authorised lodge staff can upload/change image files.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('myangel-posters','myangel-posters',true,10485760,array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "My Angel posters public read" on storage.objects for select to public using (bucket_id='myangel-posters');
create policy "My Angel staff upload posters" on storage.objects for insert to authenticated with check (bucket_id='myangel-posters' and (select public.is_myangel_staff()));
create policy "My Angel staff update posters" on storage.objects for update to authenticated using (bucket_id='myangel-posters' and (select public.is_myangel_staff())) with check (bucket_id='myangel-posters' and (select public.is_myangel_staff()));
create policy "My Angel staff delete posters" on storage.objects for delete to authenticated using (bucket_id='myangel-posters' and (select public.is_myangel_staff()));

-- Create bookings from a SECURITY DEFINER RPC. Price and capacity are NEVER trusted from the browser.
create or replace function public.create_myangel_booking(
  p_ticket_type_id uuid, p_buyer_name text, p_buyer_email text,
  p_buyer_phone text, p_quantity integer, p_website text default ''
) returns table(booking_id uuid, booking_reference text, amount_cents integer, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_type public.ticket_types%rowtype;
  v_event public.events%rowtype;
  v_count bigint;
  v_reference text;
  v_id uuid;
  v_name text := trim(coalesce(p_buyer_name,''));
  v_email text := lower(trim(coalesce(p_buyer_email,'')));
  v_phone text := trim(coalesce(p_buyer_phone,''));
  v_expires timestamptz;
begin
  if coalesce(p_website,'') <> '' then raise exception 'Invalid request'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then raise exception 'Choose 1 to 10 tickets'; end if;
  if length(v_name) < 2 or length(v_name) > 100 then raise exception 'Enter a valid full name'; end if;
  if length(v_email) > 254 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email'; end if;
  if length(v_phone) < 9 or length(v_phone) > 25 or v_phone !~ '^[+0-9 ()-]+$' then raise exception 'Enter a valid phone number'; end if;
  -- Serializes concurrent purchase attempts for a specific ticket type.
  select * into v_type from public.ticket_types where id=p_ticket_type_id for update;
  if not found then raise exception 'Ticket type not found'; end if;
  select * into v_event from public.events where id=v_type.event_id;
  if v_event.status <> 'published' or v_event.starts_at <= now() then raise exception 'This event is not on sale'; end if;
  if not v_type.active or not v_type.is_online or now() < v_type.sale_starts_at or now() >= v_type.sale_ends_at then
    raise exception 'The selected ticket is not currently on sale';
  end if;
  -- Lightweight abuse control in addition to recommended edge rate limits / CAPTCHA.
  if (select count(*) from public.bookings b
      where b.created_at > now()-interval '1 hour'
      and (lower(b.buyer_email)=v_email or b.buyer_phone=v_phone)) >= 3 then
    raise exception 'Too many booking attempts; contact the lodge';
  end if;
  if v_type.capacity is not null then
    select coalesce(sum(b.quantity),0) into v_count
      from public.bookings b where b.ticket_type_id=v_type.id
        and (b.status='paid' or (b.status='pending' and b.hold_expires_at > now()));
    if v_count+p_quantity > v_type.capacity then raise exception 'Not enough tickets remain'; end if;
  end if;
  v_reference := 'MYA-' || upper(encode(gen_random_bytes(6),'hex'));
  v_expires := now()+interval '2 hours';
  insert into public.bookings (reference,event_id,ticket_type_id,buyer_name,buyer_email,buyer_phone,quantity,unit_price_cents,total_cents,hold_expires_at)
  values (v_reference,v_event.id,v_type.id,v_name,v_email,v_phone,p_quantity,v_type.price_cents,v_type.price_cents*p_quantity,v_expires)
  returning id into v_id;
  return query select v_id,v_reference,v_type.price_cents*p_quantity,v_expires;
end;
$$;

-- Manual payment confirmation: protected staff-only atomic issuance.
-- Staff MUST verify receipt in their actual bank/payment provider first.
create or replace function public.confirm_myangel_payment(p_booking_id uuid, p_payment_reference text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype; v_num integer;
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  if length(trim(coalesce(p_payment_reference,''))) < 3 then raise exception 'Enter the verified payment reference'; end if;
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_booking.status <> 'pending' or v_booking.hold_expires_at <= now() then raise exception 'Booking is no longer awaiting payment or its hold expired'; end if;
  update public.bookings set status='paid',payment_reference=trim(p_payment_reference),paid_at=now(),updated_at=now() where id=p_booking_id;
  for v_num in 1..v_booking.quantity loop
    insert into public.tickets (booking_id,event_id,serial)
    values (p_booking_id,v_booking.event_id,'MYT-' || upper(encode(gen_random_bytes(7),'hex')));
  end loop;
  insert into public.event_audit(action,actor_id,booking_id,description)
  values('payment_confirmed',(select auth.uid()),p_booking_id,'Verified manual payment reference recorded');
  return v_booking.quantity;
end;
$$;

create or replace function public.cancel_myangel_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_status text;
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  select status into v_status from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_status <> 'pending' then raise exception 'Only unpaid pending bookings can be cancelled'; end if;
  update public.bookings set status='cancelled',updated_at=now() where id=p_booking_id;
  insert into public.event_audit(action,actor_id,booking_id) values('booking_cancelled',(select auth.uid()),p_booking_id);
end;
$$;

-- Public QR verification only returns non-sensitive ticket info. The scan_code is a secret bearer token.
create or replace function public.lookup_myangel_ticket(p_scan_code uuid)
returns table(serial text, ticket_status text, event_title text, event_date timestamptz, venue_name text)
language sql stable security definer set search_path = '' as $$
  select t.serial,t.status,e.title,e.starts_at,e.venue_name
  from public.tickets t join public.events e on e.id=t.event_id
  where t.scan_code=p_scan_code limit 1;
$$;

-- Gate entry is idempotently protected with a row lock; duplicate scans are refused.
create or replace function public.scan_myangel_ticket(p_scan_code uuid)
returns table(result text, ticket_serial text, event_title text)
language plpgsql security definer set search_path = '' as $$
declare v_ticket public.tickets%rowtype; v_title text;
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  select * into v_ticket from public.tickets where scan_code=p_scan_code for update;
  if not found then return query select 'not_found'::text,null::text,null::text; return; end if;
  select e.title into v_title from public.events e where e.id=v_ticket.event_id;
  if v_ticket.status <> 'valid' then
    return query select v_ticket.status,v_ticket.serial,v_title; return;
  end if;
  update public.tickets set status='used',used_at=now(),used_by=(select auth.uid()) where id=v_ticket.id;
  insert into public.event_audit(action,actor_id,booking_id,description)
  values('ticket_scanned',(select auth.uid()),v_ticket.booking_id,v_ticket.serial);
  return query select 'accepted'::text,v_ticket.serial,v_title;
end;
$$;

-- Attendance inventory display only, never exposes buyer names or contact details.
create or replace function public.myangel_availability(p_event_id uuid)
returns table(ticket_type_id uuid, remaining integer)
language sql stable security definer set search_path = '' as $$
  select t.id, case when t.capacity is null then null::integer else greatest(0,t.capacity - coalesce(sum(b.quantity) filter
  (where b.status='paid' or (b.status='pending' and b.hold_expires_at > now())),0)::integer) end
  from public.ticket_types t
  join public.events e on e.id=t.event_id
  left join public.bookings b on b.ticket_type_id=t.id
  where e.id=p_event_id and e.status='published' group by t.id,t.capacity;
$$;

revoke all on function public.create_myangel_booking(uuid,text,text,text,integer,text) from public;
revoke all on function public.confirm_myangel_payment(uuid,text) from public;
revoke all on function public.cancel_myangel_booking(uuid) from public;
revoke all on function public.scan_myangel_ticket(uuid) from public;
revoke all on function public.lookup_myangel_ticket(uuid) from public;
revoke all on function public.myangel_availability(uuid) from public;
grant execute on function public.create_myangel_booking(uuid,text,text,text,integer,text) to anon,authenticated;
grant execute on function public.confirm_myangel_payment(uuid,text) to authenticated;
grant execute on function public.cancel_myangel_booking(uuid) to authenticated;
grant execute on function public.scan_myangel_ticket(uuid) to authenticated;
grant execute on function public.lookup_myangel_ticket(uuid) to anon,authenticated;
grant execute on function public.myangel_availability(uuid) to anon,authenticated;
grant execute on function public.is_myangel_staff() to authenticated;

-- Real first event, matching provided posters and printed prices.
insert into public.events (slug,title,subtitle,description,category,venue_name,venue_area,starts_at,ends_at,cover_image_url,status,featured)
values ('comedy-fest','My Angel Comedy Fest','An unforgettable night of comedy',
'Five fantastic acts, one stage and an evening filled with laughter at My Angel Country Lodge.',
'Comedy','My Angel Country Lodge','Mjejane, Nkomazi, Mpumalanga','2026-12-04 18:00:00+02','2026-12-05 01:00:00+02',
'assets/gogo-square.jpg','published',true)
on conflict (slug) do nothing;

insert into public.ticket_types(event_id,code,name,description,price_cents,capacity,sale_starts_at,sale_ends_at,is_online,active,sort_order)
select e.id,x.code,x.name,x.descr,x.price,x.capacity,x.open_at::timestamptz,x.close_at::timestamptz,x.online,true,x.ord
from public.events e cross join (values
 ('october','Early Bird · October','Available during October 2026',20000,500,'2026-10-01 00:00:00+02','2026-11-01 00:00:00+02',true,1),
 ('november','General · November','Available during November 2026',25000,500,'2026-11-01 00:00:00+02','2026-12-01 00:00:00+02',true,2),
 ('gate','At the gate','Event-day door price; not sold online',30000,null,'2026-12-04 00:00:00+02','2026-12-05 01:00:00+02',false,3)
) as x(code,name,descr,price,capacity,open_at,close_at,online,ord)
where e.slug='comedy-fest'
on conflict(event_id,code) do nothing;

insert into public.event_posters(event_id,artist_slug,artist_name,portrait_url,square_url,sort_order)
select e.id,x.slug,x.name,'assets/'||x.slug||'-portrait.jpg','assets/'||x.slug||'-square.jpg',x.ord
from public.events e cross join (values
 ('mdu','Mdu Ntuli',1),('lolo','Abuti Lolo',2),('oscar','Oscar Omuhle',3),('gogo','Gogo & Slwane',4),('vusi','Vusi Mongwe',5)
) as x(slug,name,ord)
where e.slug='comedy-fest'
on conflict(event_id,artist_slug) do nothing;

-- Reuse of the same recorded payment reference across multiple bookings is blocked.
create unique index if not exists bookings_payment_reference_unique
  on public.bookings (payment_reference) where payment_reference is not null;

-- Accurate totals even once the management interface displays only the most recent 500 bookings.
create or replace function public.myangel_admin_metrics()
returns table(events_total bigint, bookings_total bigint, pending_total bigint, paid_total_cents bigint)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  return query select
    (select count(*) from public.events e where e.status='published'),
    (select count(*) from public.bookings b),
    (select count(*) from public.bookings b where b.status='pending' and b.hold_expires_at>now()),
    (select coalesce(sum(b.total_cents),0)::bigint from public.bookings b where b.status='paid');
end;
$$;
revoke all on function public.myangel_admin_metrics() from public;
grant execute on function public.myangel_admin_metrics() to authenticated;
