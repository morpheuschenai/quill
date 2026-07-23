# Quill — AI text actions, right where you need them

Select text or take a screenshot in any Mac app. Press a hotkey. Fix, translate, or summarize — without leaving the app you're in.

<!-- Add a screenshot or GIF here once available: ![Quill popup menu](docs/screenshot.png) -->

**Quill Cloud** (coming soon) — no setup, no API key needed. [Join the waitlist →](https://tally.so/r/68VMRP)

**Open Source** — bring your own API key. Build from source below.

[繁體中文](README.zh-TW.md)

---

## How it works

1. **Select text or take a screenshot** in any app — Mail, Notes, Chrome, Slack, PDF, anywhere.
2. **Press Control + Option + A** — Quill pops up right next to your selection.
3. **Pick an action** — the result replaces your text in place, or appears in a floating panel for read-only contexts.

## Features

- **Rewrite in place** — Fix grammar, change tone, translate; the selected text is replaced directly.
- **Analyze anything** — Summarize, explain, or extract action items from web pages, PDFs, and read-only text.
- **Screenshot AI** — Press Control+Option+Q, capture a region, and extract text or describe what's on screen.
- **Custom prompts** — Add any action with a custom system prompt in Preferences. As many as you need.

## Two ways to use Quill

### Quill Cloud · coming soon

Download and double-click. No API key, no Xcode, no technical setup.

[Join the waitlist →](https://tally.so/r/68VMRP) — first 50 members get one month free.

### Open Source · available now

Bring your own API key. Full control, MIT license, every line auditable on GitHub.

Requires Xcode + Apple Developer account. Build instructions below.

---

## Build from source

```sh
git clone https://github.com/morpheuschenai/quill.git
open quill/Quill/Quill.xcodeproj
```

1. Build and run (**⌘R**).
2. Grant **Accessibility** permission when prompted — System Settings → Privacy & Security → Accessibility.
3. Open Preferences (menu bar icon → Preferences) and paste your [OpenAI API key](https://platform.openai.com/api-keys).

## Configuration

| Setting | Default | Where |
|---|---|---|
| Text action hotkey | Control+Option+A | Preferences |
| Screenshot hotkey | Control+Option+Q | Preferences |
| Text model | `gpt-4o-mini` | `defaults write com.morpheus.quill quill_text_model <model>` |
| Vision model | `gpt-4o` | `defaults write com.morpheus.quill quill_vision_model <model>` |

Quill works with any OpenAI-compatible endpoint — OpenAI, Groq, OpenRouter, or a local Ollama instance.

## Privacy

By default, Quill Cloud proxies requests through Railway to OpenAI. If you switch to your own API key, requests go directly to the compatible endpoint you configure.

- **Content is not stored.** Quill Cloud does not retain screenshots, selected text, prompts, or AI replies.
- **Minimal anonymous metrics.** Daily active use, quota reached, and upgrade intent are deduplicated using a server-HMACed installation identifier. Raw events expire after 90 days.
- **API key stored in macOS Keychain.** Never logged or transmitted.
- **Clipboard-safe.** If Quill reads your selection via clipboard fallback, it restores whatever was there before.

## Known limitations

- Some apps block both Accessibility API access and simulated copy; those won't trigger.
- Read-only contexts (PDFs, browser pages) show the result in a floating panel rather than replacing text in place.
- Rewrite-in-place in Chrome and Electron apps currently falls back to the result panel.

## Development

```sh
xcodebuild test -project Quill/Quill.xcodeproj -scheme Quill \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

See [docs/](docs/) for QA notes and the compatibility matrix.

## License

[MIT](LICENSE)
