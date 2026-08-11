---
status: accepted
---

# Support independent and desktop Codex Runtimes

codexCycle will continue to read rate limits through `codex app-server`, but its authenticated Codex Runtime may come from either an independent Codex CLI or the current ChatGPT desktop app. It prefers a compatible independent CLI, falls back to the current Desktop Runtime, and treats the pre-merge Codex App as best-effort only. A Desktop Runtime is executed only when its app identity and OpenAI Team ID are pinned and both the bundle and executable pass macOS signature validation; this expands Desktop-only compatibility without taking ownership of authentication, at the cost of rejecting modified or re-signed builds and requiring an update if OpenAI changes signing identity. An unsigned independent launcher is limited to the official npm-compatible `#!/usr/bin/env node` shape: codexCycle preserves its launcher directory, filters inherited `PATH` entries through local ownership and permission checks, and validates the resolved `node` interpreter before either version probing or app-server startup. This supports package-manager launchers without extending the signature exception to arbitrary shebang scripts or interpreters.
