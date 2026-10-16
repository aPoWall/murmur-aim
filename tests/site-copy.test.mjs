import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { readDictionary } from '../scripts/build-site-ru.mjs';

const html = readFileSync(new URL('../site/index.html', import.meta.url), 'utf8');
const I18N = readDictionary(html);
const start = html.indexOf("document.querySelectorAll('[data-copy-target]')");
assert.ok(start > 0);
const handler = html.slice(start, html.indexOf('\n\n</script>', start));

function fixture(language, clipboard, fallback) {
  const writes = [], timers = new Map(); let serial = 0, removed = 0;
  const buttons = ['prompt', 'desktop-prompt'].map(copyTarget => ({
    dataset: { copyTarget }, textContent: I18N[language].copy,
    addEventListener(_event, fn) { this.click = fn; }, focus() {},
  }));
  const texts = { prompt: language === 'ru' ? I18N.ru.prompt : 'terminal installation', 'desktop-prompt': I18N[language].desktopPrompt };
  vm.runInNewContext(handler, {
    I18N, language, navigator: { clipboard: clipboard ? { async writeText(text) { writes.push(text); } } : undefined },
    document: {
      querySelectorAll: () => buttons,
      getElementById: id => ({ textContent: texts[id] }),
      createElement: () => ({ select() {}, remove() { removed++; } }),
      body: { appendChild() {} }, execCommand: fallback,
    },
    setTimeout(fn) { timers.set(++serial, fn); return serial; }, clearTimeout(id) { timers.delete(id); },
  });
  return { buttons, writes, texts, timers, removed: () => removed };
}

for (const language of ['en', 'ru']) {
  test(`copy buttons use their own ${language} prompt and feedback timers`, async () => {
    const f = fixture(language, true, () => { throw new Error('unused fallback'); });
    await f.buttons[0].click(); await f.buttons[1].click();
    assert.deepEqual(f.writes, [f.texts.prompt, f.texts['desktop-prompt']]);
    assert.ok(f.buttons.every(b => b.textContent === I18N[language].copied));
    assert.equal(f.timers.size, 2);
    for (const reset of f.timers.values()) reset();
    assert.ok(f.buttons.every(b => b.textContent === I18N[language].copy));
  });
  for (const result of [true, false, 'throw']) {
    test(`clipboard fallback ${result} reports the actual result in ${language}`, async () => {
      const f = fixture(language, false, () => { if (result === 'throw') throw new Error('denied'); return result; });
      await f.buttons[1].click();
      assert.equal(f.buttons[1].textContent, I18N[language][result === true ? 'copied' : 'copyFailed']);
      assert.equal(f.buttons[0].textContent, I18N[language].copy);
      assert.equal(f.removed(), 1, 'temporary clipboard element is always removed');
    });
  }
}
