# Run outside the App Sandbox

The personal macOS app will run outside the App Sandbox and will not target the Mac App Store because it must launch a locally installed Codex Runtime and reuse the Runtime-owned authentication state. Sandboxing would make integration with either an independent CLI or a desktop-bundled Runtime unreliable or require a substantially different authentication and distribution architecture.
