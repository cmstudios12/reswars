# My Angel Country Lodge -- secure, guided Windows email deployment.
# Run after 04_manual_pdf_email.sql has successfully executed in your Supabase SQL Editor.
# The Yoco checkout function is NOT deployed here.
$ErrorActionPreference = 'Stop'
$project = 'bhzemfnslqjjtasajawb'
function Fail($message) { Write-Host "`nERROR: $message" -ForegroundColor Red; exit 1 }
Write-Host "`nMY ANGEL EVENTS | EMAIL + PDF GO-LIVE" -ForegroundColor DarkYellow
Write-Host "Supabase project: $project"
Write-Host 'This deploys only the PDF ticket email function. Yoco remains unused.'
Write-Host 'IMPORTANT: run supabase/04_manual_pdf_email.sql in SQL Editor first.'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'Node.js not found. Install Node.js LTS first.' }
if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { Fail 'npx not found. Install Node.js LTS first.' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $here
$url = (Read-Host 'Enter LIVE website URL including https:// and final folder if any').Trim().TrimEnd('/') + '/'
try { $uri = [Uri]$url } catch { Fail 'Invalid website URL.' }
if ($uri.Scheme -ne 'https' -or -not $uri.Host.Contains('.')) { Fail 'Website URL must be public HTTPS (not localhost).' }
$sender = (Read-Host 'Enter VERIFIED FROM email address, e.g. tickets@your-domain.co.za').Trim()
if ($sender -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { Fail 'Please use a valid sender email address.' }
$from = 'My Angel Tickets <' + $sender + '>'
Write-Host 'Make sure the sender domain is VERIFIED inside Resend, or emails will fail.' -ForegroundColor Yellow
$secureKey = Read-Host 'Paste your Resend API key here (hidden input; never send it in chat)' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ($key -notmatch '^re_') { Fail 'Resend API keys typically begin re_. Check your copied API key.' }
$temp = Join-Path $env:TEMP ([IO.Path]::GetRandomFileName() + '.env')
try {
  # Quoted sender preserves friendly name and angle brackets.
  $lines = @('RESEND_API_KEY=' + $key, 'RESEND_FROM="' + $from + '"', 'SITE_URL=' + $url)
  [IO.File]::WriteAllText($temp, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
  $key = $null
  Write-Host "`n1/3 Signing in to Supabase in your own terminal..." -ForegroundColor Cyan
  & npx --yes supabase login
  if ($LASTEXITCODE -ne 0) { Fail 'Supabase login failed.' }
  Write-Host '2/3 Saving email secrets to your Supabase project...' -ForegroundColor Cyan
  & npx --yes supabase secrets set --env-file "$temp" --project-ref "$project"
  if ($LASTEXITCODE -ne 0) { Fail 'Secrets were not set. Check Supabase project permissions.' }
  Write-Host '3/3 Deploying the email function (and NOT Yoco)...' -ForegroundColor Cyan
  & npx --yes supabase functions deploy email-verified-tickets --project-ref "$project" --no-verify-jwt
  if ($LASTEXITCODE -ne 0) { Fail 'Edge Function deployment failed. Check output.' }
  Write-Host "`nSUCCESS: email-verified-tickets was deployed." -ForegroundColor Green
  Write-Host 'Next: host/upload the website files; sign in to admin; create a staging booking; confirm staging test payment; check inbox.'
  Write-Host 'NOTE: this confirms deployment only, not email delivery. A real inbox test is mandatory.'
} finally {
  if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Force }
  $key = $null
}
