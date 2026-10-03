# Glance pitch (Dublin HacX)

Pitch rules: say only what the live demo shows. Anything marked [if built] gets cut from the script if it isn't working at the freeze. Say "as far as we know" whenever Screenpipe comes up.

## 1. The 2.5-minute script (about 150 s, same order as the demo in PLAN.md)

**0:00 – 0:15 | Problem (slide 1)**
"This is Aoife. She's starting college, she needs her first laptop, and her course uses software she's never seen. She's got ten tabs open, a budget in her notes, and every time she asks an AI for help, she has to explain everything again. Or take a screenshot. Or copy and paste. Her computer already has the answer on screen. It just can't see it. So we built Glance."

**0:15 – 1:15 | Shopping: Explain (live demo)**
"Aoife looks at two laptops, and jots her budget in Notes. Nothing special. Now she's on a third laptop." (Drag a box over the specs, then hold the hotkey and speak.) *"How's this different from the earlier ones?"*
"Hear that? It compared all three laptops, and used her budget, from two different apps. She never copied anything. Glance has been quietly keeping a short memory of what she's been looking at, on her own Mac."
(Drag a box over a confusing spec.) *"What does this mean for me?"*
"Plain answer, spoken back. She points, she speaks, she gets help."

**1:15 – 2:00 | Learning: Guide (live demo)**
"Now her course app. She says: *'Show me how to export this as a PDF.'*" (Highlight appears.) "Glance doesn't just tell her. It draws a ring on the exact button on her screen, and says it out loud. She clicks, asks for the next step, and it moves on." [if v2 built: "If she clicks the wrong thing, it notices and says so."]

**2:00 – 2:20 | Privacy (live demo)**
"Now, a tool that sees your screen needs to earn trust. Here's a fake bank page with a fake card number. She points at it. Before anything leaves the Mac, Glance shows you exactly what will be sent, and the card is blacked out. [if built: 'I hid 3 sensitive items.'] Password managers are never captured, and banking and login pages are never saved to memory. When you point at one yourself, card numbers and IBANs are hidden first. [if Ollama is set up: "And this switch keeps everything on the laptop, with a local model."] One click forgets the last 15 minutes."

**2:20 – 2:30 | Close (slide 4)**
"Screenpipe, as far as we know, remembers your screen. Glance helps you act on it, privately. Built today. Thank you."

Delivery notes
- One person talks, one person drives the demo, or one person does both and the script above is written to survive that.
- If the model is slow, keep talking over it ("while it thinks, notice the highlight already shows..."). Never sit in silence.
- Do not read slides. Slide 1 is on screen while speaking the problem, then straight to the demo.

## 2. The 30-second fallback (no live demo, or time cut)

"Aoife is buying her first laptop and learning new software, and every AI makes her explain her screen from scratch. Glance is a Mac app that already knows what she's been doing across her apps. She points at anything and speaks, and it either explains it, or draws highlights on her screen to guide her step by step. It's private by design: it hides card numbers and passwords before anything is sent, shows her what's being sent, and has a local-only mode. Screenpipe, as far as we know, remembers your screen. Glance helps you act on it."

(If a demo video is playing, play the 20 s clip of point, speak, answer over this.)

## 3. Q&A prep (short and honest)

**Is this just Screenpipe / ChatGPT with a screenshot?**
"A screenshot is one moment in one app. Glance keeps a short, private memory across apps, so it can answer 'how is this different from the earlier ones?'. And it doesn't stop at an answer: it points at the button on your screen. As far as we know, Screenpipe is an open-source screen recorder with search and plugins, which is great at remembering. We're focused on the next step, acting on what you see. We haven't benchmarked against it."

**Is it safe? Does it record my passwords?**
"It's built so it shouldn't. Password managers, Keychain, System Settings and banking or login pages are excluded before anything is read or stored, and frames with a focused password field are skipped. Memory is kept for 15 minutes, then deleted, and the capture indicator is always visible with a pause and a 'forget last 15 minutes' button. Nothing leaves the Mac except when you ask a question, and you see a preview of exactly what's sent first."

**What happens if redaction misses something?**
"It can. Redaction is pattern-based: card numbers (checked with the Luhn test), IBANs, Irish PPSNs, tokens, and values next to 'password' or 'PIN'. It won't catch everything, like a secret written in an unusual format. That's why there are layers behind it: exclusions, the preview you can check before sending, and local-only mode, where nothing goes to the cloud. We'd tell users not to treat it as perfect."

**What was the hardest part to build?**
"Making the privacy part real rather than a promise: deciding what must be excluded before it's stored, and making the send step the only way anything leaves the Mac. Second hardest was getting the highlight onto the right button, which uses accessibility data, with text matching on the screen as a fallback." (Adjust to what actually happened today.)

**What's next?**
"Finish the 'check if she did it right' loop in Guide, so it corrects wrong clicks. Then an 'approve and do it for me' mode, like saving a comparison. Then testing the redaction against much more real data, and getting feedback from real students."

**How does it make money / scale?**
"Honest answer: we haven't built a business today. The likely route is a paid app or subscription for people who learn lots of software, such as students and new employees, with users able to bring their own AI key or run fully local. Because the privacy is on-device, it can scale to organisations that can't use cloud screen tools."

**Why Mac only?**
"A one-day build, and we needed deep access to the screen, accessibility and on-device text recognition, which macOS gives us in a consistent way. The design (capture, redact, ask, highlight) isn't Mac-specific, so Windows is possible later, but we'd rather be good on one platform first."

Other likely questions
- *Which AI does it use?* "Your choice: Claude, OpenAI, DeepSeek, or a local model. Voice is ElevenLabs, with Apple's on-device speech when offline."
- *What did you build today vs. use?* "The app, capture, memory, redaction, overlay and modes are built today. The AI models and ElevenLabs are services we call." (Say this up front if asked; judges score what was built today.)

## 4. Slide outline (max 4)

1. **Aoife's problem.** One photo-style image: a laptop, many tabs. Text: "Every AI makes you explain your screen again." Aoife's name and two bullet needs (first laptop, new software).
2. **What Glance does.** Three words: Remember (across apps, on your Mac), Explain, Guide. One screenshot showing a highlight on a button. Shown only if we need to introduce it before the demo.
3. **Private by design.** The send preview with a blacked-out card; list: excluded apps, local redaction, preview before sending, local-only mode. Small caption: "Redaction isn't perfect, so there are layers."
4. **Close.** "Screenpipe remembers your screen. Glance helps you act on it." Under it: Claude / OpenAI / DeepSeek / local, ElevenLabs, built today at Dublin HacX, team names.

The live demo replaces slides between 1 and 3. Slides are backup, not the pitch.

## 5. Rubric to pitch moment

| Criterion (weight) | Where the pitch earns it |
|---|---|
| Technical Execution (20%) | 0:15 – 1:15, answer uses three apps from on-device memory; 1:15 – 2:00, highlight lands on the exact button; 2:00 – 2:20, redaction and local-only mode. Q&A "hardest part" backs it up. |
| Innovation & Creativity (15%) | 0:00 – 0:15 plus the close: memory plus pointing plus highlights on your real screen, not a chat box. The Screenpipe line shows we know the field. |
| Impact & Usefulness (20%) | 0:00 – 0:15, Aoife's real problem (first laptop, new software), and her demo story from 0:15 to 2:00. Q&A answer on scale mentions students and new employees. |
| Completeness & Working Demo (15%) | The two live demo segments (0:15 – 2:00) and the privacy moment (2:00 – 2:20). Backup video plays if the live demo fails. Say plainly what is and isn't built. |
| Design & UX (10%) | Hold-and-speak interaction at 0:15, the highlight ring at 1:15 – 2:00, the plain send preview at 2:00. Slide 2 and 3 screenshots. |
| Presentation (10%) | Story-first opening, one persona, one demo path, strict 150 s plan, 30 s fallback ready. |
| Judge's Preference (10%) | The privacy moment (2:00 – 2:20) and the honest Q&A answers: trust is what a cautious or non-technical judge remembers. Aoife's story gives a parent judge something to relate to. |
