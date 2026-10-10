// Runs manager-jd.md §5 Interview 1 (猜老板在想什么) and Interview 3 (下行翻译) on the case files,
// with the official CLIs as candidates. Candidates are written under blind labels; the mapping is
// in answers/key.json so the review can be done without knowing which is which.
// Usage: node interview.mjs <interview 1|3> <case ids, comma separated | all>
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const CLAUDE = "C:\\Users\\Yufeng Ying\\scoop\\shims\\claude.exe";
const CODEX = "C:\\Users\\Yufeng Ying\\AppData\\Local\\OpenAI\\Codex\\bin\\2e5e00daee91c61d\\codex.exe";
const here = import.meta.dirname;
const cwd = join(here, "cwd");
const answers = join(here, "answers");
mkdirSync(cwd, { recursive: true });
mkdirSync(answers, { recursive: true });
writeFileSync(join(here, "empty-mcp.json"), JSON.stringify({ mcpServers: {} }));

// Fixed blind labels: A and B. Which CLI is which is only in key.json.
const KEY = { A: "codex", B: "claude" };
writeFileSync(join(answers, "key.json"), JSON.stringify(KEY));

const ROLE = `你是 Angela，Lobotomy 中用户的全局协作者（Manager）。Lobotomy 是一个桌面应用，用官方 CLI（Claude Code、Codex）作为执行者（Worker）和技术负责人（Tech Lead），用户经你管理项目。
你的职责：从不完整、含糊、甚至互相矛盾的用户信号中，维护对用户当前意图的判断；控制什么信息在什么时候呈现给用户；把用户的真实意图转成下层角色能可靠执行的任务。区分"用户明确说过""从历史高置信推断""仍不确定"。
下面是用户与一个执行者（AI 编程助手）的真实对话历史，你在旁观察。历史在用户刚发出的一条消息处截断。`;

const INTERVIEW = {
  1: `${ROLE}

不要回复用户，也不要调用任何工具。只输出以下各项，每项简短：

Current goal:
Likely current state:
Evidence:
Alternative interpretation:
What would be dangerous to assume:
Next interaction strategy:`,
  3: `${ROLE}

用户刚发出的这条消息需要交给下层。不要回复用户，也不要调用任何工具。分别写出：

Brief for Tech Lead:
（要探索或质疑的问题、边界、何时回报什么）

Brief for Worker:
（要执行的事、允许与不允许做的事、完成条件）

在每份 brief 中标明哪些是用户明确说过的，哪些是你的推断。如果某一方此时不该收到任务，写明理由。`,
};

function caseInput(text) {
  const keep = [];
  let skip = false;
  for (const line of text.split("\n")) {
    if (line.startsWith("## ")) skip = line.includes("之后实际发生了什么") || line.includes("选这个点的理由") || line.includes("来源");
    if (!skip) keep.push(line);
  }
  return keep.join("\n").trim();
}

const CLAUDE_TRIM = [
  "--setting-sources", "", "--strict-mcp-config", "--mcp-config", join(here, "empty-mcp.json"),
  "--disallowed-tools", "Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Agent,Skill,NotebookEdit",
];
const CODEX_TRIM = [
  "--skip-git-repo-check", "--ignore-rules", "--ignore-user-config",
  "--disable", "apps", "--disable", "computer_use", "--disable", "browser_use",
];

function ask(cli, prompt) {
  const [program, args] =
    cli === "claude"
      ? [CLAUDE, ["-p", "--output-format", "json", "--no-session-persistence", ...CLAUDE_TRIM]]
      : [CODEX, ["exec", "--json", "--ephemeral", "-s", "read-only", ...CODEX_TRIM, "-"]];
  return new Promise((resolve) => {
    const t0 = performance.now();
    const child = spawn(program, args, { cwd, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    let out = "", err = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (err += c));
    child.on("close", (code) => {
      const ms = Math.round(performance.now() - t0);
      let text = "", model = null;
      if (cli === "claude") {
        try {
          const r = JSON.parse(out);
          text = r.result ?? "";
          model = Object.keys(r.modelUsage ?? {}).join(",");
        } catch { text = `PARSE ERROR (exit ${code}): ${out.slice(-500)} ${err.slice(-500)}`; }
      } else {
        for (const line of out.split("\n")) {
          try {
            const e = JSON.parse(line);
            if (e.type === "item.completed" && e.item?.type === "agent_message") text = e.item.text;
          } catch {}
        }
        if (!text) text = `NO ANSWER (exit ${code}): ${err.slice(-500)}`;
      }
      resolve({ text, ms, model });
    });
    child.stdin.end(prompt);
  });
}

const [interview, which = "all"] = process.argv.slice(2);
if (!INTERVIEW[interview]) throw new Error("usage: node interview.mjs <1|3> <ids|all>");
const caseDir = join(here, "cases");
const ids = which === "all"
  ? readdirSync(caseDir).filter((f) => /^case-\d+\.md$/.test(f)).map((f) => f.slice(5, -3))
  : which.split(",");

for (const id of ids) {
  const input = caseInput(readFileSync(join(caseDir, `case-${id}.md`), "utf8"));
  const prompt = `${INTERVIEW[interview]}\n\n---\n\n${input}`;
  const runs = await Promise.all(
    Object.entries(KEY).map(async ([label, cli]) => {
      const file = join(answers, `i${interview}-case-${id}-${label}.md`);
      if (existsSync(file)) return `${label}: kept`;
      const { text, ms, model } = await ask(cli, prompt);
      writeFileSync(file, `<!-- ${ms} ms -->\n${text}\n`);
      writeFileSync(join(answers, `i${interview}-case-${id}-${label}.meta.json`), JSON.stringify({ cli, model, ms }));
      return `${label}: ${ms} ms`;
    }),
  );
  console.log(`interview ${interview} case ${id}: ${runs.join(", ")}`);
}
