// B-101 native self-compile E2E harness.
//
// PURPOSE — the permanent regression net for native-frontend self-hosting that
// `a_empty.ring` (trivial program) could not catch. Compiles a REAL program that
// stresses the std surfaces most exposed to RC over-free / leak bugs under the
// clone-all-escape borrow model — print, List (push/index/iterate/join), Map
// (insert/index/get/iterate), Str (interp/index/len), plus element-READ
// projections bound to `let` (the B-101 alias-aware-ownership hot path) — using the
// NATIVE ring.exe (the self-compiled native compiler binary), then runs the result
// and asserts EXIT 0 + exact stdout.
//
// HOW THE ORCHESTRATOR RUNS THIS (main repo, with the LLVM toolchain present):
//   cd compiler && node --test ../tests/native_selfcompile.test.mjs
// or wire it into an npm script (e.g. `npm run test:native`).
//
// WHAT IT ASSERTS:
//   1. native ring.exe compiles tests/native/real_program.ring WITHOUT crashing
//      (exit 0 from the build step), via `ring.exe build <prog> --target=js` — the
//      native frontend self-hosts the JS backend (the native LLVM backend is B-099,
//      not yet linked; --target=js exercises the full native frontend: lexer →
//      parser → checker → HIR → Perceus → JS codegen, all running as native code).
//   2. The produced JS runs to EXIT 0 and prints EXACTLY EXPECTED_STDOUT.
//   3. Steps 1+2 are repeated 3× and every run must be identical — per the
//      intermittent-heap-corruption lesson (a single pass can mask a ~1/3-hit
//      RC bug), an RC regression that only sometimes corrupts the heap is caught.
//
// WHY --target=js AND NOT --target=llvm: per docs/backlog.md (B-099), the native
// binary self-hosts the FRONTEND via --target=js; emitting native code FROM the
// native binary (--target=llvm needing libLLVM-C linkage) is B-099, out of B-101
// scope. The RC model under test (Perceus) is a HIR-level pass shared by both
// backends and fully exercised by the native frontend regardless of emit target.
// If the orchestrator additionally has the native LLVM backend wired, swap
// BUILD_ARGS to ["build", PROG, "--target=llvm"] + link + run the .exe; the
// EXPECTED_STDOUT is identical (JS backend is the oracle, see the .ring fixture).
//
// SKIP BEHAVIOR (this worktree): ring.exe is built from compiler/dist-llvm/main.o +
// ring_runtime.o and is UNTRACKED (gitignored local artifact); the LLVM N-API addon
// (compiler/llvm-addon/) is also a local build. A fresh worktree has neither, so
// ring.exe is absent — every test then SKIPS rather than fails. The harness never
// attempts to BUILD ring.exe (that would stall on the addon build); it only USES a
// pre-built ring.exe if one is present at the repo root.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(__dirname, "..");

// Native compiler binary, produced by:
//   node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist-llvm --target=llvm
//   clang compiler/dist-llvm/main.o ring_runtime.o -o ring.exe -lmsvcrt
// Untracked local artifact — present in the main repo after a native bootstrap,
// absent in a fresh worktree.
const RING_EXE = path.join(REPO, process.platform === "win32" ? "ring.exe" : "ring");
const HAVE_RING_EXE = fs.existsSync(RING_EXE);

const PROG = path.join(REPO, "tests", "native", "real_program.ring");

// Pinned by the JS oracle (build tests/native/real_program.ring with the JS
// backend and run it). The native build must reproduce this byte-for-byte.
const EXPECTED_STDOUT = [
  "count=3",
  "ada,bob,cleo",
  "top=ada (90)",
  "sum=163",
  "first=r len=4",
  "total=253",
].join("\n");

const RUNS = 3; // intermittent-RC detection: a ~1/3-hit heap bug needs >1 run.

// Normalize line endings: the native binary may write CRLF via Windows text-mode
// stdout; compare logical output, not byte encoding. Also trim a single trailing
// newline so the assertion is independent of whether print() appends one at EOF.
function norm(s) {
  return s.replace(/\r\n/g, "\n").replace(/\n$/, "");
}

// Build the fixture with the NATIVE ring.exe (frontend self-host via --target=js),
// then run the emitted JS. Returns { code, stdout } of the program run, or throws
// with diagnostics if the native build step itself crashed (non-zero exit).
function buildAndRunNative() {
  const jsOut = PROG.replace(/\.ring$/, ".js");
  try {
    const build = spawnSync(RING_EXE, ["build", PROG, "--target=js"], {
      cwd: REPO, encoding: "utf-8", timeout: 120000,
    });
    assert.strictEqual(build.status, 0,
      `native ring.exe build FAILED (exit ${build.status})\n` +
      `--- stdout ---\n${build.stdout}\n--- stderr ---\n${build.stderr}`);
    assert.ok(fs.existsSync(jsOut),
      `native build reported success but produced no JS at ${jsOut}`);

    const run = spawnSync(process.execPath, [jsOut], {
      cwd: REPO, encoding: "utf-8", timeout: 60000,
    });
    return { code: run.status, stdout: run.stdout, stderr: run.stderr };
  } finally {
    fs.rmSync(jsOut, { force: true });
  }
}

describe("native self-compile E2E (B-101)", () => {
  for (let i = 1; i <= RUNS; i++) {
    test(`real_program via native ring.exe — run ${i}/${RUNS}`,
      { skip: HAVE_RING_EXE ? false : "ring.exe not present (build native compiler first)" },
      () => {
        const { code, stdout, stderr } = buildAndRunNative();
        assert.strictEqual(code, 0,
          `native-compiled program did NOT exit 0 (exit ${code}) — likely RC over-free/abort\n` +
          `--- stdout ---\n${stdout}\n--- stderr ---\n${stderr}`);
        assert.strictEqual(norm(stdout), EXPECTED_STDOUT,
          `native-compiled program stdout diverged from oracle\n` +
          `--- expected ---\n${EXPECTED_STDOUT}\n--- got ---\n${norm(stdout)}`);
      });
  }
});
