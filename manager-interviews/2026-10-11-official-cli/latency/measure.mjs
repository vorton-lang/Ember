// Measures how long one Angela-style turn takes with the official CLIs, launched the way
// Lobotomy's adapters launch them (backend/crates/harness/src/{claude,codex}.rs), against a stub
// MCP server. Prints one JSON line per run and a summary table.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

const CLAUDE = "C:\\Users\\Yufeng Ying\\scoop\\shims\\claude.exe";
const CODEX = "C:\\Users\\Yufeng Ying\\AppData\\Local\\OpenAI\\Codex\\bin\\2e5e00daee91c61d\\codex.exe";
const here = import.meta.dirname;
const cwd = join(here, "cwd");
mkdirSync(cwd, { recursive: true });
const out = join(here, "runs.jsonl");

const INSTRUCTIONS =
  "你是 Angela，Lobotomy 中用户的全局协作者。你通过 Lobotomy 的 MCP 工具查看和管理各个项目。" +
  "用户的原话优先；你的解读要与原话分开。这是一次延迟测量，不需要调用任何工具。";
const INPUT = "只回复两个字母：OK";

// A stub MCP server: answers initialize and tools/list with no tools, accepts notifications.
const mcp = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (req.method !== "POST") {
      res.writeHead(405).end();
      return;
    }
    let msg;
    try {
      msg = JSON.parse(body);
    } catch {
      res.writeHead(400).end();
      return;
    }
    if (msg.id === undefined) {
      res.writeHead(202).end();
      return;
    }
    let result = {};
    if (msg.method === "initialize") {
      result = {
        protocolVersion: msg.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "stub", version: "0" },
      };
    } else if (msg.method === "tools/list") {
      result = { tools: [] };
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }));
  });
});
await new Promise((r) => mcp.listen(0, "127.0.0.1", r));
const mcpUrl = `http://127.0.0.1:${mcp.address().port}/mcp/tok`;
const mcpConfigPath = join(here, "mcp.json");
writeFileSync(mcpConfigPath, JSON.stringify({ mcpServers: { lobotomy: { type: "http", url: mcpUrl } } }));

const CLAUDE_TRIM = [
  "--setting-sources", "",
  "--strict-mcp-config",
  "--disallowed-tools", "CronCreate,CronDelete,CronList,ScheduleWakeup,RemoteTrigger,PushNotification,SendMessage,ListAgents,EnterWorktree,ExitWorktree,DesignSync,Workflow",
];
const CODEX_TRIM = [
  "--skip-git-repo-check", "--ignore-rules", "--ignore-user-config",
  "--disable", "apps", "--disable", "computer_use", "--disable", "browser_use",
];

function claudeArgs({ session, resume, model, withMcp = true }) {
  const args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"];
  args.push(...(resume ? ["--resume", session] : ["--session-id", session]));
  args.push("--dangerously-skip-permissions", "--allowed-tools", "mcp__lobotomy");
  if (model) args.push("--model", model);
  args.push("--append-system-prompt", INSTRUCTIONS, ...CLAUDE_TRIM);
  args.push("--mcp-config", withMcp ? mcpConfigPath : join(here, "empty-mcp.json"));
  return args;
}
writeFileSync(join(here, "empty-mcp.json"), JSON.stringify({ mcpServers: {} }));

function codexArgs({ resume, model }) {
  const args = ["exec"];
  if (resume) args.push("resume", resume);
  args.push("--json", "--dangerously-bypass-approvals-and-sandbox", ...CODEX_TRIM);
  if (model) args.push("-m", model);
  args.push(
    "-c", `developer_instructions=${JSON.stringify(INSTRUCTIONS)}`,
    "-c", `mcp_servers.lobotomy.url=${JSON.stringify(mcpUrl)}`,
    "-c", `mcp_servers.lobotomy.default_tools_approval_mode="approve"`,
    "-",
  );
  return args;
}

function run(label, program, args, input) {
  return new Promise((resolve) => {
    const t0 = performance.now();
    const ms = () => Math.round(performance.now() - t0);
    const r = { label, firstLine: null, init: null, firstText: null, done: null, exit: null, apiMs: null, wallMsReported: null, model: null, threadId: null, error: null };
    const child = spawn(program, args, { cwd, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
    let buf = "", err = "";
    child.stdout.on("data", (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        r.firstLine ??= ms();
        let e;
        try { e = JSON.parse(line); } catch { continue; }
        // Claude
        if (e.type === "system" && e.subtype === "init") { r.init ??= ms(); r.model = e.model; }
        if (e.type === "stream_event" && e.event?.delta?.type === "text_delta") r.firstText ??= ms();
        if (e.type === "assistant" && e.message?.content?.some((c) => c.type === "text")) r.firstText ??= ms();
        if (e.type === "result") { r.done ??= ms(); r.apiMs = e.duration_api_ms; r.wallMsReported = e.duration_ms; if (e.is_error) r.error = e.result; }
        // Codex
        if (e.type === "thread.started") { r.init ??= ms(); r.threadId = e.thread_id; }
        if (e.type === "item.completed" && e.item?.type === "agent_message") r.firstText ??= ms();
        if (e.type === "turn.completed") r.done ??= ms();
        if (e.type === "turn.failed" || e.type === "error") r.error = JSON.stringify(e).slice(0, 300);
      }
    });
    child.stderr.on("data", (c) => (err += c));
    child.on("close", (code) => {
      r.exit = ms();
      if (code !== 0 && !r.error) r.error = `exit ${code}: ${err.slice(-300)}`;
      appendFileSync(out, JSON.stringify(r) + "\n");
      console.log(JSON.stringify(r));
      resolve(r);
    });
    child.stdin.end(input);
  });
}

async function versionTimes(label, program, n) {
  const times = [];
  for (let i = 0; i < n; i++) {
    const t0 = performance.now();
    await new Promise((res) => spawn(program, ["--version"], { stdio: "ignore", windowsHide: true }).on("close", res));
    times.push(Math.round(performance.now() - t0));
  }
  console.log(JSON.stringify({ label, versionMs: times }));
  appendFileSync(out, JSON.stringify({ label, versionMs: times }) + "\n");
}

const plan = process.argv[2] ?? "all";
const results = [];
if (plan === "all" || plan === "version") {
  await versionTimes("claude --version", CLAUDE, 3);
  await versionTimes("codex --version", CODEX, 3);
}
if (plan === "all" || plan === "claude-haiku") {
  const session = randomUUID();
  results.push(await run("claude haiku new", CLAUDE, claudeArgs({ session, model: "haiku" }), INPUT));
  for (let i = 0; i < 3; i++) results.push(await run("claude haiku resume", CLAUDE, claudeArgs({ session, resume: true, model: "haiku" }), INPUT));
  const bare = randomUUID();
  results.push(await run("claude haiku new, no MCP", CLAUDE, claudeArgs({ session: bare, model: "haiku", withMcp: false }), INPUT));
  results.push(await run("claude haiku resume, no MCP", CLAUDE, claudeArgs({ session: bare, resume: true, model: "haiku", withMcp: false }), INPUT));
}
if (plan === "all" || plan === "claude-default") {
  const session = randomUUID();
  results.push(await run("claude default new", CLAUDE, claudeArgs({ session }), INPUT));
  for (let i = 0; i < 2; i++) results.push(await run("claude default resume", CLAUDE, claudeArgs({ session, resume: true }), INPUT));
}
if (plan === "all" || plan === "codex") {
  const first = await run("codex default new", CODEX, codexArgs({}), INPUT);
  results.push(first);
  if (first.threadId) {
    for (let i = 0; i < 3; i++) results.push(await run("codex default resume", CODEX, codexArgs({ resume: first.threadId }), INPUT));
  }
}
console.table(results.map(({ label, firstLine, init, firstText, done, exit, apiMs, model, error }) => ({ label, firstLine, init, firstText, done, exit, apiMs, model, error: error?.slice(0, 60) })));
mcp.close();
