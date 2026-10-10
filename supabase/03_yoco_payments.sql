-- MY ANGEL EVENTS: Yoco hosted checkout and verified webhook migration.
-- Run AFTER 01_schema_and_seed.sql. Do not run before that migration.
-- Payment and ticket issuance are exclusively decided by signed webhook events.

create table if not exists public.myangel_yoco_checkouts (
  booking_id uuid primary key references public.bookings(id) on delete restrict,
  checkout_id text unique,
  redirect_url text,
  payment_id text unique,
  state text not null default 'initiating' check (state in ('initiating','created','succeeded','failed','needs_review','refunded')),
  issue_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.myangel_yoco_webhook_events (
  event_id text primary key,
  event_type text not null,
  booking_id uuid references public.bookings(id),
  payment_id text,
  outcome text,
  received_at timestamptz not null default now()
);

alter table public.myangel_yoco_checkouts enable row level security;
alter table public.myangel_yoco_webhook_events enable row level security;
-- No public / authenticated RLS policies on these tables. Access is via service_role only.

-- Repair initial booking RPC to use PostgreSQL built-in gen_random_uuid() with a locked
-- ticket type. No dependency on pgcrypto lookup under the hardened search_path.
create or replace function public.create_myangel_booking(
  p_ticket_type_id uuid, p_buyer_name text, p_buyer_email text,
  p_buyer_phone text, p_quantity integer, p_website text default ''
) returns table(booking_id uuid, booking_reference text, amount_cents integer, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
 v_type public.ticket_types%rowtype; v_event public.events%rowtype;
 v_count bigint; v_reference text; v_id uuid;
 v_name text := trim(coalesce(p_buyer_name,''));
 v_email text := lower(trim(coalesce(p_buyer_email,'')));
 v_phone text := trim(coalesce(p_buyer_phone,'')); v_expires timestamptz;
begin
 if coalesce(p_website,'') <> '' then raise exception 'Invalid request'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>10 then raise exception 'Choose 1 to 10 tickets'; end if;
 if length(v_name)<2 or length(v_name)>100 then raise exception 'Enter a valid full name'; end if;
 if length(v_email)>254 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email'; end if;
 if length(v_phone)<9 or length(v_phone)>25 or v_phone !~ '^[+0-9 ()-]+$' then raise exception 'Enter a valid phone number'; end if;
 select * into v_type from public.ticket_types where id=p_ticket_type_id for update;
 if not found then raise exception 'Ticket type not found'; end if;
 select * into v_event from public.events where id=v_type.event_id;
 if v_event.status<>'published' or v_event.starts_at<=now() then raise exception 'This event is not on sale'; end if;
 if not v_type.active or not v_type.is_online or now()<v_type.sale_starts_at or now()>=v_type.sale_ends_at then
   raise exception 'The selected ticket is not currently on sale'; end if;
 if (select count(*) from public.bookings b where b.created_at>now()-interval '1 hour' and
   (lower(b.buyer_email)=v_email or b.buyer_phone=v_phone))>=3 then
   raise exception 'Too many booking attempts; contact the lodge'; end if;
 if v_type.capacity is not null then
   select coalesce(sum(b.quantity),0) into v_count from public.bookings b
     where b.ticket_type_id=v_type.id and
     (b.status='paid' or (b.status='pending' and b.hold_expires_at>now()));
   if v_count+p_quantity>v_type.capacity then raise exception 'Not enough tickets remain'; end if;
 end if;
 v_reference:='MYA-'||substring(upper(replace(gen_random_uuid()::text,'-','')) from 1 for 12);
 v_expires:=now()+interval '2 hours';
 insert into public.bookings(reference,event_id,ticket_type_id,buyer_name,buyer_email,buyer_phone,
   quantity,unit_price_cents,total_cents,hold_expires_at)
 values(v_reference,v_event.id,v_type.id,v_name,v_email,v_phone,p_quantity,v_type.price_cents,
   v_type.price_cents*p_quantity,v_expires) returning id into v_id;
 return query select v_id,v_reference,v_type.price_cents*p_quantity,v_expires;
end; $$;

-- Prepare a reservation for Yoco. The browser NEVER supplies the price.
create or replace function public.myangel_prepare_yoco_checkout(p_booking_id uuid)
returns table(booking_reference text, amount_cents integer, checkout_url text)
language plpgsql security definer set search_path = '' as $$
declare b public.bookings%rowtype; c public.myangel_yoco_checkouts%rowtype;
begin
  if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status <> 'pending' or b.hold_expires_at <= now() then raise exception 'Booking is no longer payable'; end if;
  if b.payment_method not in ('manual','gateway') then raise exception 'Unsupported payment method'; end if;
  update public.bookings set payment_method='gateway',updated_at=now() where id=b.id;
  insert into public.myangel_yoco_checkouts(booking_id) values(b.id)
  on conflict (booking_id) do nothing;
  select * into c from public.myangel_yoco_checkouts where booking_id=b.id;
  return query select b.reference,b.total_cents,c.redirect_url;
end; $$;

-- Attach Yoco session information after the server creates it. Same checkout reused on retry.
create or replace function public.myangel_attach_yoco_checkout(p_booking_id uuid,p_checkout_id text,p_redirect_url text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings%rowtype; c public.myangel_yoco_checkouts%rowtype;
begin
  if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
  if p_checkout_id is null or length(p_checkout_id)<5 or p_redirect_url !~ '^https://[a-zA-Z0-9.-]+/' then raise exception 'Invalid checkout session'; end if;
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.payment_method <> 'gateway' then raise exception 'Not an online payment'; end if;
  select * into c from public.myangel_yoco_checkouts where booking_id=b.id for update;
  if not found then raise exception 'Checkout record not found'; end if;
  if c.checkout_id is not null and c.checkout_id <> p_checkout_id then raise exception 'Checkout already linked'; end if;
  update public.myangel_yoco_checkouts set checkout_id=p_checkout_id,redirect_url=p_redirect_url,
    state=case when state='initiating' then 'created' else state end,updated_at=now() where booking_id=b.id;
end; $$;

-- Atomic, idempotent callback processor. Call ONLY from the Edge Function after verifying Yoco's HMAC.
-- Validation includes metadata reference, exact amount and currency, and a live inventory hold.
-- Expired payments are flagged for refund/manual review; NEVER issue oversold tickets.
create or replace function public.myangel_apply_yoco_webhook(
  p_event_id text,p_event_type text,p_booking_id uuid,p_booking_reference text,
  p_payment_id text,p_amount_cents integer,p_currency text)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings%rowtype; v_event public.myangel_yoco_webhook_events%rowtype;
declare v_outcome text := 'ignored'; v_num int; c public.myangel_yoco_checkouts%rowtype;
begin
  if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
  if p_event_id is null or length(p_event_id)<5 or p_payment_id is null or length(p_payment_id)<3 then raise exception 'Missing event identification'; end if;
  -- Lock the order before recording the webhook, so concurrent events serialize.
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Unknown booking'; end if;
  if b.reference <> p_booking_reference or b.payment_method <> 'gateway' then raise exception 'Booking mismatch'; end if;
  insert into public.myangel_yoco_webhook_events(event_id,event_type,booking_id,payment_id,outcome)
  values(p_event_id,p_event_type,b.id,p_payment_id,'processing') on conflict(event_id) do nothing;
  if not found then return 'duplicate'; end if;
  select * into c from public.myangel_yoco_checkouts where booking_id=b.id for update;
  if not found then raise exception 'Unknown checkout'; end if;
  if p_event_type='payment.succeeded' then
    if c.state='refunded' then
      v_outcome:='already_refunded';
    elsif p_amount_cents <> b.total_cents or p_currency <> 'ZAR' then
      v_outcome:='amount_mismatch';
    elsif b.status='paid' then
      v_outcome:=case when b.payment_reference=p_payment_id then 'duplicate_payment' else 'extra_payment_review' end;
    elsif b.status <> 'pending' or b.hold_expires_at <= now() then
      v_outcome:='expired_payment_review';
    else
      update public.bookings set status='paid',payment_reference=p_payment_id,paid_at=now(),updated_at=now()
        where id=b.id;
      for v_num in 1..b.quantity loop
        insert into public.tickets(booking_id,event_id,serial)
          values(b.id,b.event_id,'MYT-'||substring(upper(replace(gen_random_uuid()::text,'-','')) from 1 for 14));
      end loop;
      insert into public.event_audit(action,booking_id,description)
        values('yoco_paid',b.id,'Yoco signed payment succeeded: '||p_payment_id);
      v_outcome:='issued';
    end if;
    update public.myangel_yoco_checkouts set
      state=case when v_outcome in ('issued','duplicate_payment') then 'succeeded' when v_outcome='already_refunded' then 'refunded' else 'needs_review' end,
      issue_message=case when v_outcome='issued' then null else v_outcome end,
      payment_id=coalesce(payment_id,p_payment_id),updated_at=now()
      where booking_id=b.id;
  elsif p_event_type='payment.failed' then
    -- A failed attempt does not release the reservation: buyer may retry until hold expires.
    if b.status='pending' then
      update public.myangel_yoco_checkouts set state='failed',updated_at=now()
        where booking_id=b.id and state not in ('succeeded','needs_review');
    end if;
    v_outcome:='payment_failed';
  else
    v_outcome:='unhandled_event';
  end if;
  update public.myangel_yoco_webhook_events set outcome=v_outcome where event_id=p_event_id;
  return v_outcome;
end; $$;

-- Yoco refund notifications identify the checkout ID in the signed metadata.
-- A verified FULL refund automatically voids unused tickets; partial refunds need staff review.
create or replace function public.myangel_apply_yoco_refund(
 p_event_id text,p_event_type text,p_checkout_id text,p_refund_id text,
 p_amount_cents integer,p_currency text)
returns text language plpgsql security definer set search_path = '' as $$
declare b public.bookings%rowtype; c public.myangel_yoco_checkouts%rowtype;
declare v_outcome text := 'refund_ignored';
begin
 if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
 if length(coalesce(p_event_id,''))<5 or length(coalesce(p_refund_id,''))<3 or length(coalesce(p_checkout_id,''))<5
   then raise exception 'Invalid refund notification'; end if;
 select * into c from public.myangel_yoco_checkouts where checkout_id=p_checkout_id;
 if not found then raise exception 'Unknown checkout refund'; end if;
 select * into b from public.bookings where id=c.booking_id for update;
 if not found then raise exception 'Unknown booking refund'; end if;
 insert into public.myangel_yoco_webhook_events(event_id,event_type,booking_id,payment_id,outcome)
 values(p_event_id,p_event_type,b.id,p_refund_id,'processing') on conflict(event_id) do nothing;
 if not found then return 'duplicate'; end if;
 if p_event_type='refund.succeeded' then
   if p_currency<>'ZAR' or p_amount_cents<=0 or p_amount_cents>b.total_cents then
     v_outcome:='invalid_refund_review';
   elsif p_amount_cents=b.total_cents and b.status='paid' then
     update public.bookings set status='refunded',updated_at=now() where id=b.id;
     update public.tickets set status='void' where booking_id=b.id and status='valid';
     update public.myangel_yoco_checkouts set state='refunded',updated_at=now(),issue_message='Fully refunded' where booking_id=b.id;
     insert into public.event_audit(action,booking_id,description) values('yoco_refunded',b.id,'Yoco full refund confirmed: '||p_refund_id);
     v_outcome:='fully_refunded';
   else
     v_outcome:='partial_or_unmatched_refund_review';
   end if;
   if v_outcome not in ('fully_refunded') then
     update public.myangel_yoco_checkouts set state='needs_review',issue_message=v_outcome,updated_at=now() where booking_id=b.id;
   end if;
 elsif p_event_type='refund.failed' then
   v_outcome:='refund_failed_review';
   update public.myangel_yoco_checkouts set state='needs_review',issue_message=v_outcome,updated_at=now() where booking_id=b.id;
 end if;
 update public.myangel_yoco_webhook_events set outcome=v_outcome where event_id=p_event_id;
 return v_outcome;
end; $$;

-- A UUID booking id + separate printed reference are a capability pair.
-- Only expose nonsensitive order state and, after payment, its own bearer ticket codes.
create or replace function public.myangel_receipt_status(p_booking_id uuid,p_booking_reference text)
returns table(booking_reference text,booking_status text,payment_method text,ticket_codes uuid[],hold_expires_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select b.reference,
    case when b.status='pending' and b.hold_expires_at <= now() then 'expired' else b.status end,
    b.payment_method,
    case when b.status='paid' then
      array(select t.scan_code from public.tickets t where t.booking_id=b.id order by t.issued_at,t.id)
    else array[]::uuid[] end,
    b.hold_expires_at
  from public.bookings b where b.id=p_booking_id and b.reference=p_booking_reference;
end; $$;

-- Staff-only payment reconciliation summary (no direct RLS read of gateway secrets).
create or replace function public.myangel_staff_yoco_status(p_booking_id uuid)
returns table(checkout_state text,issue_message text,checkout_id text,payment_id text)
language plpgsql stable security definer set search_path = '' as $$
begin
 if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
 return query select c.state,c.issue_message,c.checkout_id,c.payment_id
 from public.myangel_yoco_checkouts c where c.booking_id=p_booking_id;
end; $$;

-- Prevent manual staff payment confirmation for bookings assigned to Yoco.
create or replace function public.confirm_myangel_payment(p_booking_id uuid, p_payment_reference text)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype; v_num integer;
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  if length(trim(coalesce(p_payment_reference,''))) < 3 then raise exception 'Enter the verified payment reference'; end if;
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_booking.payment_method <> 'manual' then raise exception 'Online Yoco payments can only be verified by the signed Yoco webhook'; end if;
  if v_booking.status <> 'pending' or v_booking.hold_expires_at <= now() then raise exception 'Booking not awaiting valid payment'; end if;
  update public.bookings set status='paid',payment_reference=trim(p_payment_reference),paid_at=now(),updated_at=now() where id=p_booking_id;
  for v_num in 1..v_booking.quantity loop
    insert into public.tickets (booking_id,event_id,serial)
    values (p_booking_id,v_booking.event_id,'MYT-' || substring(upper(replace(gen_random_uuid()::text,'-','')) from 1 for 14));
  end loop;
  insert into public.event_audit(action,actor_id,booking_id,description)
  values('payment_confirmed',(select auth.uid()),p_booking_id,'Verified manual payment reference recorded');
  return v_booking.quantity;
end; $$;

-- Gateway booking can be cancelled only by staff if checkout was never initiated.
-- Yoco can still charge in-flight sessions, so avoid silent cancellation.
create or replace function public.cancel_myangel_booking(p_booking_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_status text; v_method text;
begin
  if not public.is_myangel_staff() then raise exception 'Not authorised'; end if;
  select status,payment_method into v_status,v_method from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if v_status <> 'pending' or v_method <> 'manual' then
    raise exception 'Yoco bookings cannot be cancelled manually while a checkout may still be open'; end if;
  update public.bookings set status='cancelled',updated_at=now() where id=p_booking_id;
  insert into public.event_audit(action,actor_id,booking_id) values('booking_cancelled',(select auth.uid()),p_booking_id);
end; $$;

revoke all on table public.myangel_yoco_checkouts from anon,authenticated;
revoke all on table public.myangel_yoco_webhook_events from anon,authenticated;
revoke all on function public.myangel_prepare_yoco_checkout(uuid) from public,anon,authenticated;
revoke all on function public.myangel_attach_yoco_checkout(uuid,text,text) from public,anon,authenticated;
revoke all on function public.myangel_apply_yoco_webhook(text,text,uuid,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.myangel_apply_yoco_refund(text,text,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.myangel_receipt_status(uuid,text) from public;
revoke all on function public.myangel_staff_yoco_status(uuid) from public;
grant execute on function public.myangel_prepare_yoco_checkout(uuid) to service_role;
grant execute on function public.myangel_attach_yoco_checkout(uuid,text,text) to service_role;
grant execute on function public.myangel_apply_yoco_webhook(text,text,uuid,text,text,integer,text) to service_role;
grant execute on function public.myangel_apply_yoco_refund(text,text,text,text,integer,text) to service_role;
grant execute on function public.myangel_receipt_status(uuid,text) to anon,authenticated;
grant execute on function public.myangel_staff_yoco_status(uuid) to authenticated;
notify pgrst, 'reload schema';
