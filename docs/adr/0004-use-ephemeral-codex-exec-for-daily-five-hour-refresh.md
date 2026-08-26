---
status: accepted
---

# Use ephemeral Codex exec to refresh the five-hour window

At 7:00 AM local time, codexCycle will make one minimal Codex request through
the already selected and validated Runtime, then reread rate limits through
app-server. A rate-limit read alone cannot start or roll the five-hour usage
window.

The menu also provides Request Now for the same purpose. It uses the identical
validated Runtime and execution restrictions, then rereads both supported quota
windows. It remains disabled until a Runtime is active and while a refresh or
another request is running. A manual request made after 7:00 AM satisfies that
day's scheduled attempt so the app does not immediately submit a duplicate.

The request uses the stable non-interactive `codex exec` command with an
ephemeral session, ignored user configuration, a read-only sandbox, no
approvals, and a prompt that forbids tools and file inspection. Standard input,
output, and error are disconnected, and the process is terminated after 90
seconds. The app records the local calendar date when the process starts so a
restart or wake cannot duplicate the request that day. A missed 7:00 request is
performed once after the next launch or wake on that date.

Each scheduled or manually initiated request intentionally consumes a small
amount of Codex quota in exchange for a current five-hour window. It avoids the
experimental app-server thread and turn APIs and does not persist a Codex
conversation, but it temporarily starts a second Runtime process for the
request.
