# MY ANGEL EVENTS — MANUAL PAYMENT + EMAIL PDF TICKETS

This package replaces Yoco checkout **on the website** with a staff-confirmed payment workflow. It uses the same My Angel Supabase project and booking/ticket tables. It includes a responsive cream-and-orange homepage, updated admin dashboard, reservation status page, official logo, and a landscape PDF design closely following your uploaded sample.

## What happens

1. Guest selects an event/ticket quantity, enters name, email and phone, and clicks **Reserve my tickets**.
2. Supabase creates a **pending/manual** reservation and displays the unique `MYA-...` reference. No live QR is issued.
3. Guest contacts My Angel on WhatsApp for your official payment instructions.
4. Staff opens **admin.html**, confirms the amount actually arrived and enters a transaction reference. The protected `confirm_myangel_payment` RPC marks the booking paid and issues the correct number of individual `MYT-...` QR codes.
5. The admin page automatically calls `email-verified-tickets`, which verifies the staff session and paid booking again on the server, creates a professional one-page-per-guest landscape PDF and sends one branded email with the PDF as an attachment via Resend.
6. Admin sees **sent/failed** status. If email failed, click **Send / retry professional PDF ticket email** (without repeating payment confirmation).
7. The QR links also work on `ticket.html` and only authorised staff can accept tickets at the gate once. Invalid, void, or previously scanned tickets are rejected.

**The downloadable SAMPLE_My_Angel_Ticket.pdf is design-only**. It says NOT VALID and its QR is not a real pass. Real, unique QR codes are generated ONLY after a staff-confirmed payment in Supabase.

## Important: install to your existing Supabase project

Project: `bhzemfnslqjjtasajawb`.

If you have already applied schema 01 and Yoco migration 03, **do not rerun them**. Run the new script:

`supabase/04_manual_pdf_email.sql` (Supabase Dashboard → SQL Editor).

If this is a completely fresh database, apply `01_schema_and_seed.sql`, then `03_yoco_payments.sql` (this also creates the booking-status RPC used by the site), then `04_manual_pdf_email.sql`. Migration 03 contains old Yoco backend objects but **the new frontend never initiates a Yoco session**. You don't need to deploy its Yoco functions to test manual payments. If not already configured, complete `02_grant_first_admin.sql` by following its instructions (it authorises your own Supabase Auth account).

### Deploy the new Edge Function

From the project directory, using Supabase CLI:

```sh
supabase login
supabase link --project-ref bhzemfnslqjjtasajawb
supabase functions deploy email-verified-tickets --no-verify-jwt
```

The function itself validates the guest-independent *staff JWT* using Supabase Auth and checks `staff_users`. `--no-verify-jwt` allows publishable-key projects at the gateway; it does **not** make the function publicly usable.

### Email service

Sign up for Resend, verify a domain/subdomain owned by My Angel and configure its DNS records. Choose a sender such as `My Angel Tickets <tickets@yourverifieddomain.co.za>`. Keep all secrets server-side:

```sh
supabase secrets set RESEND_API_KEY='re_...' \
  RESEND_FROM='My Angel Tickets <tickets@yourverifieddomain.co.za>' \
  SITE_URL='https://your-live-myangel-site.co.za/'
```

`SITE_URL` **must be the actual public website URL**, ending with `/` (include `/events/` if deployed inside a folder). The live PDF QR codes use it to point to `ticket.html?code=...`. The Edge Function also needs Supabase's built-in `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` server secrets. Do not put any secret in `config.js`, `index.html`, the ZIP before uploading to hosting, or a chat message.

### Deploy website files

Upload `index.html`, `app.js`, `admin.html`, `admin.js`, `payment.html`, `payment.js`, `ticket.html`, `ticket.js`, `config.js`, `styles.css`, `admin.css`, and **the entire assets folder** to the same web root. All original artist posters are included. You should replace corresponding live files, not upload the PDF sample to your public web root.

## Test safely

1. Make sure ticket sales are open for the test event and your staff login works.
2. Create a NEW reservation using your own email; previously created gateway/Yoco bookings remain gateway-tagged and cannot be manually approved (this prevents bypassing a payment that may already be in flight).
3. In admin → Bookings, search for the new reference. If you want to test with nonreal money, use a **dedicated private/staging event**; do not mark a real customer as paid without receiving money.
4. Confirm payment before the reservation's 2-hour hold expires. Enter the real verified bank/cash register reference (or a clear staging reference in your non-public test environment).
5. Check the inbox + spam folder. Open attached PDF and scan it in the staff gate scanner; the first gate scan should accept, the second should reject as already used.
6. If the email fails, open Supabase Dashboard → Edge Functions → `email-verified-tickets` → Logs; ensure sender domain is verified, Resend API key is valid, `SITE_URL` is correct, and the PNG/poster assets are hosted publicly. Retry via admin.
7. When ready for live use, keep manual payments or re-enable Yoco separately. **This package does not configure or test real card payments.**

## Safeguards and limitations

- Guests cannot mark themselves paid. The server only emails when the booking status is `paid`, the method is `manual`, all issued tickets are valid, and the authenticated sender belongs to `staff_users`.
- The email delivery log prevents normal double sends and uses a Resend idempotency key for retry requests. A payment confirmation and email delivery are different operations: if email fails, ticket issuance stays paid and staff must retry email.
- The QR code is a private bearer token. Don't publish QR codes or send them to third parties. No ID/age policy was specified in the source poster: the ticket says **Confirm with the lodge** until you configure the event's `age_restriction` field.
- PDF email deliverability and actual customer receipt cannot be confirmed until you connect Resend and deploy the server function. Nothing here has been deployed to your live Supabase project.
- Booking inventory holds are 2 hours under the existing database rules. Booking/capacity limits are applied by Supabase RPCs, not by HTML.
- The PDF sample intentionally uses a **sample guest identity** and an invalid QR and is **not** proof of purchase.
