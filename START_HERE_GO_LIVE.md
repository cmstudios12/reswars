# MY ANGEL EVENTS — START HERE (real PDF email, Yoco off)

This folder contains the complete website and the function used to email PDF admission tickets, configured for Supabase project `bhzemfnslqjjtasajawb`.

**Not live until you complete the steps below.** Do not share Resend API keys or the Supabase service-role key with anyone, including a public website or a chat.

## 1. Confirm database readiness (5 minutes)

Open https://supabase.com/dashboard/project/bhzemfnslqjjtasajawb/sql/new and paste `supabase/CHECK_READINESS.sql`. Run it.

If `email delivery table`, `email claim function`, or `email completion function` are MISSING, run **only** `supabase/04_manual_pdf_email.sql` in a new query, then rerun the check. If schema 01 / 03 are missing, do not blindly rerun on a project with existing data; inspect the current schema or get assistance first.

Check at least one staff account exists. If none, create your Supabase Auth user and follow `02_grant_first_admin.sql` to assign admin access.

## 2. Verify your Resend sender (5–30+ minutes, depends on DNS)

Open https://resend.com/domains and add/verify a domain you control (e.g. a dedicated `mail.` subdomain). Copy Resend's supplied DNS records into the **domain DNS management panel**, wait until status is VERIFIED. Create a Resend API key on https://resend.com/api-keys. Keep it private.

Note: Resend may accept a request before delivery. Check real inbox as well as Resend email logs.

## 3. Publish the website (5–15 minutes, requires hosting)

Upload these files from the package to your HTTPS website host: `index.html`, `app.js`, `styles.css`, `config.js`, `admin.html`, `admin.js`, `admin.css`, `ticket.html`, `ticket.js`, `payment.html`, `payment.js`, and the entire `assets/` folder.

Important: put the files in the **same directory** and make sure your real domain loads `index.html`, `admin.html`, `ticket.html` and `assets/myangel-logo.png`. Do NOT upload SQL files, test PDFs, function source or API keys to the public website.

## 4. Deploy email function (on Windows; 5–10 minutes)

Install the official Node.js LTS if you do not have it. Open PowerShell in this folder, and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\DEPLOY_EMAIL_WINDOWS.ps1
```

The script prompts for your **HTTPS website URL**, the **verified FROM email**, and the **private Resend API key** locally; logs you into Supabase; stores secrets in Supabase; deploys only `email-verified-tickets`; and removes the temporary secret file.

Supabase functions dashboard: https://supabase.com/dashboard/project/bhzemfnslqjjtasajawb/functions
Secrets dashboard: https://supabase.com/dashboard/project/bhzemfnslqjjtasajawb/settings/functions

For a manual dashboard alternative, add exactly these secrets: `RESEND_API_KEY`, `RESEND_FROM` (example `My Angel Tickets <tickets@yourdomain.co.za>`), and `SITE_URL` (must be the complete public site root, e.g. `https://example.co.za/events/`). Then deploy `supabase/functions/email-verified-tickets/index.ts` as Edge Function `email-verified-tickets` and turn JWT gateway verification **off**. The code independently enforces Supabase user JWT + staff status, so keep that protection unchanged.

## 5. Do an actual end-to-end email test (10 minutes)

For meeting demonstration, use a **separate staging project or a dedicated non-customer test event**. Do NOT mark an unpaid guest as paid for the genuine Comedy Fest. The system will create valid gate passes when staff confirm.

1. Open published site `index.html`; create a booking using an inbox you can inspect. Choose a ticket category currently on sale and save the unique `MYA-...` reference.
2. Open `admin.html` and sign in with a recognised staff Auth account.
3. Before touching any booking, click **Send demo PDF to my email** in Bookings. Check your inbox for the PDF marked **SAMPLE - NOT VALID**. This tests the real sender safely without issuing a ticket.
4. Find booking in Bookings tab. For a genuine booking confirm money has arrived; for a staging booking clearly label the test. Click **Confirm payment, issue & email PDF tickets**.
5. Check the message in Admin: email status should be **sent**. Then check both inbox and spam, open the PDF, and use `admin.html` scanning to validate the QR. Scanning a second time must refuse entry.
6. If email fails, open Edge Functions → `email-verified-tickets` → Logs and inspect `Resend` error. Press **Send / retry professional PDF ticket email** in Admin after correcting it.

**Yoco is disabled in this front-end package.** Do NOT deploy any Yoco functions while testing manual payment. The presence of old gateway SQL alone does not initiate a charge.

## Owner meeting talking points

- All My Angel events in a single premium website; posters swipe on mobile.
- Staff manage events, ticket categories, customers and entries themselves.
- Guest tickets are issued ONLY when staff confirm; every QR admits one person.
- Real PDF tickets arrive through My Angel-branded email after deployment and domain verification.
- Yoco can be enabled separately after payment testing and approval.

## Known limitations

- Confirmation invokes email from the signed-in admin browser; if staff close the page immediately after clicking confirm, the tickets may be issued but email may not send. The admin's Retry button completes delivery.
- `Sent` means Resend accepted the email request. Delivery to a particular inbox must be tested; bounces and spam filtering are possible.
- A fake test confirmation in your production database issues real scannable tickets. Use staging for simulated payments.
- Pending bookings have a 2-hour reservation hold; choose a currently on-sale tier.
- QR camera scanning depends on browser support; pasted QR ticket links remain available as a fallback.
