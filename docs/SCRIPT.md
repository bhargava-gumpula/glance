# Glance: Dublin HacX presentation script

Everything here exists on `main` (e770a5c). Judges score what was built today, so say only what the screen shows. If a beat fails, use its fallback (section 8) and keep the story going.

**Pages** (from docs/DEMO.md):
1. ThinkPad X1: https://www.lenovo.com/ie/en/c/laptops/thinkpad/thinkpadx1/
2. MacBook Pro specs: https://www.apple.com/ie/macbook-pro/specs/
3. MacBook Air specs: https://www.apple.com/ie/macbook-air/specs/ (scroll so "Unified memory" is visible)

**Notes:** the text of `demo/budget-note.txt` (Budget: €1,200 max · 16GB RAM · light · good battery).
**Pages doc:** a short "Assignment" document, open and frontmost when beat 4 starts.
**Bank:** `demo/mock-bank.html` (red DEMO banner, fake data only).

**Controls that exist:**
- Tap ⌥Space: Pip appears with a one-line field and a Point button.
- Hold ⌥Space: talk.
- **Show more** on Pip's bubble opens the chat; **Hide chat** closes it.
- The menu-bar penguin has **Forget Last 10 Minutes**, **Pause Memory** and **Local Only**.

**The model is slow (about 20 s to the first word on grok via Azure).** Every question below has a filler line written in. Never stand in silence.

---

## 0. Introduction (about 60 s, before the demo)

"Hi, we're [team names], and this is Glance.

Think about the last time you asked an AI for help with something on your computer. You took a screenshot. You copied and pasted. You explained what you were looking at, what you'd already tried, and what you were trying to do. And then it answered with a wall of text, and you still had to figure out where to click.

Your computer already knows all of that. It's right there on your screen. The AI just can't see it.

**Glance is an AI companion for your Mac that understands what you're doing, across every app, without you explaining anything.**

It keeps a short, private memory of what you've been looking at: just the last ten minutes, on your own Mac. When you need help, you press one shortcut and ask, out loud or by typing. You can point at anything on screen, a spec, a chart, a confusing setting, and it explains it in plain language using everything you've been doing.

And when you need to *do* something, Glance doesn't just tell you how. Pip, our little penguin, flies to the exact button on your screen and guides you through it step by step, noticing if you click the wrong thing.

Because it sees your screen, privacy was built in from the start. Passwords, banking pages and private windows are never recorded. Card numbers and personal details are hidden before anything is sent. And you can wipe the memory with one click.

Other tools record your screen, or make you explain it to a chatbot. **Glance remembers your screen, and helps you act on it, privately.**

Let us show you."

**Short (about 20 s):** "Every AI makes you explain your screen: screenshots, copy-paste, repeat. Glance is a Mac companion that already knows what you've been doing across your apps. Point at anything or just ask, and it explains it, or Pip flies to the exact button and guides you step by step. And it's private: sensitive details are hidden before anything leaves your Mac. Let us show you."

---

## 1. Main script (3:00)

One presenter (P) and one driver (D). It also works with one person doing both: DO lines are short.

| Time | SAY | DO |
|---|---|---|
| **0:00** | "This is Aoife. She starts college next month. She needs her first laptop, under €1,200, and her course uses software she's never opened." | Slide 1 on screen. |
| 0:10 | "Every AI she tries makes her explain her screen again: screenshot, copy, paste, repeat. Her Mac already has the answer on screen. It just can't see it. So we built Glance." | Switch to the Mac (Safari, page 1). |
| **0:20** | "Aoife's been shopping. A ThinkPad…" | Page 1 is open; scroll slowly for 5 s. |
| 0:25 | "…a MacBook Pro…" | Tab to page 2; scroll 5 s. |
| 0:30 | "…and she keeps her budget in Notes, like everyone does." | Cmd-Tab to Notes (the budget note is already there); hold 4 s. |
| 0:35 | "She never told Glance any of this. It's been keeping a short memory of her screen, on her Mac, for the last ten minutes." | Tab to page 3 (MacBook Air specs). |
| **0:42** | "So she just asks." | **Hold ⌥Space**: *"Which of the laptops I looked at fits my budget?"* Release. |
| 0:47 | *Filler A* (section 2): "While it thinks: notice she didn't select anything or paste anything. Glance is reading what she looked at across Safari and Notes, and it's already hidden anything sensitive before it goes to the model." | Wait. Pip shows "Thinking…". |
| ~1:05 | (Let the spoken answer play: it names the laptops and the €1,200 / 16 GB budget.) "Three pages and a note from two different apps, and she never copied a thing. **ChatGPT or Claude would need her to explain or screenshot all that. Screenpipe or Recall would let her search it. Glance already has it, and acts on it.**" (15 s: take it from the Point beat's filler.) | When it's done, click **Show more**: point at the full answer. Then **Hide chat**. |
| **1:15** | "Now a spec she doesn't get." | **Tap ⌥Space** → click **Point** → drag a box over the "Unified memory" row. |
| 1:20 | | **Hold ⌥Space**: *"What does this mean for me?"* Release. |
| 1:23 | *Filler B*: "Pointing is just a box. Only that box and her question go out, and she can see exactly what was sent." | Wait. |
| ~1:40 | (Spoken answer connects unified memory to her 16 GB need.) "Plain English, tied to her own note." | Let the box clear on its own. |
| **1:45** | "That's buying. Now the part that scares students: new software. Her assignment is due as a PDF, in Pages." | Click into the Pages document (it must be frontmost). |
| 1:50 | | **Hold ⌥Space**: *"Show me how to export this as a PDF."* Release. |
| 1:53 | *Filler C*: "Glance doesn't screenshot and guess. It reads the app's real menus and buttons, the same way VoiceOver does, so when it points, it points at the real thing. And it never clicks for her: she does the clicking, she does the learning." | Wait for Pip to fly to **File** and ring it. |
| ~2:10 | "File. Watch: I'll open the wrong one on purpose." | Click **Edit** and leave it open. Pip: *"That's Edit. Close it and click File."* (local, under half a second). |
| 2:15 | "Caught instantly, no AI call." | Press Esc to close Edit. Click **File**. Pip moves to **Export To** by itself. Hover it; Pip moves to **PDF…**. Click **PDF…**. |
| 2:22 | "She hasn't said 'next' once. Glance watches the screen change and moves on." | The Export sheet opens; Pip rings **Next** (a local advance, or a re-check: Pip shows "Checking…"). Click **Next**, then **Export** in the save panel when Pip rings it. |
| **2:35** | "Last thing: a tool that sees your screen has to earn trust. Here's a fake bank page." | Cmd-Tab to the bank tab (pre-opened). **Tap ⌥Space** → **Point** → drag over the whole page. **Hold ⌥Space**: *"Can you read this page?"* |
| 2:42 | "Before anything leaves the Mac, Glance stops and asks: it hid a card number, an IBAN, a PPS number and a password. I'll hit Cancel." | Pip's bubble shows Send/Cancel. Click **Cancel** ("Cancelled. Nothing was sent."). Click **Show more**: the preview with black boxes. |
| 2:50 | "Nothing sent. And one click forgets the last ten minutes." | Menu-bar penguin → **Forget Last 10 Minutes**. |
| **2:55** | "Screenpipe remembers your screen. Glance helps you act on it, privately. Built today. Thank you." | Slide 4. |

The Guide beat (1:45–2:35) is the one most likely to run long. If it reaches 2:35 before **Export**, say "and she finishes from there," then move on to privacy.

---

## 2. Filler lines for the ~20 s model wait

Every line is true on `main`. Pick the next unused one; each takes about 6–8 s.

- **A (memory):** "She didn't select or paste anything. Glance has been reading the windows she looked at, on-device, for the last ten minutes, and that memory never leaves the Mac until she asks."
- **B (pointing):** "Pointing is just a box. Only that box and her question go out, and she can open the preview to see exactly what was sent."
- **C (Guide):** "It reads the app's real menus and buttons through macOS Accessibility, the same data VoiceOver uses, so it rings the actual control, not a guess from a screenshot."
- **D (redaction):** "Before anything goes to the model, card numbers, IBANs, PPS numbers, emails and passwords are swapped for tags like [CARD], and blacked out in the image."
- **E (exclusions):** "Some apps it never looks at: Keychain, Passwords, 1Password, System Settings. Banking and login pages are never saved to memory."
- **F (voice):** "She can talk or type. Voice is transcribed by ElevenLabs, or on the Mac when offline, and only the short answer is read out."
- **G (honest):** "The model's in the cloud today, so this pause is the network. There's also a Local Only switch that uses Apple's on-device model."
- **H (never clicks):** "Guide never clicks for her. Our tests fail the build if any click code appears."

If the wait passes 30 s, say: "It's thinking hard; I'll show you the answer in the chat when it lands," and carry on with the next beat. Come back to it with **Show more**.

---

## 2b. Why not just…? (as far as we know; we haven't benchmarked any of these)

| | Context across apps, last few minutes | Points at the real control on screen | Step-by-step guide through menus | Redacts before sending + excluded apps | Local-only mode |
|---|---|---|---|---|---|
| **Glance** | Yes (10 min, on the Mac) | Yes (Accessibility, OCR fallback) | Yes (follows File › Export To › PDF… live, catches wrong menus) | Yes | Yes (Apple on-device model) |
| ChatGPT / Claude / Gemini desktop apps | You explain or share a screenshot/window | No, answers in chat | Text instructions | Your responsibility | No (cloud) |
| Claude computer use / agents | Screenshots of the current screen | It clicks for you instead of teaching you | It does the task, you don't learn it | Depends on the setup | No |
| Screenpipe / Rewind / Microsoft Recall | Yes: they record and search your history | No | No | Recall filters some sensitive info; all keep data locally | Screenpipe and Recall are local |
| Cluely-style overlays | The current screen/meeting | No | No | Not their focus | No |

One line: **"Screenpipe remembers your screen. Glance helps you act on it, privately."**

---

## 3. Short versions

### 60 seconds
"Aoife needs a laptop under €1,200 and has to learn Pages for college. Every AI makes her explain her screen from scratch. Glance is a Mac companion that already knows what she's been looking at. [Hold ⌥Space] *'Which of the laptops I looked at fits my budget?'* It answers from three pages and her Notes, and she never copied a thing. [Pages] *'Show me how to export this as a PDF.'* Pip flies to the real File menu, follows her through Export To, PDF and Next, and corrects her if she opens the wrong menu. It never clicks for her. And it's private: card numbers and passwords are blacked out before anything is sent, risky sends need her OK, and one click forgets the last ten minutes. Screenpipe remembers your screen. Glance helps you act on it, privately."

### 30-second elevator pitch
"ChatGPT makes you explain your screen; Screenpipe just records it. Glance is a Mac app that already knows what you've been looking at. Point at anything, or just ask, and it explains it, or flies to the exact button and guides you step by step through any app. It's private by design: sensitive numbers are hidden before anything leaves your Mac, risky sends ask first, and memory forgets itself after ten minutes. Screenpipe remembers your screen. Glance helps you act on it."

---

## 4. Q&A (short, honest)

**How is this different from Screenpipe, or ChatGPT with a screenshot?**
"A screenshot is one moment in one app. Glance keeps a ten-minute private memory across apps, so 'the laptops I looked at' works. And it doesn't stop at an answer: Guide points at the real button and follows you through the steps. As far as we know, Screenpipe is an open-source screen recorder with search. It's great at remembering, and we focus on acting. We haven't benchmarked against it."

**Why not just use ChatGPT or Claude's desktop app?**
"You'd have to explain or screenshot what you looked at in other apps. Glance already has the last ten minutes, and it points at the real button and walks you through, instead of writing instructions in a chat."

**Isn't this Microsoft Recall or Rewind?**
"Those record and search your history; as far as we know that's their job. Glance keeps only ten minutes, never stores banking, password or private windows, redacts before sending, and uses that context to guide you step by step."

**Why not let an AI agent just click it for her?**
"Then she never learns Pages. Guide teaches; it never clicks. Agent mode, with plan approval, is our next phase, not this one."

**What exactly gets sent?**
"Only when you ask. Your question, plus either your box selection or, without one, the text of the front window and a redacted summary of the last ten minutes. In Guide, the menu and button names plus the screen text, and an image only if the model accepts images. Everything goes through one function that redacts it first, and the panel shows a preview of what went."

**What if redaction misses something?**
"It can. It's pattern-based: Luhn-checked card numbers, IBANs, PPSNs, emails, keys, and values next to 'password' or 'PIN'. An unusual format can slip through. So there are layers: excluded apps, banking and login pages never stored, Send/Cancel for high-risk items in normal questions, the preview, and Local Only. We wouldn't call it perfect."

**What's local?**
"Screen capture, text recognition, the memory database, redaction, the menu and button reading, and Pip's pointing all run on the Mac. The cloud only sees what you ask about. Local Only switches the AI to Apple's on-device model and blocks every non-local network request."

**What was the hardest part?**
"Guide. Getting Pip onto the exact control across different coordinate systems and screens, following a menu path like File › Export To › PDF… live without asking the AI at every hop, and noticing a wrong click locally. Plus making privacy real: one exit point for data, with tests that fail if anything bypasses it."

**What's next?**
"Agent mode (Phase 9): Glance does the task itself, but only after you approve its plan. It gets a visible 'in control' indicator, Esc to stop, a confirmation before anything irreversible, and it never types passwords or acts in excluded apps. It isn't started yet. First we want real students using Guide."

**Why Mac?**
"A one-day build that needs deep access to the screen, Accessibility and on-device text recognition, which macOS gives consistently. The design (capture, redact, ask, point) isn't Mac-only."

**How many people, and what did Claude Code do?**
"[Team size and names.] We designed it, chose every feature and privacy rule, tested every phase on a real Mac, and decided what shipped. Claude Code wrote most of the code, in several parallel sessions with one coordinating them, each phase gated by our checks and an automated self-test suite of over 400 checks. Built today."

**Which AI models?**
"Your choice in Settings: Claude, OpenAI, DeepSeek, an OpenAI-compatible endpoint (we're using one on Azure), or local. Voice is ElevenLabs, with Apple's voice and speech recognition as fallbacks."

---

## 5. Slides (max 4)

1. **Aoife.** A photo-style image of a student, a laptop and lots of tabs. Text: "Every AI makes you explain your screen again." Two needs: a laptop under €1,200, and new software for her course.
2. **What Glance does.** Three words with an icon each: **Remember** (ten minutes, on your Mac) · **Explain** (point or just ask) · **Guide** (Pip rings the real button). One screenshot of Pip ringing File › Export To. Backup only, if the demo can't start.
3. **Private by design.** The Send/Cancel bubble plus the blacked-out bank preview. Bullets: excluded apps · redacted before sending · Send/Cancel for card/IBAN/PPS/password · Forget Last 10 Minutes · Local Only. Small print: "Redaction isn't perfect, so there are layers."
4. **Close.** "Screenpipe remembers your screen. Glance helps you act on it, privately." Under it: built today at Dublin HacX · Swift, macOS Accessibility, Vision, ScreenCaptureKit · Claude Code · team names.

---

## 6. Rubric map

| Criterion (weight) | Moment |
|---|---|
| Technical (20) | 0:42 memory across Safari + Notes; 1:53 Guide reads real menus, follows File › Export To › PDF… locally, and catches the wrong menu with no AI call; 2:35 redaction + blackout. Q&A "hardest part". |
| Impact (20) | 0:00 Aoife's real problem (money + new software); 1:45 "the part that scares students"; Q&A "what's next" (real students). |
| Innovation (15) | Pointing at the real control instead of describing it; memory across apps; noticing wrong clicks; the Screenpipe close line. |
| Completeness / working demo (15) | All four beats live on one Mac; the "hasn't said next once" moment; fallbacks ready (section 8). |
| Design (10) | Pip: one-line field, Show more / Hide chat, the ring above open menus, spoken short answers with full detail on screen. |
| Presentation (10) | One persona, one path, timed to the second, scripted fillers so there's never silence. |
| Judge's preference (10) | The privacy beat (Cancel → "Nothing was sent", black boxes, Forget) and honest Q&A answers ("it isn't perfect, so there are layers"). |

---

## 7. Pre-demo checklist (10 min before)

- [ ] **One desktop, no full-screen apps**: Safari, Notes, Pages and the browser all windowed on the main display. Guide's coordinates assume this.
- [ ] Do Not Disturb on (Control Centre → Focus). Quit Mail, Messages, Slack, Chrome and anything else noisy. Volume up.
- [ ] Glance launched (penguin in the menu bar). Mic, Screen Recording and Accessibility granted. Tap ⌥Space once to check, then tap again to hide.
- [ ] Keys set in Settings (provider + ElevenLabs). Ask one test question and check that it answers. **Local Only OFF.**
- [ ] Menu → **Forget Last 10 Minutes** (clear rehearsal memory), then **within 10 minutes of going on**, open in this order: page 1 (ThinkPad X1), page 2 (MacBook Pro specs), the budget note in Notes, page 3 (MacBook Air specs, scrolled to "Unified memory"). Memory keeps only the last 10 minutes.
- [ ] Pages: a short document open, no export sheet open. Delete old exported PDFs from the Desktop.
- [ ] The mock bank page open in a browser tab, but not frontmost until beat 5.
- [ ] Guide: `guideAutoRecheck` left at its default (on) for the hands-free beat. Rehearse the Pages flow once on this Mac today.
- [ ] Backup video queued (record it right after a clean rehearsal).
- [ ] Optional log in a hidden Terminal: `/usr/bin/log stream --predicate 'subsystem == "ie.dublinhacx.glance"' --info`.

---

## 8. If it breaks

| Beat | Symptom | Do this, and say this |
|---|---|---|
| Any question | Over 30 s and no answer | Say filler G, move on to the next beat, and come back with **Show more** later. If the network is dead, Menu → **Local Only** and ask again ("same question, fully on the Mac"). |
| Voice | Mic or transcription fails | Tap ⌥Space and **type** the question into Pip's field. "Typing works too." |
| Memory answer | Ignores a laptop or the budget | **Show more**: point at the activity list in the preview ("here's everything it remembered"). Re-ask: "Compare the ThinkPad, MacBook Pro and MacBook Air against my €1,200 budget." |
| Point | The box lands wrong | **Point** again and redraw. A new box starts a fresh question. |
| Guide | Doesn't start (answers like Explain) | Click the **Guide** chip in the chat header (Show more first), then ask again. |
| Guide | Pip doesn't move after File opens | Keep going by hand and say "Export To, then PDF". Then **tap ⌥Space** or say "next" for the next step (v1 behaviour). |
| Guide | Hands-free stalls after PDF… | Tap ⌥Space (= next). "It also takes a 'next' from her." |
| Guide | Pages misbehaves | Switch to **TextEdit** (document open): "Show me how to export this as a PDF" → File › Export as PDF… › Save. |
| Guide | Wrong-menu line missing | Skip the wrong-click part; close the menu and continue. |
| Privacy | No Send/Cancel | **Show more** and point at the black boxes in the preview: "it still hid them." Then Forget. |
| Privacy | Bank page won't open | `open demo/mock-bank.html` from Terminal, or skip straight to **Forget Last 10 Minutes**. |
| Whole demo | Mac or Glance down | Play the backup video and narrate the 60-second version (section 3) over it. |
