# Run outside the App Sandbox

The personal macOS app will run outside the App Sandbox and will not target the Mac App Store because it must launch the user's separately installed Codex CLI and reuse the CLI-owned authentication state. Sandboxing would make that local process integration unreliable or require a substantially different authentication and distribution architecture.
