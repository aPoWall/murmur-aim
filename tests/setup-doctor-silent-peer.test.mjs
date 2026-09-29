import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateSilentPeer } from '../packages/setup/dist/src/doctor.js';

// A peer whose daemon predates the probe responder (2.11.0) never answers, so the timeout read
// exactly like a dead channel and cost a pilot user a near-rollback of a working setup (#292).
const now = Date.parse('2026-09-29T12:00:00.000Z');
const ago = ms => new Date(now - ms).toISOString();

test('recent signed traffic from the peer turns a silent probe into a warning that names the evidence', () => {
  const warn = evaluateSilentPeer('agent-jarvis', ago(60_000), now);
  assert.equal(warn.state, 'warn');
  assert.equal(warn.reason, 'roundtrip.peer-silent');
  assert.match(warn.detail, /agent-jarvis/);
  assert.match(warn.detail, /2026-09-29T11:59:00/, 'the time of the evidence is named, not just its existence');
  assert.match(warn.fixHint, /older than 2\.11\.0/);
  assert.match(warn.fixHint, /murmur --version/);
});

test('without recent traffic the timeout stays a failure', () => {
  // Null tells the caller to let the original error through: nothing here proves the transport.
  assert.equal(evaluateSilentPeer('agent-jarvis', null, now), null);
  assert.equal(evaluateSilentPeer('agent-jarvis', ago(3_600_000), now), null, 'exactly at the window is already too old');
  assert.equal(evaluateSilentPeer('agent-jarvis', ago(86_400_000), now), null);
});

test('an unusable or future timestamp is not evidence', () => {
  for (const value of ['', '   ', 'вчера', '2026-13-45T99:00:00Z', 'NaN']) {
    assert.equal(evaluateSilentPeer('agent-jarvis', value, now), null, value || '(empty)');
  }
  // A row dated ahead of this clock proves nothing and must not buy a softer verdict.
  assert.equal(evaluateSilentPeer('agent-jarvis', ago(-60_000), now), null);
});

test('the boundary is the hour before now', () => {
  assert.ok(evaluateSilentPeer('p', ago(3_599_999), now));
  assert.equal(evaluateSilentPeer('p', ago(3_600_001), now), null);
});
