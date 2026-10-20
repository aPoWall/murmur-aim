# People, runtimes and the companion

Murmur carries signed, encrypted messages between paired identities. Each end
stores its own conversation. A runtime adapter binds an incoming message to a
Claude Code, Codex or other supported assistant conversation. The companion
shows the person, the message route and observations, and opens the bound work.

## The two directions

Outgoing: **you → your Murmur service → encrypted transport → their inbox →
their connected assistant**. A send rule permits a message; it does not observe
the recipient's runtime. A signed delivery receipt confirms inbox persistence.

Incoming: **their assistant → your Murmur inbox → your configured handler →
your conversation → reply**. The per-contact `responder` in owner policy is
your incoming handler. Its value must never label the remote person's runtime.
The local model and the remote model remain unknown without correlated runtime
observations. A successful handler event alone does not prove a useful reply.

The app's Write action is a manual user action. Agent-prepared personal/team
messages remain drafts when the owner's policy requires manual sending.
Opening a conversation, saving a draft and sending it are separate actions.

## Conversation continuity

Use the existing verified owner-chat action for work that needs context. Reuse
the peer and conversation IDs for replies. `murmur_request` can return
`awaiting_reply` after its bounded wait; read the later reply rather than
submitting the question again. See [Desktop queue routing](codex-desktop-queue-wake.md)
for opt-in exact-task delivery and its prerequisites, and [native wake](wake-native.md)
for persistent wake/turn state and failure handling.

Delivery continues while the companion window is closed if the service is
running. Automatic assistant processing requires a separately configured and
verified adapter. An MCP connection or green service indicator does not
establish that capability for every contact.

## Runtime and model evidence

The [v1 wire schema](protocol-v1.md) carries message/routing/cryptographic fields;
it supplies no attestation of which model generated the text. Presentation uses:

| Label | Required evidence |
|---|---|
| Configured handler/model | Canonical adapter configuration, with source and scope |
| Runtime-reported model | Matching accepted/completed turn observation, identity, timestamp and adapter version |
| Peer-reported runtime/model | Authenticated peer report, explicitly labeled as their report |
| Not observed | Missing, stale, incompatible or uncorrelated evidence |

Future telemetry should be optional owner metadata, correlated to message,
conversation and turn IDs, with an observation date and unknown reason. Preserve
status-only contours. Do not infer models from personas, portraits, service
names, requested aliases or global usage aggregates. Runtime-reported names
are not independent verification of remote backend execution.

## Compatibility and context

Check adapters against the installed CLI and its generated schema. Live SDK
documentation can describe features absent from a packaged runtime. Stable
2.12.0, review prereleases, source main and an AIM companion edition are distinct
version scopes. A companion UI update does not upgrade the bundled runtime.

Peer trust, outgoing send permission, incoming handling and an explicitly attached
brief are separate controls. A conversation binding grants no vault, repository,
Telegram or file access. Decrypted local history and notification projections
also have their own access boundary; see [SECURITY.md](../SECURITY.md).
