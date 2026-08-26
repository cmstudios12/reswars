RES WARS FULL ATTACK PACKAGE

UPLOAD/REPLACE:
- index.html
- game.html
- spin.html
- profile.html

DATABASE:
If you already ran the earlier SQL files, run ONLY final-gameplay-integration.sql.
For a fresh/current database upgrade, reswars-upgrade-all.sql contains the combined upgrade chain.

CURRENT FLOW:
Index -> live chat/presence -> invite -> shared session -> ready lobby -> 5 second synchronized countdown -> live game -> finish -> secure result claim -> XP/wins/games played -> achievements/team totals -> profile.

IMPORTANT:
Do not use battle.html anymore. Universal games use game.html.

PWA / ADD TO HOME SCREEN
- Upload manifest.json, sw.js and the icons/ folder to the SAME folder as index.html.
- Upload the updated index.html, game.html, spin.html and profile.html too.
- Site MUST be served over HTTPS (localhost is also allowed for development).
- Android/Chromium gets the native install prompt.
- iPhone/iPad gets instructions to Share > Add to Home Screen.
- Installed mode uses standalone display and safe-area handling.
- Service worker cache is reswars-app-v8; battle.html is NOT cached anymore.
