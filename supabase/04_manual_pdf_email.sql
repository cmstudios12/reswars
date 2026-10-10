-- MY ANGEL EVENTS / Migration 04: staff-confirmed payment + email PDF tracking.
-- Apply AFTER migrations 01 and 03. Does NOT remove past Yoco records or paid tickets.
-- Yoco API remains installed but is not called from this manual checkout website.

alter table public.events
  add column if not exists age_restriction text not null default 'Confirm with the lodge';

create table if not exists public.myangel_ticket_email_deliveries (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  state text not null default 'pending' check (state in ('pending','sending','sent','failed')),
  attempts integer not null default 0,
  started_at timestamptz,
  sent_at timestamptz,
  provider_email_id text,
  last_error text,
  updated_at timestamptz not null default now()
);

alter table public.myangel_ticket_email_deliveries enable row level security;
drop policy if exists "Lodge staff can view email delivery" on public.myangel_ticket_email_deliveries;
create policy "Lodge staff can view email delivery" on public.myangel_ticket_email_deliveries
 for select to authenticated using ((select public.is_myangel_staff()));

-- Only server-side Edge Functions may claim/release email deliveries.
create or replace function public.myangel_claim_ticket_email(p_booking_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_booking public.bookings%rowtype;
        v_email public.myangel_ticket_email_deliveries%rowtype;
begin
 if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
 select * into v_booking from public.bookings where id=p_booking_id for update;
 if not found then raise exception 'Booking not found'; end if;
 if v_booking.status <> 'paid' then raise exception 'Tickets cannot be emailed before payment is confirmed'; end if;
 if v_booking.payment_method <> 'manual' then raise exception 'This email method is reserved for manually paid bookings'; end if;
 if (select count(*) from public.tickets where booking_id=p_booking_id and status='valid') <> v_booking.quantity then
    raise exception 'Ticket count or validity mismatch. Contact admin before sending.';
 end if;
 insert into public.myangel_ticket_email_deliveries(booking_id) values(p_booking_id)
 on conflict (booking_id) do nothing;
 select * into v_email from public.myangel_ticket_email_deliveries where booking_id=p_booking_id for update;
 if v_email.state='sent' then return 'already_sent'; end if;
 if v_email.state='sending' and v_email.started_at > now()-interval '5 minutes' then return 'in_progress'; end if;
 update public.myangel_ticket_email_deliveries set state='sending', started_at=now(),updated_at=now(),
  attempts=attempts+1,last_error=null where booking_id=p_booking_id;
 return 'claimed';
end; $$;

create or replace function public.myangel_finish_ticket_email(p_booking_id uuid,p_ok boolean,p_provider_id text default null,p_error text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if (select auth.role()) <> 'service_role' then raise exception 'Not authorised'; end if;
 update public.myangel_ticket_email_deliveries
   set state=case when p_ok then 'sent' else 'failed' end,
       sent_at=case when p_ok then now() else sent_at end,
       provider_email_id=case when p_ok then p_provider_id else provider_email_id end,
       last_error=case when p_ok then null else left(coalesce(p_error,'Email send failed'),500) end,
       updated_at=now()
 where booking_id=p_booking_id and state='sending';
 if not found then raise exception 'Email delivery was not claimed'; end if;
end; $$;

revoke all on table public.myangel_ticket_email_deliveries from anon,authenticated;
grant select on table public.myangel_ticket_email_deliveries to authenticated;
revoke all on function public.myangel_claim_ticket_email(uuid) from public,anon,authenticated;
revoke all on function public.myangel_finish_ticket_email(uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.myangel_claim_ticket_email(uuid) to service_role;
grant execute on function public.myangel_finish_ticket_email(uuid,boolean,text,text) to service_role;
notify pgrst, 'reload schema';
