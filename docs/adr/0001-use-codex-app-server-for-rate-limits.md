---
status: superseded by ADR-0003
---

# Use Codex app-server for rate limits

The app will use the locally installed and authenticated Codex CLI as its sole usage-data source, reading structured rate-limit data through `codex app-server` and deriving the weekly remaining percentage from the weekly window. This keeps authentication owned by Codex and avoids scraping the usage website, parsing terminal output, or copying private credentials, at the cost of requiring a compatible local Codex CLI.
