# Glance demo runbook (~2.5 min)

Persona: **Aoife**, a first-year student buying her first laptop and learning new software. Budget EUR 1,200.
Files: `demo/budget-note.txt` (the note), `demo/mock-bank.html` (fictional bank, fake data only).

## Pages to use (checked 2026-10-03)

| # | Page | URL | Check |
|---|------|-----|-------|
| 1 | Lenovo ThinkPad X1 family | https://www.lenovo.com/ie/en/c/laptops/thinkpad/thinkpadx1/ | 200 |
| 2 | ASUS Zenbook range | https://www.asus.com/ie/laptops/for-home/zenbook/ | 200 |
| 3 | Apple MacBook Air specs | https://www.apple.com/ie/macbook-air/specs/ | 200 |

Fallbacks (200): https://www.apple.com/ie/macbook-air/ and https://www.apple.com/ie/macbook-pro/specs/.
Dell XPS and Microsoft Surface pages returned 403 to curl (bot blocking); they may load in Safari but are unverified, so avoid them.
Do not use the Lenovo `.../thinkpad-x1-carbon-gen-13-.../len101t0100` link: it redirects to an unrelated L13 page.

**Confusing spec (page 3):** on the Apple specs page, point at "Unified memory" (or "Neural Engine"). Aoife's note says "16GB RAM", so the answer should connect unified memory to that need. Open the page before the demo and confirm that line is visible; scroll position matters on camera.

## Script

**1. Problem (0:00-0:15)**
"Every AI makes you explain everything again. And unfamiliar apps are confusing."

**2. Shopping (0:15-1:15)**
1. Safari: open page 1, scroll 5 s. Open page 2 in a new tab, scroll 5 s.
2. Open Notes, paste `demo/budget-note.txt` (select all in the file, copy, paste). Say: "I'm keeping my budget here."
3. Open page 3. Hold the hotkey and say: "How's this different from the earlier ones?" Expected: a spoken answer using all three laptops and the EUR 1,200 / 16GB budget.
4. Point the cursor at "Unified memory". Hold the hotkey: "What does this mean for me?"

**3. Learning (1:15-2:00)**
"Now I need to hand in my assignment as a PDF." Hold the hotkey: "Show me how to export this as a PDF."
Guide app: **Pages** is installed (`/Applications/Pages Creator Studio.app`; Keynote and Numbers too). Have a short document open in Pages. Highlights should walk: **File menu, Export To, PDF..., Next, Save**. (Pages menu labels are from memory; open it once beforehand and correct this line.)
Reliable fallback: **TextEdit** (`/System/Applications/TextEdit.app`): File, Export as PDF..., choose a name, Save.
Optional (if v2 is built): click the wrong menu on purpose and let Glance correct her.

**4. Privacy (2:00-2:20)**
Run `open demo/mock-bank.html` (opens in the default browser; the page has a red DEMO banner). Hold the hotkey: "Can you read this page?"
Expect: the preview shows the card, IBAN, PPSN, email and password field blacked out, and Glance says "I hid that." Then switch on local-only mode and say/trigger "forget last 15 minutes".

**5. Close (2:20-2:30)**
"Screenpipe remembers your screen. Glance helps you act on it, privately."

## Pre-demo reset checklist
- [ ] Clear the timeline / memory in Glance (forget everything), confirm it is empty.
- [ ] Quit Safari windows and tabs; reopen only pages 1-3 in order (page 3 scrolled to the spec) plus a blank Notes note.
- [ ] Delete old exported PDFs from the Desktop so the export is clean; have the Pages/TextEdit document open.
- [ ] Turn on Do Not Disturb (Control Centre, Focus).
- [ ] Quit unneeded apps (Mail, Messages, Slack, Chrome, etc.); hide Dock and extra menu-bar items if cluttered.
- [ ] Local-only mode OFF at the start so the toggle is visible.
- [ ] Mic and screen-recording permissions granted; test the hotkey once; volume up.
- [ ] Close the mock bank page until beat 4.
