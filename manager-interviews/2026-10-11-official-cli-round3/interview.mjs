// Round 3 (draft v1) of manager-jd.md §5 interviews 1 and 3: the Angela instruction draft (manager-draft.md)
// goes in as the role instructions, the way Lobotomy's adapters pass a role's instructions
// (Claude: --append-system-prompt; Codex: developer_instructions). Each candidate has its own effort. The runtime's local-time line opens each input. Candidates are blind labels; the mapping
// is in answers/key.json.
// Usage: node interview.mjs <interview 1|3> <case ids, comma separated | all>
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const CLAUDE = 'C:\\Users\\Yufeng Ying\\scoop\\shims\\claude.exe';
const CODEX = 'C:\\Users\\Yufeng Ying\\AppData\\Local\\OpenAI\\Codex\\bin\\2e5e00daee91c61d\\codex.exe';
const here = import.meta.dirname;
const cwd = join(here, 'cwd');
const answers = join(here, 'answers');
mkdirSync(cwd, { recursive: true });
mkdirSync(answers, { recursive: true });
writeFileSync(join(here, 'empty-mcp.json'), JSON.stringify({ mcpServers: {} }));

const CANDIDATES = {
  P: { cli: 'claude', model: 'claude-opus-5-5', effort: 'high' },
  Q: { cli: 'codex', model: 'gpt-6.1-sol', effort: 'xhigh' },
};
writeFileSync(join(answers, 'key.json'), JSON.stringify({ candidates: CANDIDATES }, null, 2));

const INSTRUCTIONS = readFileSync(join(here, 'manager-draft.md'), 'utf8').replaceAll('{name}', 'Angela');

// The user's local time at the cut (JST), as the runtime would put it at the top of the input.
const LOCAL_TIME = {
  '01': '2026-10-01 16:28', '02': '2026-10-01 21:20', '03': '2026-10-03 23:42', '04': '2026-10-04 00:36',
  '05': '2026-10-04 15:03', '06': '2026-10-09 22:01', '07': '2026-10-09 23:13', '08': '2026-10-10 01:29',
};

const SITUATION = '下面是用户与一个执行者（AI 编程助手）的真实对话历史，你在旁观察。历史在用户刚发出的一条消息处截断。';

const TASK = {
  1: `${SITUATION}

不要回复用户，也不要调用任何工具。只输出以下各项，每项简短：

Current goal:
Likely current state:
Evidence:
Alternative interpretation:
What would be dangerous to assume:
Next interaction strategy:`,
  3: `${SITUATION}

用户刚发出的这条消息需要交给下层。不要回复用户，也不要调用任何工具。分别写出：

Brief for Tech Lead:
（要探索或质疑的问题、边界、何时回报什么）

Brief for Worker:
（要执行的事、允许与不允许做的事、完成条件）

在每份 brief 中标明哪些是用户明确说过的，哪些是你的推断。如果某一方此时不该收到任务，写明理由。`,
};

/** The case as the candidate sees it: no source line, no ground truth, no reason for the pick. */
function caseInput(text) {
  const keep = [];
  let skip = false;
  for (const line of text.split('\n')) {
    if (line.startsWith('## ')) skip = line.includes('之后实际发生了什么') || line.includes('选这个点的理由') || line.includes('来源');
    if (!skip) keep.push(line);
  }
  return keep.join('\n').trim();
}

const CLAUDE_TRIM = [
  '--setting-sources', '', '--strict-mcp-config', '--mcp-config', join(here, 'empty-mcp.json'),
  '--disallowed-tools', 'Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Agent,Skill,NotebookEdit',
];
const CODEX_TRIM = [
  '--skip-git-repo-check', '--ignore-rules', '--ignore-user-config',
  '--disable', 'apps', '--disable', 'computer_use', '--disable', 'browser_use',
];

function ask({ cli, model, effort }, prompt) {
  const [program, args] =
    cli === 'claude'
      ? [CLAUDE, ['-p', '--output-format', 'json', '--no-session-persistence', '--model', model, '--effort', effort, '--append-system-prompt', INSTRUCTIONS, ...CLAUDE_TRIM]]
      : [CODEX, ['exec', '--json', '--ephemeral', '-s', 'read-only', ...CODEX_TRIM, '-m', model,
          '-c', `model_reasoning_effort=${JSON.stringify(effort)}`, '-c', `developer_instructions=${JSON.stringify(INSTRUCTIONS)}`, '-']];
  return new Promise((resolve) => {
    const t0 = performance.now();
    const child = spawn(program, args, { cwd, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let out = '', err = '';
    child.stdout.on('data', (c) => (out += c));
    child.stderr.on('data', (c) => (err += c));
    child.on('close', (code) => {
      const ms = Math.round(performance.now() - t0);
      let text = '', used = null, usage = null;
      if (cli === 'claude') {
        try {
          const r = JSON.parse(out);
          text = r.result ?? '';
          used = Object.keys(r.modelUsage ?? {}).join(',');
          usage = r.usage ?? null;
        } catch { text = `PARSE ERROR (exit ${code}): ${out.slice(-500)} ${err.slice(-500)}`; }
      } else {
        for (const line of out.split('\n')) {
          try {
            const e = JSON.parse(line);
            if (e.type === 'item.completed' && e.item?.type === 'agent_message') text = e.item.text;
            if (e.type === 'turn.completed') usage = e.usage ?? null;
          } catch {}
        }
        used = model;
        if (!text) text = `NO ANSWER (exit ${code}): ${err.slice(-500)}`;
      }
      resolve({ text, ms, used, usage });
    });
    child.stdin.end(prompt);
  });
}

const [interview, which = 'all'] = process.argv.slice(2);
if (!TASK[interview]) throw new Error('usage: node interview.mjs <1|3> <ids|all>');
const caseDir = join(here, 'cases');
const ids = which === 'all'
  ? readdirSync(caseDir).filter((f) => /^case-\d+\.md$/.test(f)).map((f) => f.slice(5, -3))
  : which.split(',');

for (const id of ids) {
  const input = caseInput(readFileSync(join(caseDir, `case-${id}.md`), 'utf8'));
  const prompt = `【Lobotomy】用户本地时间：${LOCAL_TIME[id]}（JST）\n\n${TASK[interview]}\n\n---\n\n${input}`;
  const runs = await Promise.all(
    Object.entries(CANDIDATES).map(async ([label, candidate]) => {
      const file = join(answers, `i${interview}-case-${id}-${label}.md`);
      if (existsSync(file)) return `${label}: kept`;
      const { text, ms, used, usage } = await ask(candidate, prompt);
      writeFileSync(file, `<!-- ${ms} ms -->\n${text}\n`);
      writeFileSync(join(answers, `i${interview}-case-${id}-${label}.meta.json`), JSON.stringify({ ...candidate, used, ms, usage }));
      return `${label}: ${ms} ms`;
    }),
  );
  console.log(`interview ${interview} case ${id}: ${runs.join(', ')}`);
}
