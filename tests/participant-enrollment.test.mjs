import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { connect, nkeys, nkeyAuthenticator, StringCodec } from 'nats';
import { EnrollmentReference, enrollmentChallenge } from '../examples/participant-enrollment/reference.mjs';

const now = 1_792_150_000_000;
function request(invitation, agentId, key = nkeys.createUser()) {
  const fields = { agentId, brokerPublicKey: key.getPublicKey(),
    signingPublicKey: Buffer.alloc(32, 1).toString('base64'), encryptionPublicKey: Buffer.alloc(32, 2).toString('base64') };
  return { key, request: { ...fields, proof: key.sign(enrollmentChallenge(invitation, fields)) } };
}
function fixture(t) {
  const db = new DatabaseSync(':memory:'); t.after(() => db.close());
  return { db, registry: new EnrollmentReference(db) };
}

test('enrollment binds identity and broker proof; only a digest is stored; consumption is durable', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-enrollment-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const file = path.join(root, 'registry.db'); await fs.writeFile(file, '', { mode: 0o600 });
  let db = new DatabaseSync(file); let registry = new EnrollmentReference(db);
  const invite = registry.issue({ agentId: 'alice', peers: ['host'] }, now), client = request(invite.invitation, 'alice');
  t.after(() => client.key.clear());
  assert.throws(() => registry.redeem(invite.invitation, { ...client.request, agentId: 'bob' }, now), /proof-invalid/);
  const wrong = request(invite.invitation, 'bob'); t.after(() => wrong.key.clear());
  assert.throws(() => registry.redeem(invite.invitation, wrong.request, now), /identity-mismatch/);
  const enrolled = registry.redeem(invite.invitation, client.request, now);
  assert.equal(enrolled.state, 'pending-broker-apply');
  const rows = JSON.stringify(db.prepare('SELECT * FROM invitations').all());
  assert.equal(rows.includes(invite.invitation), false);
  assert.equal(JSON.stringify(db.prepare('SELECT * FROM participants').all()).includes(Buffer.from(client.key.getSeed()).toString()), false);
  db.close(); db = new DatabaseSync(file); t.after(() => db.close()); registry = new EnrollmentReference(db);
  assert.throws(() => registry.redeem(invite.invitation, client.request, now + 1), /invitation-unavailable/);
  assert.throws(() => registry.issue({ agentId: 'alice', peers: [] }, now), /identity-occupied/);
  registry.revoke(enrolled.principalId, now + 2);
  assert.throws(() => registry.issue({ agentId: 'alice', peers: [] }, now + 3), /identity-occupied/);
  assert.throws(() => registry.authorization(), /no-active-participants/);
});

test('expired enrollment, wildcard identities, wrong proofs and reused broker keys are refused', t => {
  const { registry } = fixture(t);
  for (const bad of ['*', '>', 'alice.admin', '$SYS', '']) {
    assert.throws(() => registry.issue({ agentId: bad, peers: [] }, now), /scope-invalid/);
    assert.throws(() => registry.issue({ agentId: 'alice', peers: [bad] }, now), /scope-invalid/);
  }
  assert.throws(() => registry.issue({ agentId: 'alice', peers: [], ttlMs: 900001 }, now), /expiry-invalid/);
  const expired = registry.issue({ agentId: 'expired', peers: [], ttlMs: 1 }, now), old = request(expired.invitation, 'expired');
  t.after(() => old.key.clear());
  assert.throws(() => registry.redeem(expired.invitation, old.request, now + 1), /invitation-expired/);
  const invite = registry.issue({ agentId: 'alice', peers: [] }, now), client = request(invite.invitation, 'alice');
  t.after(() => client.key.clear());
  assert.throws(() => registry.redeem(invite.invitation, { ...client.request, proof: new Uint8Array(64) }, now), /proof-invalid/);
  registry.redeem(invite.invitation, client.request, now);
  assert.deepEqual(registry.authorization().users[0].permissions.publish, { deny: ['>'] });
  const other = registry.issue({ agentId: 'bob', peers: [] }, now), reused = request(other.invitation, 'bob', client.key);
  assert.throws(() => registry.redeem(other.invitation, reused.request, now), /identity-occupied/);
});

async function bounded(promise, label, milliseconds = 4000) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`timeout:${label}`)), milliseconds); })]); }
  finally { clearTimeout(timer); }
}

test('real isolated NATS: individual revocation closes only that principal, ACLs reject foreign subjects', { timeout: 30000 }, async t => {
  if (process.platform === 'win32') { t.skip('POSIX config-reload signal proof; unit contract tests run on Windows'); return; }
  let version;
  try { version = execFileSync('nats-server', ['--version'], { encoding: 'utf8' }).trim(); }
  catch { if (process.env.MURMUR_REQUIRE_ENROLLMENT_BROKER === '1') throw new Error('isolated-nats-server-required'); t.skip('isolated nats-server unavailable'); return; }
  const { registry } = fixture(t), root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-enrollment-broker-'));
  const clients = [], keys = [];
  t.after(async () => { for (const client of clients) await client.close(); keys.forEach(key => key.clear()); await fs.rm(root, { recursive: true, force: true }); });
  function enroll(agentId, peers) {
    const invite = registry.issue({ agentId, peers }, now), client = request(invite.invitation, agentId); keys.push(client.key);
    return { ...registry.redeem(invite.invitation, client.request, now), key: client.key };
  }
  const alice = enroll('alice', ['host']), bob = enroll('bob', ['host']), host = enroll('host', ['alice', 'bob']);
  const listener = createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
  const conf = path.join(root, 'nats.conf');
  const save = () => fs.writeFile(conf, JSON.stringify({ host: '127.0.0.1', port, authorization: registry.authorization() }), { mode: 0o600 });
  await save();
  const server = spawn('nats-server', ['-c', conf], { stdio: ['ignore', 'ignore', 'pipe'] });
  // This contains only generated fixture principals. Never enable protocol tracing with real credentials.
  let serverLog = ''; server.stderr.on('data', chunk => { serverLog += chunk; });
  t.after(async () => { if (server.exitCode === null) { server.kill('SIGTERM'); await once(server, 'exit'); } });
  const options = principal => ({ servers: `nats://127.0.0.1:${port}`, authenticator: nkeyAuthenticator(principal.key.getSeed()),
    reconnect: false, timeout: 500, name: `enrollment-test-${principal.agentId}` });
  let h;
  for (let attempt = 0; attempt < 100 && !h; attempt++) {
    try { h = await connect(options(host)); }
    catch (error) { if (server.exitCode !== null || attempt === 99) throw error; await delay(20); }
  }
  const a = await connect(options(alice)), b = await connect(options(bob)); clients.push(h, a, b);
  const sc = StringCodec(), messages = [], bobMessages = [];
  const hostInbox = h.subscribe('msg.host', { callback: (err, msg) => { assert.ifError(err); messages.push(sc.decode(msg.data)); } });
  const bobInbox = b.subscribe('msg.bob', { callback: (err, msg) => { assert.ifError(err); bobMessages.push(sc.decode(msg.data)); } });
  await Promise.all([h.flush(), b.flush()]); a.publish('msg.host', sc.encode('alice-before')); b.publish('msg.host', sc.encode('bob-before'));
  await Promise.all([a.flush(), b.flush()]);
  for (let i = 0; i < 100 && messages.length < 2; i++) await delay(10);
  assert.deepEqual(new Set(messages), new Set(['alice-before', 'bob-before']));
  const bobClientId = b.info.client_id, bobEvents = [];
  const bobStatus = b.status(), aliceStatus = a.status();
  t.after(() => { bobStatus.stop(); aliceStatus.stop(); });
  const consumeBobStatus = (async () => { for await (const event of bobStatus) bobEvents.push(event.type); })();
  const errors = [];
  const statuses = (async () => { for await (const event of aliceStatus) if (event.type === 'error') errors.push(event.data); })();
  const denied = ['msg.bob', 'msg.>', '$JS.API.INFO', '$SYS.REQ.SERVER.PING'];
  for (const subject of denied) a.publish(subject, sc.encode('must-not-arrive'));
  const rejectedSubscription = new Promise(resolve => { a.subscribe('msg.bob', { callback: err => { if (err) resolve(err); } }); });
  await a.flush();
  assert.match(String(await bounded(rejectedSubscription, 'foreign-subscribe-refusal')), /permission/i);
  for (let i = 0; i < 100 && errors.length < denied.length; i++) await delay(10);
  assert.ok(errors.length >= denied.length, 'broker reported each unauthorized publish');
  assert.ok(messages.every(message => !message.includes('must-not-arrive')));
  assert.deepEqual(bobMessages, [], 'foreign publish was not delivered to the other participant');
  const revoked = registry.revoke(alice.principalId, now + 1); assert.equal(revoked.state, 'pending-broker-apply');
  const closed = a.closed(); await save(); server.kill('SIGHUP');
  // NATS 2.10 closes the removed user's existing socket without a final auth error.
  // The closed socket plus a fresh authentication refusal prove the two separate effects.
  await bounded(closed, 'revoked-client-disconnect');
  assert.equal(a.isClosed(), true);
  await assert.rejects(connect(options(alice)), /authorization/i);
  b.publish('msg.host', sc.encode('bob-after')); await b.flush();
  for (let i = 0; i < 100 && !messages.includes('bob-after'); i++) await delay(10);
  assert.ok(messages.includes('bob-after')); assert.equal(b.info.client_id, bobClientId);
  assert.equal(b.isClosed(), false); assert.equal(bobEvents.some(event => ['disconnect', 'reconnect'].includes(event)), false);
  h.publish('msg.bob', sc.encode('reply-after')); await h.flush();
  for (let i = 0; i < 100 && !bobMessages.length; i++) await delay(10);
  assert.deepEqual(bobMessages, ['reply-after']);
  hostInbox.unsubscribe(); bobInbox.unsubscribe(); await a.close(); await b.close();
  bobStatus.stop(); aliceStatus.stop(); await Promise.all([statuses, consumeBobStatus]);
  assert.match(serverLog, /Reloaded server configuration/);
  t.diagnostic(`${version}; alice live connection revoked/reconnect denied; bob same connection retained; expired/reused invite covered separately`);
});
