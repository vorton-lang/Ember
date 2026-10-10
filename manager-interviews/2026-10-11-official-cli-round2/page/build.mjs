// Builds the side-by-side page from the case files and round-2 answers: template.html with the
// data embedded as JSON. Usage: node build.mjs
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const here = import.meta.dirname;
const root = join(here, '..');
const read = (p) => readFileSync(p, 'utf8');

const LOCAL_TIME = {
  '01': '10-01 16:28', '02': '10-01 21:20', '03': '10-03 23:42', '04': '10-04 00:36',
  '05': '10-04 15:03', '06': '10-09 22:01', '07': '10-09 23:13', '08': '10-10 01:29',
};
const FIRST = ['04', '05', '07', '08'];

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

const answer = (interview, id, label) => {
  try {
    return read(join(root, 'answers', `i${interview}-case-${id}-${label}.md`)).replace(/^<!--.*?-->\n/, '').trim();
  } catch {
    return null;
  }
};

const ids = readdirSync(join(root, 'cases')).filter((f) => /^case-\d+\.md$/.test(f)).map((f) => f.slice(5, -3)).sort();
const order = [...FIRST, ...ids.filter((id) => !FIRST.includes(id))];
const cases = order.map((id) => {
  const s = sections(read(join(root, 'cases', `case-${id}.md`)));
  const interviews = {};
  for (const n of [1, 3]) {
    const a = { X: answer(n, id, 'X'), Y: answer(n, id, 'Y'), Z: answer(n, id, 'Z') };
    if (a.X || a.Y || a.Z) interviews[n] = a;
  }
  return {
    id, first: FIRST.includes(id), title: s.title, time: LOCAL_TIME[id],
    history: s['历史'], cut: s['截断处的用户消息'], truth: s['之后实际发生了什么（不给候选模型看）'] ?? s['之后实际发生了什么'],
    why: s['选这个点的理由'], interviews,
  };
});
const key = JSON.parse(read(join(root, 'answers', 'key.json')));
const data = { cases, key, draft: read(join(root, 'manager-draft.md')).replaceAll('{name}', 'Angela') };
const json = JSON.stringify(data).replaceAll('</', '<\\/').replaceAll('\u2028', '\\u2028').replaceAll('\u2029', '\\u2029');
const html = read(join(here, 'template.html')).replace('/*DATA*/null', json);
writeFileSync(join(here, 'angela-interviews.html'), html);
console.log(`${cases.length} cases, ${html.length} chars`);
