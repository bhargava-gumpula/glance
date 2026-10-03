# Open decisions

Each open decision has a working default and exactly one place to change it.

| Decision | Default | Where to change |
|---|---|---|
| Product name | Glance | `Config.bundleID`, `scripts/build-app.sh` (Info.plist), README |
| Hotkey | ⌥Space | `Config.hotkeyKeyCode` / `hotkeyDescription` |
| Capture interval | 3 s | `Config.captureIntervalSeconds` (Settings override) |
| Memory retention | 15 min | `Config.retentionMinutes` (Settings override) |
| Default AI provider | Claude | `Config.provider`: claude / deepseek / openai / local |
| Default models | Claude `claude-opus-5-5`, DeepSeek `deepseek-chat` (text-only → OCR text), OpenAI `gpt-5`, Local `qwen2.5vl` @ `localhost:11434/v1` | `Config.providerPresets`; per-provider override in Settings (model, address, "can see images") |
| Claude effort | low (snappy panel) | `Config.claudeEffort` |
| Claude refusal fallback | on (`fallbacks: "default"`, Anthropic picks the fallback model) | `AI/AnthropicProvider.swift` |
| What a question sends | Only the selected region: one image of it plus its OCR text (text-only models get just the text). The rest of the screen is never captured | `ContextPacket.capture` / `firstMessage` |
| Explain prompt and follow-ups | brief, grounded, quotes the spec it relies on; "Explain more" / "Example" | `Modes/Mode.swift` (moves to `Resources/prompts/` if prompts need editing without a rebuild) |
| New selection = new conversation | yes | `ChatModel.pointed` |
| ElevenLabs voice | set in Phase 2 | Settings (Phase 2) |
| Speak answers aloud | on | `Config.ttsEnabled` |
| Never-captured apps | Keychain, System Settings, Passwords, 1Password, Bitwarden | `Config.excludedApps` |
| Never-captured sites | set in Phase 3 | URL blocklist (Phase 3) |
| Redaction rules | Cards (Luhn), IBAN (mod-97), PPSN (check letter), SSN, emails, phones, street addresses + Eircodes + labelled addresses, crypto wallets (ETH, BTC, base58) and private keys/seed phrases, API keys/JWTs/bearer tokens/passwords, labelled account/brokerage/ID numbers and 2FA codes, usernames/@handles//Users paths, dates of birth, names (labelled, or two-word names found by Apple's NaturalLanguage tagger), IP addresses. Matching OCR lines are blacked out in images | `Privacy/Redactor.swift` |
| Redaction override | Only when the question explicitly asks ("don't redact", "unredact", "show the hidden …", "it's okay to see …"); lasts until the next selection and the preview says so. Excluded apps are never captured either way | `Redactor.userAskedToReveal` |
| "Do" actions | save comparison only | `Modes/Do.swift` (Phase 7) |
| Visual style | system default | `UI/` (Phase 8) |
| Demo sites and Guide app | Safari product pages; export-to-PDF flow | docs/PLAN.md, Demo |
