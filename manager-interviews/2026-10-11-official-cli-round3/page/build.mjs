// A local page: for each case, 甲 and 乙 under draft v0 (round 2) and v1 (round 3) side by side,
// with the two before/after reviews. Usage: node build.mjs
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const here = import.meta.dirname;
const dir = join(here, '..', 'review');
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const LOCAL_TIME = { '01': '10-01 16:28', '02': '10-01 21:20', '03': '10-03 23:42', '04': '10-04 00:36', '05': '10-04 15:03', '06': '10-09 22:01', '07': '10-09 23:13', '08': '10-10 01:29' };

function sections(text) {
  const out = {};
  let name = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('# ')) { out.title = line.slice(2).replace(/^case-\d+：/, '').trim(); continue; }
    if (line.startsWith('## ')) { name = line.slice(3).trim(); out[name] = []; continue; }
    if (name) out[name].push(line);
  }
  for (const k of Object.keys(out)) if (Array.isArray(out[k])) out[k] = out[k].join('\n').trim();
  return out;
}

const ids = readdirSync(join(dir, 'cases')).filter((f) => /^case-\d+\.md$/.test(f)).map((f) => f.slice(5, -3)).sort();
const cases = ids.map((id) => {
  const s = sections(read(join(dir, 'cases', `case-${id}.md`)));
  const interviews = {};
  for (const n of [1, 3]) {
    const get = (v, who) => read(join(dir, v, `i${n}-case-${id}-${who}.md`));
    const a = { '甲': { v0: get('v0', '甲'), v1: get('v1', '甲') }, '乙': { v0: get('v0', '乙'), v1: get('v1', '乙') } };
    if (a['甲'].v1 || a['乙'].v1) interviews[n] = a;
  }
  return { id, title: s.title, time: LOCAL_TIME[id], cut: s['截断处的用户消息'], history: s['历史'], truth: s['之后实际发生了什么（不给候选模型看）'] ?? s['之后实际发生了什么'], interviews };
});
const data = {
  cases,
  reviews: { claude: read(join(dir, 'review-claude.md')), codex: read(join(dir, 'review-codex.md')) },
  drafts: { v0: read(join(dir, 'manager-draft-v0.md')), v1: read(join(dir, 'manager-draft-v1.md')) },
};
const json = JSON.stringify(data).replaceAll('</', '<\\/').replaceAll('\u2028', '\\u2028').replaceAll('\u2029', '\\u2029');
const html = read(join(here, 'template.html')).replace('/*DATA*/null', json);
writeFileSync(join(here, 'angela-v0-v1.html'), html);
console.log(`${cases.length} cases, ${html.length} chars`);
