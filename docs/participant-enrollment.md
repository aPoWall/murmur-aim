---
title: Independently revocable participant credentials
status: reference validated
updated: 2026-10-16
tags: [security, enrollment, nats]
---

# Independently revocable participant credentials

Issue #169 is a design and acceptance task. The design below has an executable reference and a real isolated Core NATS revocation test. **The normal Murmur runtime and invitation format are unchanged.** Existing installations still use their configured shared token; installing this source does not migrate them or make that token independently revocable.

## Decision and credential boundaries

Use one **NATS user NKey per participant**, independently generated on that participant's device. Its private seed stays on that device; the enrollment registry and broker hold only its public NKey. A random immutable `principalId` identifies the enrollment record. `agentId` selects its receive subjects. Neither is a private E2E key.

The existing Murmur encryption and signing keys remain separate. Broker authentication admits a connection; subject ACLs constrain routing; Murmur signature verification, encryption and peer trust still govern the letter. Revoking broker access does not change E2E identity, erase delivered content or revoke a separate credential that the participant may possess.

NATS supports public NKeys and challenge signatures, so the broker does not need a participant password or private seed. Subject publish and subscribe permissions are independent. The native behavior is described in [NATS authentication](https://docs.nats.io/learn/security/authentication-basics) and [authorization](https://docs.nats.io/learn/security/authorization).

## Enrollment contract

```mermaid
sequenceDiagram
    participant O as Operator
    participant R as Enrollment registry
    participant P as Participant device
    participant B as Broker
    O->>R: Allocate agentId and exact allowed peers
    R-->>O: Random one-use nonce; maximum 15 minutes
    O->>P: Trusted invitation with verified enrollment service address
    P->>P: Generate a separate broker NKey seed
    P->>R: Nonce, public keys, signed enrollment challenge over TLS
    R->>R: Verify proof; atomically consume nonce and bind principal
    R-->>P: Principal accepted, broker application pending
    O->>B: Validate and apply public NKey plus exact ACLs
    P->>B: NKey challenge authentication
    B-->>P: Connection accepted
```

The operator allocates an unused `agentId` and an allow-list of peer IDs. IDs use the existing conservative ASCII identifier syntax; subject separators, wildcard characters and NATS control-plane names cannot be injected. The reference limits the peer list to 128 and the lifetime to 15 minutes. A 256-bit random bearer nonce is returned once; SQLite stores only SHA-256 of it, its scope and expiry.

The device submits its `agentId`, new broker public NKey, and existing/new Murmur E2E signing and encryption public keys. Its broker key signs a domain-separated challenge containing all four fields and the nonce digest. Changing identity or keys invalidates the proof. This proves possession of the broker key; the usual signed/encrypted Murmur handshake is still required to verify E2E key possession and two-way reachability.

One SQLite `BEGIN IMMEDIATE` transaction checks expiry and unused status, rejects an occupied identity or previously bound NKey, creates the participant, and marks the invitation consumed. Successful redemption cannot be repeated, including after registry restart. Invalid proofs, wrong identities and expired nonces create no participant. Two invitations for the same identity cannot create two participants because the durable identity uniqueness constraint also applies. A revoked principal remains a tombstone and cannot silently enroll again under a fresh invitation.

A lost enrollment response does not justify replay or issuing duplicate credentials. A future service must offer an authenticated status/recovery operation that proves the same public NKey, or an operator explicitly starts a replacement flow. The reference deliberately does not add that network service.

## Subject authorization

For participant `alice`, with approved, active peer `host`:

| Operation | Exact grant | Everything else |
| --- | --- | --- |
| Subscribe | `msg.alice`, `ack.alice` | Denied |
| Publish | `msg.host`, `ack.host` | Denied |

Both participants need their own independently approved publish scope. A peer registration does not automatically grant the reverse direction. A principal with no active peers gets `publish: { deny: [">"] }`: an empty NATS allow-list would not reliably express deny-all. A revoked peer is removed from other principals' generated publish lists too. The generator refuses to produce an empty user list, which could otherwise result in an unintentionally unauthenticated listener.

No wildcard message subscription, `$SYS`, `$JS`, `_INBOX`, arbitrary reply subject or dynamically inferred peer grant is emitted. Core Murmur delivery acknowledgements use the explicit `ack.<agentId>` subjects. A sender with permission for a destination still cannot impersonate another sender to Murmur without the corresponding signing key; valid peer signatures remain mandatory.

## Revocation: requested and observed are different

`revoke(principalId)` persists a tombstone and returns `pending-broker-apply`. It does not claim that a live connection stopped. The operator renders the remaining public principals, validates the complete broker configuration, applies it by the broker's supported reload, and checks that:

1. The revoked principal's existing connection is closed.
2. A fresh connection with the same seed is refused.
3. An unaffected participant sends and receives on its **same connection**, with no disconnect/reconnect.
4. Every relevant cluster node, listener, leaf or gateway observes the same policy before revocation is reported complete.

The reference test proves the first three on one isolated broker, not a federated deployment. A partial or failed reload leaves revocation **pending** and must not undo the tombstone. Subsequent configuration reconciliation retries from durable desired state. NATS configuration validation and reload are described in [config management](https://docs.nats.io/learn/deployment/config-management).

## Migration and rollback

There is no automatic migration and no production command in the reference. Rollout requires the separately approved broker/peer window from #153 and the following concrete plan:

- Inventory every direct daemon, MCP process, service account, dashboard, auxiliary sender, leaf and broker credential. Record explicit profiles and independently verified recovery copies; do not scan and guess a running identity.
- Add runtime support for a mutually exclusive broker auth descriptor, for example `auth.mode = nkey` plus an explicit private seed-file path. A legacy token and NKey mode together must fail clearly. Enforce private seed ownership/ACLs, avoid values in argv/logs, and support the selected profile consistently across entrypoints. This code is **not** in the reference.
- Rehearse on an isolated parallel TLS-protected broker/account with individual principals and equivalent allowed peers. Never bridge the legacy unrestricted account into the new restricted subject space in a way that bypasses ACLs. Require normal signed encrypted roundtrips, wake tests and native service restart checks before per-profile cutover.
- During the approved window, move the coordinated peer group to the new listener/account, keeping E2E keys, store, cursors and message IDs. Stop each old connection before starting its replacement; do not dual-send or bulk replay queues. Verify each participant and retire its legacy route.
- Independently revocable access is achieved only after any shared/alternative credential known to those participants no longer reaches the protected subjects. A legacy token that still works on the old broker defeats the revocation promise. Retiring or rotating that token remains a separate coordinated operation.
- Before any participant is revoked, rollback may restore the original explicit profiles and old listener within the approved window. After revocation or suspected shared-token compromise, rollback must preserve the deny decision: retain the new ACLs or issue replacement credentials only to still-authorized peers. Never restore an old shared secret or registry snapshot that re-enables a revoked principal. Restore tombstones and consumption history before admitting traffic.

The enrollment service itself must authenticate its operator, verify TLS server identity, protect invitation delivery, apply rate limits, keep a trusted clock, serialize issuance/revocation, audit public principal changes, protect registry backups and reconcile broker state durably. An offline/expired enrollment fails closed. Those deployment controls are required for rollout; this library is not a hosted enrollment service.

## Explicit scope limits

| Feature | Reference support | Rollout requirement |
| --- | --- | --- |
| Core NATS `msg.<agentId>` / `ack.<agentId>` | Validated | Ordinary signed/encrypted Murmur acceptance after runtime integration |
| JetStream | Excluded | Admin-provisioned streams/consumers, per-principal delivery/ACK/API grants; remove runtime stream-management privileges. Never grant `$JS.>` or `_INBOX.>` globally to make tests pass. |
| Channel-specific subjects | Excluded | Enumerate authorized channel/member routes and test their exact grant/revocation rules |
| Presence, arbitrary NATS request/reply, dashboards | Excluded | Inventory exact subjects and isolated response prefixes before enabling |
| Leafnodes/federation/multiple brokers | Excluded | Define account imports/exports and verify every ingress, cache and reconnect path |
| Public enrollment transport, UI and seed-file storage | Design only | Implement and verify operator authentication, TLS, private storage and recovery flow |

Profiles using excluded features must refuse this migration until the corresponding contract is reviewed and tested. This reference does not broaden permissions silently.

Revocation stops future broker access after application. It cannot recall plaintext already read, ciphertext already stored, copied E2E private keys or independent sessions. A compromised broker seed requires revocation/re-enrollment; compromised E2E keys additionally require explicit contact-key replacement and trust re-verification. E2E encryption does not hide routing metadata or prevent an authorized sender from flooding an allowed destination; server and enrollment quotas remain necessary.

## Reproducible acceptance

The implementation is [reference.mjs](../examples/participant-enrollment/reference.mjs), used only by [participant-enrollment.test.mjs](../tests/participant-enrollment.test.mjs). It has no executable entrypoint, production configuration writer, broker reload helper or access to a user profile. The SQLite handle is injected by the test. Fresh fixture seeds and nonces are never printed.

With a local `nats-server` installed, run from a checkout:

```sh
npm ci
MURMUR_REQUIRE_ENROLLMENT_BROKER=1 node --test tests/participant-enrollment.test.mjs
```

The required-broker flag turns a missing broker into failure, instead of a skip. The ordinary unit suite still runs the enrollment contract tests where a broker is unavailable. The POSIX test launches its own loopback broker on a free port with a temporary configuration, never uses environment broker credentials, reloads only that child PID, then removes its own temporary files.

On 2026-10-16, Linux with Node 22 and **NATS 2.10.22** passed all three tests with zero skips: persisted nonce consumption/restart, expiry and proof/scope/key-reuse refusals, and real broker ACL/revocation behavior. The revoked existing socket closed; its fresh authentication was refused; the second participant kept the same client ID and exchanged messages in both directions. Unauthorized publish and subscribe attempts were rejected and did not deliver to the other participant. Native Windows broker reload and production infrastructure were not part of this proof.
