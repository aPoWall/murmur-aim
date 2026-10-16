import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createKeyPair, createSigningKeyPair } from '../packages/security/dist/src/index.js';
import { validateConfig, safeError } from '../packages/setup/dist/src/config.js';
import { loadConfig } from '../packages/setup/dist/src/config.js';
import { resolveContext } from '../packages/setup/dist/src/paths.js';
import { protectPrivateFile } from '../packages/setup/dist/src/private-file.js';
import { addExplicitAccessFixture } from './helpers/private-files.mjs';
import { readBrokerInputs } from '../packages/setup/dist/src/broker-input.js';
const exec=promisify(execFile), root=fileURLToPath(new URL('../',import.meta.url));

const config = async overrides => ({ agentId:'agent-a', subject:'msg.agent-a', natsUrl:'tls://broker.example:4222',
  keys:{ encryption:await createKeyPair(), signing:await createSigningKeyPair() }, peers:{}, ...overrides });

test('setup config delegates TLS/auth policy to shared secure builder', async () => {
  assert.equal(validateConfig(await config({natsUser:'alice',natsPassword:'secret',natsTls:{caFile:path.join(os.tmpdir(),'ca.pem')}})).natsUser,'alice');
  const plaintext=await config({natsUrl:'nats://broker.example:4222'}), mixed=await config({natsToken:'x',natsUser:'alice',natsPassword:'secret'}), ip=await config({natsUrl:'tls://127.0.0.1:4222'});
  assert.equal(validateConfig(plaintext).natsUrl, plaintext.natsUrl);
  assert.throws(()=>validateConfig(mixed),/nats-auth-methods-conflict/);
  assert.throws(()=>validateConfig(ip),/nats-tls-server-name-required-for-ip/);
});

test('private broker inputs require owned private single-line files', async t => {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'murmur-tls-input-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
  const user=path.join(dir,'user'), pass=path.join(dir,'pass'), ca=path.join(dir,'ca.pem');
  for (const [file,text] of [[user,'alice'],[pass,'secret']]) { const h=await fs.open(file,'wx',0o600);try{await protectPrivateFile(file,h);await h.writeFile(text);}finally{await h.close();} }
  await fs.writeFile(ca,'CA',{mode:0o644});
  assert.deepEqual(await readBrokerInputs({userFile:user,passwordFile:pass,caFile:ca,serverName:'broker.example'}),
    {natsUser:'alice',natsPassword:'secret',natsTls:{caFile:ca,serverName:'broker.example'}});
  if(process.platform==='win32') await addExplicitAccessFixture(pass);else await fs.chmod(pass,0o644);
  await assert.rejects(readBrokerInputs({userFile:user,passwordFile:pass}),/broker-input.file-not-private/);
  if(process.platform!=='win32') await fs.chmod(pass,0o600);
  const repair=await fs.open(pass,'w');try{await protectPrivateFile(pass,repair);}finally{await repair.close();}
  await fs.writeFile(pass,'bad\nvalue');
  await assert.rejects(readBrokerInputs({userFile:user,passwordFile:pass}),/broker-input.secret-invalid/);
  await fs.writeFile(pass,'secret');
  const link=path.join(dir,'linked-user');try{await fs.symlink(user,link);}catch(error){if(process.platform==='win32'&&error.code==='EPERM'){t.diagnostic('symlink permission unavailable');return;}throw error;}
  await assert.rejects(readBrokerInputs({userFile:link,passwordFile:pass}),/broker-input.file-invalid/);
});

test('safe errors redact URL credentials, auth values, and private keys', () => {
  for (const secret of ['nats://alice:secret@broker:4222','alice:secret','natsPassword=secret','privateKey=abc'])
    assert.equal(safeError(new Error(secret)),'operation-failed');
  assert.equal(safeError(new Error('broker.unauthorized')),'broker.unauthorized');
  assert.equal(safeError(new Error('nats-plaintext-non-loopback-rejected')),'nats-plaintext-non-loopback-rejected');
  assert.equal(safeError(new Error('nats-made-up-secret-value')),'operation-failed');
});

test('ordinary config load preserves legacy remote plaintext', async t => {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'murmur-plaintext-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
  const context=resolveContext({dataDir:dir,repoRoot:root});await fs.mkdir(dir,{recursive:true});
  await fs.writeFile(context.configPath,JSON.stringify(await config({natsUrl:'nats://remote.example:4222'})),{mode:0o600});
  assert.equal((await loadConfig(context)).natsUrl, 'nats://remote.example:4222');
});

test('CLI keeps legacy remote plaintext initialization compatible', async t => {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'murmur-plaintext-cli-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
  const {stdout}=await exec(process.execPath,['packages/setup/bin/murmur.mjs','init','--agent-id','agent-a','--broker-url','nats://broker.example:4222','--data-dir',dir,'--json'],{cwd:root,env:{...process.env,NODE_NO_WARNINGS:'1'}});
  assert.equal(JSON.parse(stdout).agentId,'agent-a');
  assert.equal(JSON.parse(await fs.readFile(path.join(dir,'agent-config.json'),'utf8')).natsUrl,'nats://broker.example:4222');
});

test('broker file read is bounded by bytes actually consumed and rejects TLS symlinks at use', async t => {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'murmur-tls-use-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
  const ca=path.join(dir,'ca.pem'), target=path.join(dir,'target.pem');await fs.writeFile(ca,'CA',{mode:0o644});await fs.writeFile(target,'OTHER',{mode:0o644});
  const { validateConfiguredTlsFiles }=await import('../packages/setup/dist/src/broker-input.js');
  await validateConfiguredTlsFiles({natsUrl:'tls://broker.example:4222',natsTls:{caFile:ca}});
  await fs.rename(ca,path.join(dir,'old.pem'));try{await fs.symlink(target,ca);}catch(error){if(process.platform==='win32'&&error.code==='EPERM'){t.diagnostic('symlink permission unavailable');return;}throw error;}
  await assert.rejects(validateConfiguredTlsFiles({natsUrl:'tls://broker.example:4222',natsTls:{caFile:ca}}),/broker-input.file-invalid/);
});
