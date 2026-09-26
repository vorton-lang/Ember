// LLVM backend differential regression tests.
//
// For each case in tests/cases/llvm/, compile it with BOTH backends and assert the
// runtime output is identical. The JS backend is the oracle: any divergence means
// the LLVM codegen regressed. These guard the fixes from the LLVM self-hosting work
// (tuple-match tag checks, OR-patterns, Set iteration, generic Eq/Ord dispatch,
// List.contains, fail/catch via ring_try, nested named patterns, field ordering).
//
// Requires a native toolchain (clang) + ring_runtime.cpp. If clang is unavailable
// (e.g. CI without LLVM), every test is skipped rather than failing.
//
// Run from the compiler/ dir:  node --test ../tests/llvm_diff.test.mjs
// or via:                      npm run test:llvm

import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, "..");
const RING = path.join(REPO, "compiler", "dist", "main.js");
const CASES = path.join(REPO, "tests", "cases", "llvm");
const RUNTIME_CPP = path.join(REPO, "ring_runtime.cpp");
const RUNTIME_O = path.join(REPO, "ring_runtime.o");

function have(cmd) {
  try { execSync(cmd, { stdio: "pipe" }); return true; } catch { return false; }
}
const HAVE_CLANG = have("clang --version");

function sh(cmd) {
  return execSync(cmd, { cwd: REPO, encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 60000 });
}

function buildRuntime() {
  // Rebuild if missing or older than the source.
  if (fs.existsSync(RUNTIME_O) &&
      fs.statSync(RUNTIME_O).mtimeMs >= fs.statSync(RUNTIME_CPP).mtimeMs) return;
  sh(`clang++ -c "${RUNTIME_CPP}" -o "${RUNTIME_O}" -std=c++17 -O0 -D_CRT_SECURE_NO_WARNINGS`);
}

function runJs(ringFile) {
  const jsFile = ringFile.replace(/\.ring$/, ".js");
  try {
    sh(`node "${RING}" build "${ringFile}"`);
    return sh(`node "${jsFile}"`);
  } finally {
    fs.rmSync(jsFile, { force: true });
  }
}

function runLlvm(ringFile) {
  const base = ringFile.replace(/\.ring$/, "");
  const oFile = base + ".o";
  const exeFile = base + ".exe";
  try {
    sh(`node "${RING}" build "${ringFile}" --target=llvm`);
    // Big stack: a few cases recurse; LLVM native default stack is 1MB.
    sh(`clang "${oFile}" "${RUNTIME_O}" -o "${exeFile}" -lmsvcrt -Wl,/STACK:536870912`);
    return sh(`"${exeFile}"`);
  } finally {
    fs.rmSync(oFile, { force: true });
    fs.rmSync(exeFile, { force: true });
    fs.rmSync(path.join(REPO, "ring_output.ll"), { force: true });
  }
}

const caseFiles = fs.existsSync(CASES)
  ? fs.readdirSync(CASES).filter(f => f.endsWith(".ring")).sort()
  : [];

describe("llvm backend == js backend (differential)", () => {
  before(() => { if (HAVE_CLANG) buildRuntime(); });

  for (const f of caseFiles) {
    test(`${f}`, { skip: HAVE_CLANG ? false : "clang not available" }, () => {
      const ringFile = path.join(CASES, f);
      // Normalize line endings: the native exe writes CRLF via Windows text-mode
      // stdout, node writes LF. We compare logical output, not byte encoding.
      const norm = (s) => s.replace(/\r\n/g, "\n");
      const jsOut = norm(runJs(ringFile));
      const llvmOut = norm(runLlvm(ringFile));
      assert.strictEqual(llvmOut, jsOut,
        `LLVM output diverged from JS for ${f}\n--- JS ---\n${jsOut}\n--- LLVM ---\n${llvmOut}`);
    });
  }
});
