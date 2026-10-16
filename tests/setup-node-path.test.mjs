import test from 'node:test';
import assert from 'node:assert/strict';
import { stableNodeExecutable, resolveContext } from '../packages/setup/dist/src/paths.js';

test('Homebrew Node persists a verified stable executable, including pinned formulae', () => {
  for (const prefix of ['/opt/homebrew', '/usr/local']) {
    const current = `${prefix}/Cellar/node/25.9.0_3/bin/node`;
    assert.equal(stableNodeExecutable(current, 'darwin', file => {
      assert.equal(file, `${prefix}/bin/node`); return current;
    }), `${prefix}/bin/node`);
    const pinned = `${prefix}/Cellar/node@22/22.22.0/bin/node`;
    assert.equal(stableNodeExecutable(pinned, 'darwin', file => {
      assert.equal(file, `${prefix}/opt/node@22/bin/node`); return pinned;
    }), `${prefix}/opt/node@22/bin/node`);
  }
});

test('absent, non-executable or different Node aliases never silently switch runtime', () => {
  const current = '/opt/homebrew/Cellar/node/25.9.0_3/bin/node';
  assert.equal(stableNodeExecutable(current, 'darwin', () => { throw new Error('missing'); }), current);
  assert.equal(stableNodeExecutable(current, 'darwin', () => '/other/node'), current);
  assert.equal(stableNodeExecutable(current, 'darwin', file => file.includes('/opt/node/') ? current : '/other/node'), '/opt/homebrew/opt/node/bin/node');
  assert.equal(stableNodeExecutable(current, 'linux', () => { throw new Error('must not inspect'); }), current);
  assert.equal(stableNodeExecutable('/custom/node', 'darwin', () => { throw new Error('must not inspect'); }), '/custom/node');
  assert.equal(resolveContext({ platform: 'darwin', home: '/Users/test', repoRoot: '/runtime', dataDir: '/Users/test/murmur', nodePath: current, env: {} }).nodePath, current,
    'an explicit caller-selected executable is preserved');
});
