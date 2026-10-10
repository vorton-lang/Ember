// Lays out the before/after material for the review under blind labels (甲 = round 2 Y / round 3
// P; 乙 = round 2 Z / round 3 Q), and bundles it into one text for a reviewer without file access.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';

const here = import.meta.dirname;
const r2 = join(here, '..', 'angela2');
const dir = join(here, 'review');
for (const d of ['v0', 'v1', 'cases']) mkdirSync(join(dir, d), { recursive: true });
copyFileSync(join(r2, 'manager-draft.md'), join(dir, 'manager-draft-v0.md'));
copyFileSync(join(here, 'manager-draft.md'), join(dir, 'manager-draft-v1.md'));
copyFileSync(join(here, 'review-prompt.md'), join(dir, 'review-prompt.md'));
for (const f of readdirSync(join(here, 'cases'))) copyFileSync(join(here, 'cases', f), join(dir, 'cases', f));

const strip = (t) => t.replace(/^<!--.*?-->\n/, '');
const pairs = [[r2, 'v0', { Y: '甲', Z: '乙' }], [here, 'v1', { P: '甲', Q: '乙' }]];
for (const [root, v, map] of pairs) {
  for (const f of readdirSync(join(root, 'answers')).filter((f) => /^i[13]-case-\d+-[A-Z]\.md$/.test(f))) {
    const label = map[f.slice(-4, -3)];
    if (!label) continue;
    writeFileSync(join(dir, v, f.replace(/-[A-Z]\.md$/, `-${label}.md`)), strip(readFileSync(join(root, 'answers', f), 'utf8')));
  }
}

const read = (p) => readFileSync(p, 'utf8');
const parts = ['以下是审阅所需的全部材料，内容都已附在下面；你不需要、也不要读取任何文件。'];
for (const f of ['review-prompt.md', 'manager-draft-v0.md', 'manager-draft-v1.md']) parts.push(`=== 文件：${f} ===\n${read(join(dir, f))}`);
for (const f of readdirSync(join(dir, 'cases')).sort()) parts.push(`=== 文件：cases/${f} ===\n${read(join(dir, 'cases', f))}`);
for (const v of ['v0', 'v1']) for (const f of readdirSync(join(dir, v)).sort()) parts.push(`=== 文件：${v}/${f} ===\n${read(join(dir, v, f))}`);
parts.push('材料到此结束。按 review-prompt.md 的要求，把完整的审阅（第 1 到第 5 部分，中文）作为最终回复输出。');
const bundle = parts.join('\n\n');
writeFileSync(join(dir, 'bundle.txt'), bundle);
console.log(`${readdirSync(join(dir, 'v0')).length} v0 answers, ${readdirSync(join(dir, 'v1')).length} v1 answers, bundle ${bundle.length} chars`);
