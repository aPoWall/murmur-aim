#!/usr/bin/env node
import { appendFileSync } from "node:fs";
import path from "node:path";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { NatsBroker } from "../packages/broker-nats/dist/src/index.js";
import { SQLiteDedupeOutboxStore, ChannelRosterStore, channelSubjectRoutes, stableEnvelopePayload } from "../packages/core/dist/src/index.js";
import {
  decryptPayload,
  verifyEnvelopeSignature,
} from "../packages/security/dist/src/index.js";
import { readPrivateJson, setPrivateUmask } from "./secure-state.mjs";

setPrivateUmask();

const defaultCodexHome = process.env.CODEX_HOME || path.join(homedir(), ".codex");
const logPath =
  process.env.MURMUR_MCP_LOG_PATH || path.join(defaultCodexHome, "mcp-channel-server", "channel.log");

const log = (level, msg, data = {}) => {
  const line = `${JSON.stringify({ ts: new Date().toISOString(), level, msg, ...data })}\n`;
  process.stderr.write(line);
  try {
    appendFileSync(logPath, line);
  } catch {
    // Keep the MCP server alive even if diagnostic file logging is unavailable.
  }
};

const send = (payload) => {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
};

const ok = (id, result) => {
  if (id === undefined) return;
  send({ jsonrpc: "2.0", id, result });
};

const fail = (id, message) => {
  if (id === undefined) return;
  send({ jsonrpc: "2.0", id, error: { code: -32000, message } });
};

const envFlag = (name, defaultValue) => {
  const value = process.env[name];
  if (value === undefined) return defaultValue;
  return !["0", "false", "no", "off"].includes(value.trim().toLowerCase());
};

const dataDir = process.env.DATA_DIR || ".data";
const configPath = path.join(dataDir, "agent-config.json");
const config = await readPrivateJson(configPath);
const dbPath = process.env.MURMUR_STORE_PATH ?? path.join(dataDir, "murmur.db");
const consumerId = process.env.MURMUR_MCP_CONSUMER_ID || `${config.agentId}-mcp-channel-${process.pid}`;
const emitToSession = envFlag("MURMUR_MCP_TO_SESSION", true);
const textPrefix = process.env.MURMUR_MCP_TEXT_PREFIX || "";

const broker = new NatsBroker({ url: config.natsUrl, token: config.natsToken });
const dedupe = new SQLiteDedupeOutboxStore(dbPath);
const roster = config.channelRoster?.enabled
  ? new ChannelRosterStore(config.channelRoster.path || process.env.MURMUR_CHANNEL_ROSTER_PATH || path.join(dataDir, "channel-roster.db")) : null;
const subjectRoutes = channelSubjectRoutes(config.subject, consumerId, config.subjectScoping);
if (subjectRoutes.length > 1 && !roster) throw new Error("subject-scoping-requires-roster");

// MCP logging notifications do not acknowledge acceptance by an agent turn.
// This observer must not advertise interactive presence or own wake delivery.
const emitChannelNotification = ({ from, text, msgId, conversationId, createdAt }) => {
  const data = {
    text: `${textPrefix}${text}`,
    msgId,
    source: from,
    conversationId,
    createdAt,
  };
  if (emitToSession) {
    data.toSession = true;
  }
  send({
    jsonrpc: "2.0",
    method: "notifications/message",
    params: {
      level: "info",
      logger: "murmur-channel",
      data,
    },
  });
};

const onMessage = async (envelope) => {
  if (!envelope.recipients.includes(config.agentId)) {
    log("warn", "Ignoring message not addressed to this agent", {
      msgId: envelope.msgId,
      sender: envelope.senderAgentId,
      recipients: envelope.recipients,
    });
    return;
  }

  const peer = config.peers[envelope.senderAgentId];
  if (!peer) {
    throw new Error(`unknown-sender:${envelope.senderAgentId}`);
  }

  const valid = await verifyEnvelopeSignature(
    stableEnvelopePayload(envelope),
    envelope.signature,
    peer.signing.publicKey,
  );
  if (!valid) {
    throw new Error(`signature-invalid:${envelope.senderAgentId}`);
  }

  const plaintext = await decryptPayload(
    {
      ciphertext: envelope.payloadCiphertext,
      nonce: envelope.payloadNonce,
      senderPublicKey: peer.encryption.publicKey,
    },
    config.keys.encryption.privateKey,
  );

  const addressing = roster?.evaluateAddressing({ channelId: envelope.channelId,
    selfAgentId: config.agentId, senderAgentId: envelope.senderAgentId,
    senderMemberId: envelope.senderMemberId, addresseeMemberId: envelope.addresseeMemberId });
  if (addressing && !addressing.allowWake) {
    log("info", "MCP channel notification suppressed by addressing", { msgId: envelope.msgId, reason: addressing.reason });
    return;
  }
  emitChannelNotification({
    from: envelope.senderAgentId,
    text: plaintext,
    msgId: envelope.msgId,
    conversationId: envelope.conversationId,
    createdAt: envelope.createdAt,
  });

  log("info", "MCP channel notification emitted", {
    msgId: envelope.msgId,
    from: envelope.senderAgentId,
    conversationId: envelope.conversationId,
    toSession: emitToSession,
    textLen: plaintext.length,
    deliveryReceipt: false,
    ownership: "advisory-only",
  });
};

let running = true;

const startSubscriber = async () => {
  await broker.connect();
  for (const route of subjectRoutes) {
    await broker.subscribeWithAck({ ...route, consumerId, dedupe, onMessage, emitDeliveryAcks: false });
  }
  log("info", "Murmur MCP channel server subscribed", {
    agentId: config.agentId,
    subject: config.subject,
    subjects: subjectRoutes.map((route) => route.subject),
    consumerId,
    dbPath,
    deliveryReceipt: false,
    ownership: "advisory-only",
    toSession: emitToSession,
  });
};

const shutdown = async (signal) => {
  if (!running) return;
  running = false;
  log("info", "Shutdown signal received", { signal });
  const forceExit = setTimeout(() => {
    log("warn", "Forced shutdown after broker close timeout", { signal });
    process.exit(0);
  }, 1500);
  forceExit.unref?.();
  try {
    await broker.close();
    roster?.close();
  } catch (err) {
    log("error", "Broker close error", { error: err instanceof Error ? err.message : String(err) });
  } finally {
    clearTimeout(forceExit);
  }
  process.exit(0);
};

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
process.stdin.on("end", () => void shutdown("stdin-end"));
process.stdin.on("close", () => void shutdown("stdin-close"));
process.stdout.on("error", (err) => {
  const code = err && typeof err === "object" && "code" in err ? err.code : undefined;
  if (code === "EPIPE") void shutdown("stdout-epipe");
});

void startSubscriber().catch((err) => {
  log("fatal", "Murmur MCP channel server failed", {
    error: err instanceof Error ? err.message : String(err),
  });
  process.exit(1);
});

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("close", () => void shutdown("readline-close"));

rl.on("line", (line) => {
  if (!line.trim()) return;

  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return;
  }

  try {
    if (req.method === "initialize") {
      ok(req.id, {
        protocolVersion: "2024-11-05",
        serverInfo: { name: "murmur-v2-mcp-channel", version: "0.1.0" },
        capabilities: { tools: {} },
      });
      return;
    }

    if (req.method === "tools/list") {
      ok(req.id, { tools: [] });
      return;
    }

    if (req.method === "notifications/initialized") return;

    fail(req.id, `unsupported method: ${req.method}`);
  } catch (err) {
    fail(req.id, err instanceof Error ? err.message : "request failed");
  }
});
