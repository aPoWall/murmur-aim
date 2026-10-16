/**
 * Design reference for #169. No HTTP listener, production config writer, broker
 * reload or Murmur runtime integration. The caller supplies a private SQLite DB.
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { nkeys } from 'nats';

const TTL = 15 * 60_000;
const hash = value => createHash('sha256').update(value).digest('hex');
const validId = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(value);
const validTime = value => Number.isSafeInteger(value) && value > 0;
const validPublicKey = value => typeof value === 'string' && Buffer.from(value, 'base64').length === 32
  && Buffer.from(value, 'base64').toString('base64') === value;

/** Domain-separated proof binds the one-time challenge to every public enrollment field. */
export function enrollmentChallenge(invitation, request) {
  if (typeof invitation !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(invitation)) throw new Error('enrollment.invitation-invalid');
  return Buffer.from(JSON.stringify(['murmur.enrollment-reference/1', hash(invitation), request.agentId,
    request.brokerPublicKey, request.signingPublicKey, request.encryptionPublicKey]));
}

export class EnrollmentReference {
  constructor(db) {
    this.db = db;
    db.exec(`PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 1000;
      CREATE TABLE IF NOT EXISTS invitations (
        token_hash TEXT PRIMARY KEY, agent_id TEXT NOT NULL, peer_ids TEXT NOT NULL,
        expires_at INTEGER NOT NULL, used_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS participants (
        principal_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL UNIQUE,
        broker_public_key TEXT NOT NULL UNIQUE, signing_public_key TEXT NOT NULL,
        encryption_public_key TEXT NOT NULL, peer_ids TEXT NOT NULL,
        enrolled_at INTEGER NOT NULL, revoked_at INTEGER
      );`);
  }

  issue({ agentId, peers, ttlMs = TTL }, now = Date.now()) {
    if (!validId(agentId) || !Array.isArray(peers) || peers.length > 128
      || peers.some(peer => !validId(peer) || peer === agentId) || new Set(peers).size !== peers.length) {
      throw new Error('enrollment.scope-invalid');
    }
    if (!validTime(now) || !Number.isSafeInteger(ttlMs) || ttlMs < 1 || ttlMs > TTL) throw new Error('enrollment.expiry-invalid');
    if (this.db.prepare('SELECT 1 FROM participants WHERE agent_id = ?').get(agentId)) throw new Error('enrollment.identity-occupied');
    const invitation = randomBytes(32).toString('base64url');
    this.db.prepare('INSERT INTO invitations(token_hash,agent_id,peer_ids,expires_at) VALUES(?,?,?,?)')
      .run(hash(invitation), agentId, JSON.stringify(peers), now + ttlMs);
    // A bearer nonce is returned once. Only its digest is stored, never a broker seed/token.
    return { schema: 'murmur.enrollment-reference/1', invitation, agentId, expiresAt: now + ttlMs };
  }

  redeem(invitation, request, now = Date.now()) {
    if (!validTime(now) || !validId(request?.agentId) || !validPublicKey(request.signingPublicKey)
      || !validPublicKey(request.encryptionPublicKey) || typeof request.brokerPublicKey !== 'string'
      || !/^U[A-Z2-7]{55}$/.test(request.brokerPublicKey) || !(request.proof instanceof Uint8Array) || request.proof.length !== 64) {
      throw new Error('enrollment.proof-invalid');
    }
    const challenge = enrollmentChallenge(invitation, request);
    let verifier;
    try {
      verifier = nkeys.fromPublic(request.brokerPublicKey);
      if (!verifier.verify(challenge, request.proof)) throw new Error();
    } catch { throw new Error('enrollment.proof-invalid'); }
    finally { verifier?.clear(); }
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const row = this.db.prepare('SELECT * FROM invitations WHERE token_hash = ?').get(hash(invitation));
      if (!row || row.used_at !== null) throw new Error('enrollment.invitation-unavailable');
      if (row.expires_at <= now) throw new Error('enrollment.invitation-expired');
      if (row.agent_id !== request.agentId) throw new Error('enrollment.identity-mismatch');
      if (this.db.prepare('SELECT 1 FROM participants WHERE agent_id = ? OR broker_public_key = ?')
        .get(request.agentId, request.brokerPublicKey)) throw new Error('enrollment.identity-occupied');
      const principalId = randomUUID();
      this.db.prepare(`INSERT INTO participants VALUES(?,?,?,?,?,?,?,NULL)`).run(principalId,
        request.agentId, request.brokerPublicKey, request.signingPublicKey, request.encryptionPublicKey, row.peer_ids, now);
      this.db.prepare('UPDATE invitations SET used_at = ? WHERE token_hash = ?').run(now, hash(invitation));
      this.db.exec('COMMIT');
      return { principalId, agentId: request.agentId, brokerPublicKey: request.brokerPublicKey, state: 'pending-broker-apply' };
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }

  revoke(principalId, now = Date.now()) {
    if (!validTime(now)) throw new Error('enrollment.time-invalid');
    const changed = this.db.prepare('UPDATE participants SET revoked_at = ? WHERE principal_id = ? AND revoked_at IS NULL').run(now, principalId);
    if (changed.changes !== 1) throw new Error('enrollment.participant-unavailable');
    return { principalId, state: 'pending-broker-apply' };
  }

  /** Declarative config only. An operator must validate, apply and verify the observed broker state. */
  authorization() {
    const active = this.db.prepare('SELECT * FROM participants WHERE revoked_at IS NULL ORDER BY principal_id').all();
    const agentIds = new Set(active.map(row => row.agent_id));
    if (!active.length) throw new Error('enrollment.no-active-participants');
    return { users: active.map(row => {
      const peers = JSON.parse(row.peer_ids).filter(peer => agentIds.has(peer));
      return { nkey: row.broker_public_key, permissions: {
        // Empty allow-lists do NOT deny all in NATS. Use an explicit deny-all for zero peers.
        publish: peers.length ? { allow: peers.flatMap(peer => [`msg.${peer}`, `ack.${peer}`]) } : { deny: ['>'] },
        subscribe: { allow: [`msg.${row.agent_id}`, `ack.${row.agent_id}`] },
      } };
    }) };
  }
}
