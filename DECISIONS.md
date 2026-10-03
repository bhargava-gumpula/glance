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
| What a question sends | crop of the selection + whole screen (downscaled, selection outlined) + OCR text of the selection; text-only models get all on-screen OCR text instead of images | `ContextPacket.firstMessage` |
| Explain prompt and follow-ups | brief, grounded, quotes the spec it relies on; "Explain more" / "Example" | `Modes/Mode.swift` (moves to `Resources/prompts/` if prompts need editing without a rebuild) |
| New selection = new conversation | yes | `ChatModel.pointed` |
| ElevenLabs voice | set in Phase 2 | Settings (Phase 2) |
| Speak answers aloud | on | `Config.ttsEnabled` |
| Never-captured apps | Keychain, System Settings, Passwords, 1Password, Bitwarden | `Config.excludedApps` |
| Never-captured sites | set in Phase 3 | URL blocklist (Phase 3) |
| Redaction rules | Phase 1: cards (Luhn), emails, API keys → `[CARD]` `[EMAIL]` `[KEY]`; matching OCR lines are blacked out in images | `Privacy/Redactor.swift` (moves to `Resources/redaction.json` in Phase 4) |
| "Do" actions | save comparison only | `Modes/Do.swift` (Phase 7) |
| Visual style | system default | `UI/` (Phase 8) |
| Demo sites and Guide app | Safari product pages; export-to-PDF flow | docs/PLAN.md, Demo |
