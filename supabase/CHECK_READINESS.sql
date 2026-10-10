-- MY ANGEL / READ-ONLY GO-LIVE DIAGNOSTICS
-- Run in Supabase SQL Editor. Does not modify data.
select 'events table' as check_name,
  case when to_regclass('public.events') is not null then 'OK' else 'MISSING - apply schema 01' end as result
union all select 'bookings table',
  case when to_regclass('public.bookings') is not null then 'OK' else 'MISSING - apply schema 01' end
union all select 'staff_users table',
  case when to_regclass('public.staff_users') is not null then 'OK' else 'MISSING - apply schema 01' end
union all select 'ticket email delivery table',
  case when to_regclass('public.myangel_ticket_email_deliveries') is not null then 'OK' else 'MISSING - apply migration 04' end
union all select 'manual booking function',
  case when to_regprocedure('public.create_myangel_booking(uuid,text,text,text,integer,text)') is not null then 'OK' else 'MISSING - apply schema 01' end
union all select 'manual payment confirmation',
  case when to_regprocedure('public.confirm_myangel_payment(uuid,text)') is not null then 'OK' else 'MISSING - apply schema 01 then 03' end
union all select 'email claim function',
  case when to_regprocedure('public.myangel_claim_ticket_email(uuid)') is not null then 'OK' else 'MISSING - apply migration 04' end
union all select 'email completion function',
  case when to_regprocedure('public.myangel_finish_ticket_email(uuid,boolean,text,text)') is not null then 'OK' else 'MISSING - apply migration 04' end
order by check_name;

-- Check staff role records WITHOUT displaying customer/booking data.
select role, count(*) as accounts from public.staff_users group by role order by role;
-- AFTER migration 04, see email delivery outcomes without exposing personal data.
-- select state, count(*) from public.myangel_ticket_email_deliveries group by state;
