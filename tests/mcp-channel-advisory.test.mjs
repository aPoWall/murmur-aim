import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import vm from "node:vm";
import * as core from "../packages/core/dist/src/index.js";
import * as security from "../packages/security/dist/src/index.js";
import { SessionLeaseStore, createNativeLeaseGate } from "../scripts/lease.mjs";

const thisFile = fileURLToPath(import.meta.url);
const sourceFile = process.env.MURMUR_ADVISORY_SOURCE ||
  fileURLToPath(new URL("../scripts/murmur-mcp-channel-server.mjs", import.meta.url));

// SourceTextModule is opt-in on Node 22. Run this test in a bounded child so
// the repository's normal node --test command requires no extra flags.
if (process.env.MURMUR_ADVISORY_VM_CHILD !== "1") {
  test("MCP advisory channel regressions", { timeout: 45000 }, () => {
    const result = spawnSync(process.execPath,
      ["--experimental-vm-modules", "--test", thisFile], {
        env: (() => { const e = { ...process.env, MURMUR_ADVISORY_VM_CHILD: "1" }; delete e.NODE_TEST_CONTEXT; return e; })(),
        encoding: "utf8", timeout: 40000, maxBuffer: 2 * 1024 * 1024,
      });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stdout + result.stderr);
  });
} else {
  async function fixture(t, { owner = null } = {}) {
    const dir = mkdtempSync(path.join(tmpdir(), "murmur-advisory-"));
    const closers = [];
    t.after(() => {
      for (const close of closers.reverse()) close();
      rmSync(dir, { recursive: true, force: true });
    });
    const leasePath = path.join(dir, "lease.db");
    const lease = new SessionLeaseStore(leasePath);
    closers.push(() => lease.close());
    if (owner) {
      lease.claimOrSkip("fixture-conversation", "receiver", owner, 600000);
      if (!owner.startsWith("native:")) {
        lease.registerSession({
          sessionId: owner, threadId: owner, agentId: "receiver", mode: "foreground",
        });
      }
    }
    const snapshot = () => ({
      owners: lease.db.prepare("SELECT * FROM channel_owner ORDER BY conversation_id, member_slot").all(),
      presence: lease.db.prepare("SELECT * FROM session_presence ORDER BY session_id").all(),
    });
    const baseline = snapshot();
    const receiver = { encryption: await security.createKeyPair(), signing: await security.createSigningKeyPair() };
    const sender = { encryption: await security.createKeyPair(), signing: await security.createSigningKeyPair() };
    const config = {
      agentId: "receiver", subject: "msg.receiver", natsUrl: "nats://fixture.invalid:4222",
      keys: receiver,
      peers: { sender: { encryption: { publicKey: sender.encryption.publicKey },
        signing: { publicKey: sender.signing.publicKey } } },
      channelRoster: { enabled: true },
    };
    writeFileSync(path.join(dir, "agent-config.json"), JSON.stringify(config), { mode: 0o600 });
    const roster = new core.ChannelRosterStore(path.join(dir, "channel-roster.db"));
    roster.createChannel({ channelId: "fixture-channel", conversationId: "fixture-conversation",
      type: "group", members: [
        { memberId: "receiver-member", agentId: "receiver" },
        { memberId: "sender-member", agentId: "sender" },
      ] });
    roster.close();
    const stdout = [], stderr = [], intervals = [], routes = [];
    const stream = { on() {} };
    const fakeProcess = {
      pid: 12345,
      env: {
        DATA_DIR: dir, CODEX_HOME: dir,
        MURMUR_STORE_PATH: path.join(dir, "murmur.db"),
        MURMUR_LEASE_DB: leasePath,
        MURMUR_LEASE_MODULE_URL: new URL("../scripts/lease.mjs", import.meta.url).href,
        MURMUR_MCP_LOG_PATH: path.join(dir, "channel.log"),
        MURMUR_MCP_SESSION_ID: "observer", CODEX_THREAD_ID: "observer",
        MURMUR_LEASE_HEARTBEAT_MS: "1",
      },
      stdin: stream,
      stdout: { ...stream, write: (s) => stdout.push(s) },
      stderr: { ...stream, write: (s) => stderr.push(s) },
      on() {},
      exit(code) { throw new Error("unexpected-exit:" + code); },
    };
    let onMessage;
    class FixtureBroker {
      async connect() {}
      async close() {}
      async subscribeWithAck(options) {
        routes.push(options);
        onMessage = options.onMessage;
      }
    }
    const track = (Base) => class extends Base {
      constructor(...args) {
        super(...args);
        closers.push(() => this.close());
      }
    };
    const context = vm.createContext({
      process: fakeProcess, Buffer, URL, console,
      setTimeout, clearTimeout,
      setInterval: (fn) => { intervals.push(fn); return { unref() {} }; },
      clearInterval() {},
    });
    const dependencies = {
      "node:fs": await import("node:fs"),
      "node:path": await import("node:path"),
      "node:os": await import("node:os"),
      "node:url": await import("node:url"),
      "node:readline": { createInterface: () => ({ on() {} }) },
      "../packages/broker-nats/dist/src/index.js": { NatsBroker: FixtureBroker },
      "../packages/core/dist/src/index.js": {
        ...core,
        SQLiteDedupeOutboxStore: track(core.SQLiteDedupeOutboxStore),
        ChannelRosterStore: track(core.ChannelRosterStore),
      },
      "../packages/security/dist/src/index.js": security,
      "./secure-state.mjs": {
        setPrivateUmask() {},
        readPrivateJson: async (p) => JSON.parse(readFileSync(p, "utf8")),
      },
      [fakeProcess.env.MURMUR_LEASE_MODULE_URL]: { SessionLeaseStore: track(SessionLeaseStore) },
    };
    const modules = new Map();
    function dependency(specifier) {
      if (!Object.hasOwn(dependencies, specifier)) throw new Error("unexpected-import:" + specifier);
      if (!modules.has(specifier)) {
        const values = dependencies[specifier];
        modules.set(specifier, new vm.SyntheticModule(Object.keys(values), function () {
          for (const [key, value] of Object.entries(values)) this.setExport(key, value);
        }, { context }));
      }
      return modules.get(specifier);
    }
    const mod = new vm.SourceTextModule(readFileSync(sourceFile, "utf8"), {
      context, identifier: pathToFileURL(sourceFile).href,
      initializeImportMeta: (meta) => { meta.url = pathToFileURL(sourceFile).href; },
      importModuleDynamically: async (specifier) => {
        const dep = dependency(specifier);
        if (dep.status === "unlinked") await dep.link(dependency);
        if (dep.status === "linked") await dep.evaluate();
        return dep;
      },
    });
    await mod.link(dependency);
    await mod.evaluate();
    // Flush subscriber microtasks; no network, sleeps or live profiles.
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(typeof onMessage, "function", stderr.join(""));
    assert.ok(routes.length > 0);
    assert.ok(routes.every((r) => r.emitDeliveryAcks === false));
    const encrypted = await security.encryptPayload("synthetic advisory", receiver.encryption.publicKey, sender.encryption.privateKey);
    async function envelope(changes = {}) {
      const env = {
        schemaVersion: "1.0", msgId: "fixture-message", conversationId: "fixture-conversation",
        senderAgentId: "sender", recipients: ["receiver"], createdAt: "2026-01-01T00:00:00Z",
        payloadCiphertext: encrypted.ciphertext, payloadNonce: encrypted.nonce,
        channelId: "fixture-channel", senderMemberId: "sender-member",
        addresseeMemberId: "receiver-member", ...changes,
      };
      env.signature = await security.signEnvelope(core.stableEnvelopePayload(env), sender.signing.privateKey);
      return env;
    }
    const notifications = () => stdout.join("").trim().split("\n").filter(Boolean)
      .map((s) => JSON.parse(s)).filter((p) => p.method === "notifications/message");
    const logs = () => stderr.join("").trim().split("\n").filter(Boolean).map((s) => JSON.parse(s));
    const unchanged = () => assert.deepEqual(snapshot(), baseline);
    return { onMessage, envelope, notifications, logs, unchanged, intervals, lease };
  }

  test("startup and heartbeat cannot advertise interactive presence", async (t) => {
    const f = await fixture(t);
    for (const heartbeat of f.intervals) heartbeat();
    f.unchanged();
    assert.equal(f.lease.hasLiveInteractiveSession("receiver", 20000), false);
    const gate = createNativeLeaseGate({ store: f.lease, agentId: "receiver" });
    assert.equal((await gate({ conversationId: "fixture-conversation" })).allow, true);
    const subscribed = f.logs().find((r) => r.msg === "Murmur MCP channel server subscribed");
    assert.equal(subscribed.deliveryReceipt, false);
  });

  for (const owner of ["native:receiver", "real-interactive-session"]) {
    test("valid advisory preserves owner and token: " + owner, async (t) => {
      const f = await fixture(t, { owner });
      await f.onMessage(await f.envelope());
      for (const heartbeat of f.intervals) heartbeat();
      f.unchanged();
      const notices = f.notifications();
      assert.equal(notices.length, 1);
      assert.equal(notices[0].params.data.text, "synthetic advisory");
      const emitted = f.logs().find((r) => r.msg === "MCP channel notification emitted");
      assert.equal(emitted.deliveryReceipt, false);
      assert.equal(emitted.ownership, "advisory-only");
    });
  }

  test("foreign recipient remains silent", async (t) => {
    const f = await fixture(t);
    await f.onMessage(await f.envelope({ recipients: ["someone-else"] }));
    assert.equal(f.notifications().length, 0);
    f.unchanged();
  });

  test("unknown sender is rejected", async (t) => {
    const f = await fixture(t);
    await assert.rejects(f.onMessage(await f.envelope({ senderAgentId: "unknown" })), /unknown-sender/);
    assert.equal(f.notifications().length, 0);
    f.unchanged();
  });

  test("invalid signature is rejected", async (t) => {
    const f = await fixture(t);
    const env = await f.envelope();
    env.signature = Buffer.alloc(64).toString("base64");
    await assert.rejects(f.onMessage(env), /signature-invalid/);
    assert.equal(f.notifications().length, 0);
    f.unchanged();
  });

  test("validly signed corrupt ciphertext cannot notify", async (t) => {
    const f = await fixture(t);
    await assert.rejects(f.onMessage(await f.envelope({
      payloadCiphertext: Buffer.alloc(32).toString("base64"),
    })));
    assert.equal(f.notifications().length, 0);
    f.unchanged();
  });

  test("roster suppresses messages addressed to another member", async (t) => {
    const f = await fixture(t);
    await f.onMessage(await f.envelope({ addresseeMemberId: "sender-member" }));
    assert.equal(f.notifications().length, 0);
    assert.ok(f.logs().some((r) => r.msg === "MCP channel notification suppressed by addressing"));
    f.unchanged();
  });
}
