// LSP server smoke test — sends JSON-RPC requests, verifies responses
import { spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const CLI = path.resolve(__dirname, "../compiler/dist/cli.js");

const child = spawn("node", [CLI, "lsp"], { stdio: ["pipe", "pipe", "pipe"] });

let buf = "";
let pending = new Map(); // id → { resolve, reject }
let nextId = 1;
let notifications = [];

child.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  while (true) {
    const headerEnd = buf.indexOf("\r\n\r\n");
    if (headerEnd < 0) break;
    const header = buf.slice(0, headerEnd);
    const match = header.match(/Content-Length:\s*(\d+)/i);
    if (!match) break;
    const len = parseInt(match[1], 10);
    const bodyStart = headerEnd + 4;
    if (buf.length < bodyStart + len) break;
    const body = buf.slice(bodyStart, bodyStart + len);
    buf = buf.slice(bodyStart + len);
    const msg = JSON.parse(body);
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id).resolve(msg);
      pending.delete(msg.id);
    } else {
      notifications.push(msg);
    }
  }
});

child.stderr.on("data", () => {});

function send(method, params, id) {
  const msg = { jsonrpc: "2.0", method, params };
  if (id !== undefined) msg.id = id;
  const body = JSON.stringify(msg);
  child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send(method, params, id);
    setTimeout(() => { pending.delete(id); reject(new Error(`timeout: ${method}`)); }, 5000);
  });
}

function notify(method, params) {
  send(method, params);
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

const DEMO_SRC = `struct Point { x: Int, y: Int }

fn distance(p: Point) -> Int {
  p.x + p.y
}

fn main() -> Int {
  let pt = Point { x: 3, y: 4 }
  distance(pt)
}
`;

const ERR_SRC = `fn broken() -> Int {
  unknown_var
}
`;

let pass = 0;
let fail = 0;
function check(name, condition) {
  if (condition) { pass++; console.log(`  PASS: ${name}`); }
  else { fail++; console.log(`  FAIL: ${name}`); }
}

async function run() {
  console.log("=== LSP Smoke Test ===\n");

  // 1. Initialize
  console.log("[1] Initialize");
  const init = await request("initialize", {
    processId: process.pid, capabilities: {}, rootUri: null
  });
  check("has result", !!init.result);
  check("has capabilities", !!init.result?.capabilities);
  check("hover enabled", init.result?.capabilities?.hoverProvider === true);
  check("completion enabled", !!init.result?.capabilities?.completionProvider);
  check("definition enabled", init.result?.capabilities?.definitionProvider === true);
  check("references enabled", init.result?.capabilities?.referencesProvider === true);
  check("rename enabled", init.result?.capabilities?.renameProvider === true);
  check("symbols enabled", init.result?.capabilities?.documentSymbolProvider === true);
  check("code actions enabled", init.result?.capabilities?.codeActionProvider === true);
  notify("initialized", {});

  // 2. Open document (valid)
  console.log("\n[2] Open valid document + diagnostics");
  notify("textDocument/didOpen", {
    textDocument: { uri: "file:///demo.ring", languageId: "ring", version: 1, text: DEMO_SRC }
  });
  await sleep(500);
  const diags = notifications.filter(n => n.method === "textDocument/publishDiagnostics" && n.params?.uri === "file:///demo.ring");
  check("received diagnostics notification", diags.length > 0);
  const lastDiag = diags[diags.length - 1];
  check("no errors in valid file", lastDiag?.params?.diagnostics?.length === 0);

  // 3. Hover
  console.log("\n[3] Hover on 'pt'");
  const hover = await request("textDocument/hover", {
    textDocument: { uri: "file:///demo.ring" },
    position: { line: 7, character: 6 }  // "pt" in "let pt = ..."
  });
  check("hover returns result", hover.result !== null);
  const hoverText = typeof hover.result?.contents === "string"
    ? hover.result.contents
    : hover.result?.contents?.value ?? "";
  check("hover shows Point type", hoverText.includes("Point"));
  console.log(`    hover content: ${hoverText.replace(/\n/g, " ").slice(0, 80)}`);

  // 4. Completion
  console.log("\n[4] Completion at top-level scope");
  const comp = await request("textDocument/completion", {
    textDocument: { uri: "file:///demo.ring" },
    position: { line: 8, character: 2 }
  });
  const items = comp.result || [];
  const labels = items.map(i => i.label);
  check("completion returns items", items.length > 0);
  check("has 'distance' function", labels.includes("distance"));
  check("has 'print' builtin", labels.includes("print"));
  check("has 'let' keyword", labels.includes("let"));
  console.log(`    ${items.length} items, sample: ${labels.slice(0, 8).join(", ")}`);

  // 5. Go-to-definition
  console.log("\n[5] Go-to-definition on 'distance'");
  const def = await request("textDocument/definition", {
    textDocument: { uri: "file:///demo.ring" },
    position: { line: 8, character: 3 }  // "distance" in "distance(pt)"
  });
  check("definition returns result", def.result !== null);
  check("definition points to line 2 (fn distance)", def.result?.range?.start?.line === 2);
  console.log(`    definition at line ${def.result?.range?.start?.line}`);

  // 6. References
  console.log("\n[6] Find references of 'pt'");
  const refs = await request("textDocument/references", {
    textDocument: { uri: "file:///demo.ring" },
    position: { line: 7, character: 6 },
    context: { includeDeclaration: true }
  });
  const refLocs = refs.result || [];
  check("references found", refLocs.length >= 2);
  console.log(`    ${refLocs.length} references found`);

  // 7. Document Symbols
  console.log("\n[7] Document symbols");
  const syms = await request("textDocument/documentSymbol", {
    textDocument: { uri: "file:///demo.ring" }
  });
  const symList = syms.result || [];
  const symNames = symList.map(s => s.name);
  check("has Point struct", symNames.includes("Point"));
  check("has distance function", symNames.includes("distance"));
  check("has main function", symNames.includes("main"));
  console.log(`    symbols: ${symNames.join(", ")}`);

  // 8. Rename
  console.log("\n[8] Rename 'pt' to 'point'");
  const rename = await request("textDocument/rename", {
    textDocument: { uri: "file:///demo.ring" },
    position: { line: 7, character: 6 },
    newName: "point"
  });
  check("rename returns edit", rename.result !== null);
  const edits = rename.result?.changes?.["file:///demo.ring"] || [];
  check("rename has edits", edits.length >= 2);
  check("all edits use new name", edits.every(e => e.newText === "point"));
  console.log(`    ${edits.length} edit locations`);

  // 9. Open document with errors
  console.log("\n[9] Open document with errors");
  notifications = [];
  notify("textDocument/didOpen", {
    textDocument: { uri: "file:///error.ring", languageId: "ring", version: 1, text: ERR_SRC }
  });
  await sleep(500);
  const errDiags = notifications.filter(n =>
    n.method === "textDocument/publishDiagnostics" && n.params?.uri === "file:///error.ring"
  );
  check("error diagnostics received", errDiags.length > 0);
  const lastErr = errDiags[errDiags.length - 1];
  check("has error diagnostics", (lastErr?.params?.diagnostics?.length ?? 0) > 0);
  if (lastErr?.params?.diagnostics?.length > 0) {
    const d = lastErr.params.diagnostics[0];
    check("error has code", !!d.code);
    check("error has source 'ring'", d.source === "ring");
    console.log(`    error: [${d.code}] ${d.message}`);
  }

  // 10. Code Actions (on error file)
  console.log("\n[10] Code actions on error");
  const actions = await request("textDocument/codeAction", {
    textDocument: { uri: "file:///error.ring" },
    range: { start: { line: 0, character: 0 }, end: { line: 2, character: 0 } },
    context: { diagnostics: lastErr?.params?.diagnostics || [] }
  });
  console.log(`    ${(actions.result || []).length} code actions available`);

  // Summary
  console.log(`\n=== Results: ${pass} passed, ${fail} failed ===`);

  child.kill();
  process.exit(fail > 0 ? 1 : 0);
}

run().catch(err => {
  console.error("Fatal:", err);
  child.kill();
  process.exit(1);
});
