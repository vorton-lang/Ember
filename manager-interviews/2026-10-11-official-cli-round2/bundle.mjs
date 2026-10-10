// Puts everything a reviewer may see into one text, so a reviewer without file access gets the same
// material and nothing else (no key.json, no meta, no script).
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const here = import.meta.dirname;
const read = (p) => readFileSync(p, 'utf8');
const parts = [];
parts.push('以下是审阅所需的全部材料。审阅要求中提到的文件路径，内容都已附在下面；你不需要、也不要读取任何文件。\n');
parts.push(`=== 文件：review-prompt.md ===\n${read(join(here, 'review-prompt.md'))}`);
parts.push(`=== 文件：notes/manager-jd.md ===\n${read('C:\\Users\\Yufeng Ying\\Desktop\\Lobotomy\\notes\\manager-jd.md')}`);
parts.push(`=== 文件：manager-draft.md ===\n${read(join(here, 'manager-draft.md'))}`);
for (const f of readdirSync(join(here, 'cases')).filter((f) => /^case-\d+\.md$/.test(f)).sort()) {
  parts.push(`=== 文件：cases/${f} ===\n${read(join(here, 'cases', f))}`);
}
for (const f of readdirSync(join(here, 'answers')).filter((f) => /^i[13]-case-\d+-[XYZ]\.md$/.test(f)).sort()) {
  const text = read(join(here, 'answers', f)).replace(/^<!--.*?-->\n/, '');
  parts.push(`=== 文件：answers/${f} ===\n${text}`);
}
parts.push('材料到此结束。按 review-prompt.md 的要求，把完整的审阅（第 1 到第 6 部分，中文）作为最终回复输出。');
const bundle = parts.join('\n\n');
writeFileSync(join(here, 'review-bundle.txt'), bundle);
console.log(`${bundle.length} chars`);
