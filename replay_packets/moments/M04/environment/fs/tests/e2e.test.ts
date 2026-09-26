// Ring-lang end-to-end compiler tests
// Uses Ring self-hosted compiler via in-process ESM import

import { test, describe } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import * as vm from "node:vm";
import { execSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { parse } from "../compiler/dist/parser.js";
import { check } from "../compiler/dist/checker.js";
import { generate } from "../compiler/dist/codegen.js";
import { new_collecting_sink } from "../compiler/dist/diagnostics.js";
import { format_llm, format_human } from "../compiler/dist/formatter.js";
import { compile_project, compile_project_esm } from "../compiler/dist/compiler_mod.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const REPO_ROOT = __dirname.includes("dist")
  ? path.resolve(__dirname, "../..")
  : path.resolve(__dirname, "..");
const CASES_DIR = path.resolve(REPO_ROOT, "tests/cases");
const MODULES_DIR = path.resolve(REPO_ROOT, "tests/cases/modules");
const RING = path.resolve(REPO_ROOT, "compiler/dist/main.js");

const Option_none = Object.freeze({ _tag: "none" });
function Option_some(v: any) { return { _tag: "some", _0: v }; }

// ============================================================
// In-process runtime: strip ESM imports, provide Node globals via vm
// ============================================================

class ExitError extends Error {
  code: number;
  constructor(code: number) {
    super(`process.exit(${code})`);
    this.code = code;
  }
}

function make_sandbox(output_lines: string[]): vm.Context {
  const sandbox = {
    console: {
      log: (...args: unknown[]) => {
        output_lines.push(args.map(a => typeof a === "string" ? a : String(a)).join(" "));
      },
      error: () => {},
      warn: () => {},
    },
    process: {
      exit: (code: number) => { throw new ExitError(code); },
      argv: ["node", "test"],
      cwd: () => process.cwd(),
      stderr: { write: () => {} },
    },
    JSON, Map, Set, Array, Object, Error, String, Number, Boolean,
    RegExp, Symbol, parseInt, parseFloat, isNaN, isFinite,
    Infinity, NaN, undefined, Math,
    __fs: fs, __path: path,
  };
  return vm.createContext(sandbox);
}

function strip_esm_lines(js: string): string {
  return js
    .replace(/^import \{[^\n]*\n/m, "")
    .replace(/^const __require[^\n]*\n/m, "")
    .replace(/var __fs = __require\("fs"\), __path = __require\("path"\);/, "");
}

function run_js_in_vm(js_code: string): string {
  const output_lines: string[] = [];
  const ctx = make_sandbox(output_lines);
  const script = new vm.Script(js_code, { filename: "ring-output.js", timeout: 5000 });
  script.runInContext(ctx);
  return output_lines.length > 0 ? output_lines.join("\n") + "\n" : "";
}

// ============================================================
// In-process compile helpers
// ============================================================

function has_errors(sink: any): boolean {
  return sink.items.some((d: any) => d.severity._tag === "SevError");
}

function ring_run_single(file_path: string): string {
  const source = fs.readFileSync(file_path, "utf-8");
  const sink = new_collecting_sink();
  const ast = parse(source, file_path, sink);
  if (has_errors(sink)) {
    throw new Error(`Parse error in ${file_path}`);
  }
  const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
  const result = check(ast, sink, fail_ev);
  if (has_errors(sink)) {
    throw new Error(`Type error in ${file_path}: ${sink.items.map((d: any) => d.message).join("; ")}`);
  }
  const js = generate(result.program, false, false, Option_none, Option_none, Option_none, Option_none, Option_none, Option_none, Option_none);
  return run_js_in_vm(strip_esm_lines(js));
}

function ring_run_multi(file_path: string): string {
  const tmp_dir = fs.mkdtempSync(path.join(REPO_ROOT, "tests/.tmp_esm_"));
  try {
    execSync(`node "${RING}" build "${file_path}" --out-dir="${tmp_dir}"`, {
      encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
    });
    const entry_name = path.basename(file_path, ".ring") + ".js";
    return execSync(`node "${path.join(tmp_dir, entry_name)}"`, {
      encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 10000,
    });
  } finally {
    fs.rmSync(tmp_dir, { recursive: true, force: true });
  }
}

function ring_run(file_path: string): string {
  const source = fs.readFileSync(file_path, "utf-8");
  if (/^use\s+|^pub\s+use\s+/m.test(source)) {
    return ring_run_multi(file_path);
  }
  return ring_run_single(file_path);
}

function ring_check(file_path: string): { success: boolean; error_output: string } {
  const sink = new_collecting_sink();
  try {
    const source = fs.readFileSync(file_path, "utf-8");
    const ast = parse(source, file_path, sink);
    if (has_errors(sink)) {
      const text = sink.items.filter((d: any) => d.severity._tag === "SevError").map((d: any) => `${d.code}: ${d.message}`).join("\n");
      return { success: false, error_output: text };
    }
    if (/^use\s+|^pub\s+use\s+/m.test(source)) {
      let captured_stderr = "";
      const orig_write = process.stderr.write;
      process.stderr.write = ((chunk: any, ...args: any[]) => {
        captured_stderr += typeof chunk === "string" ? chunk : chunk.toString();
        return true;
      }) as any;
      try {
        const result = compile_project(file_path);
        process.stderr.write = orig_write;
        if (!result.success) {
          return { success: false, error_output: captured_stderr || "Compilation failed" };
        }
        return { success: true, error_output: "" };
      } catch (e: any) {
        process.stderr.write = orig_write;
        return { success: false, error_output: captured_stderr || e.message || String(e) };
      }
    }
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    const result = check(ast, sink, fail_ev);
    if (has_errors(sink)) {
      const text = sink.items.filter((d: any) => d.severity._tag === "SevError").map((d: any) => `${d.code}: ${d.message}`).join("\n");
      return { success: false, error_output: text };
    }
    return { success: true, error_output: "" };
  } catch (err: any) {
    if (has_errors(sink)) {
      const text = sink.items.filter((d: any) => d.severity._tag === "SevError").map((d: any) => `${d.code}: ${d.message}`).join("\n");
      return { success: false, error_output: text };
    }
    const err_text = err.message || String(err);
    return { success: false, error_output: err_text };
  }
}

function ring_build_single(file_path: string): string {
  const source = fs.readFileSync(file_path, "utf-8");
  const sink = new_collecting_sink();
  const ast = parse(source, file_path, sink);
  const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
  const result = check(ast, sink, fail_ev);
  return generate(result.program, false, false, Option_none, Option_none, Option_none, Option_none, Option_none, Option_none, Option_none);
}

function ring_build_multi_esm(file_path: string): Map<string, string> {
  const dist_dir = path.join(path.dirname(file_path), "dist");
  if (fs.existsSync(dist_dir)) fs.rmSync(dist_dir, { recursive: true, force: true });
  fs.mkdirSync(dist_dir, { recursive: true });

  execSync(`node "${RING}" build "${file_path}" --out-dir="${dist_dir}"`, {
    encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
  });

  const files = new Map<string, string>();
  function walk(dir: string) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".js")) {
        files.set(path.relative(dist_dir, full), fs.readFileSync(full, "utf-8"));
      }
    }
  }
  walk(dist_dir);
  fs.rmSync(dist_dir, { recursive: true, force: true });
  return files;
}

// ============================================================
// Test cases
// ============================================================

interface TestCase {
  file: string;
  expected: string;
}

const cases: TestCase[] = [
  { file: "hello.ring", expected: "3\n" },
  { file: "enum_match.ring", expected: "red\n" },
  { file: "enum_named_fields.ring", expected: "enum_named_fields: all tests passed\n" },
  { file: "enum_named_fields_generic.ring", expected: "enum_named_fields_generic: all tests passed\n" },
  { file: "enum_named_mixed.ring", expected: "enum_named_mixed: all tests passed\n" },
  { file: "json_stringify.ring", expected: "json_stringify: all tests passed\n" },
  { file: "string_interp.ring", expected: "Hello, World!\n" },
  { file: "effect_or.ring", expected: "42\n" },
  { file: "effect_catch.ring", expected: "42\n" },
  { file: "effect_handle_fail.ring", expected: "42\n" },
  { file: "effect_handle_io.ring", expected: "got: mock-data\n" },
  { file: "effect_resume.ring", expected: "processed: mock-data\n" },
  { file: "trait_basic.ring", expected: "hello-trait\n" },
  { file: "trait_chain.ring", expected: "num\n" },
  { file: "trait_multi_call.ring", expected: "24\n" },
  { file: "effect_evidence.ring", expected: "mock-data\n" },
  { file: "effect_multi_handler.ring", expected: "file-content\n" },
  { file: "effect_propagate.ring", expected: "propagated\n" },
  { file: "effect_cell.ring", expected: "2\n" },
  { file: "effect_cell_closure.ring", expected: "3\n" },
  { file: "effect_resume_side.ring", expected: "reading: input.txt\nmock-result\n" },
  { file: "row_basic.ring", expected: "alice\n" },
  { file: "row_multi_field.ring", expected: "30\n" },
  { file: "row_generic.ring", expected: "whiskers-rex\n" },
  { file: "effect_row_strict.ring", expected: "3-mock-data\n" },
  { file: "effect_row_handle.ring", expected: "42\n" },
  { file: "effect_row_asymmetric.ring", expected: "effect_row_asymmetric: ok\n" },
  { file: "option_basic.ring", expected: "42\n" },
  { file: "option_unwrap.ring", expected: "43\n" },
  { file: "option_try.ring", expected: "42\n" },
  { file: "option_or.ring", expected: "141\n" },
  { file: "option_chain.ring", expected: "option_chain: all tests passed\n" },
  { file: "option_unwrap_method.ring", expected: "42\nhello\n" },
  { file: "catch_typed.ring", expected: "99\n" },
  { file: "catch_multi_arm.ring", expected: "catch_multi_arm: all tests passed\n" },
  { file: "catch_always_consumes.ring", expected: "catch_always_consumes: all tests passed\n" },
  { file: "match_wildcard.ring", expected: "yes\nno\nother\n" },
  { file: "try_nested.ring", expected: "-1\n6\n" },
  { file: "trait_higher_order.ring", expected: "num\n" },
  { file: "option_unwrap_none.ring", expected: "99\n6\n" },
  { file: "string_interp_nested.ring", expected: "sum: 3\nab1cd\n" },
  { file: "string_interp_fn_call.ring", expected: "string_interp_fn_call: all tests passed\n" },
  { file: "string_interp_nested_quotes.ring", expected: "string_interp_nested_quotes: all tests passed\n" },
  { file: "assign_compound.ring", expected: "12\n" },
  { file: "match_guard.ring", expected: "positive\nnegative\nzero\n" },
  { file: "else_if.ring", expected: "A\nB\nC\n" },
  { file: "trait_default.ring", expected: "Whiskers\n" },
  { file: "eq_strict.ring", expected: "true\ntrue\nfalse\ntrue\nfalse\n" },
  { file: "float_basic.ring", expected: "12.56\n" },
  { file: "bool_ops.ring", expected: "false\ntrue\nfalse\ntrue\n" },
  { file: "unary_ops.ring", expected: "-42\n5\n" },
  { file: "generic_basic.ring", expected: "42\nhello\n1\n" },
  { file: "lambda_arg.ring", expected: "42\n6\n" },
  { file: "lambda_infer_call.ring", expected: "lambda_infer_call: all tests passed\n" },
  { file: "return_early.ring", expected: "5\n3\n" },
  { file: "struct_basic.ring", expected: "25\n" },
  { file: "struct_update_test.ring", expected: "struct update: all tests passed\n" },
  { file: "struct_update_enum_test.ring", expected: "struct update enum: all tests passed\n" },
  { file: "struct_update_generic_test.ring", expected: "struct update generic: all tests passed\n" },
  { file: "struct_match_pattern.ring", expected: "struct_match_pattern: all tests passed\n" },
  { file: "ufcs_basic.ring", expected: "1\n" },
  { file: "match_guard_multi.ring", expected: "big circle\nsmall circle\nsquare\nrectangle\n" },
  { file: "match_nested.ring", expected: "positive\nnon-positive\nnothing\n" },
  { file: "nested_match_stmt.ring", expected: "42\ndeep\n" },
  { file: "trait_alias.ring", expected: "num\n" },
  { file: "return_if.ring", expected: "5\n3\npositive\nnegative\nzero\n" },
  { file: "if_else_if_return.ring", expected: "101\n-1\n51\n-2\n1\n" },
  { file: "while_basic.ring", expected: "10\n" },
  { file: "break_continue.ring", expected: "7\n" },
  { file: "for_range.ring", expected: "10\n" },
  { file: "for_range_nested.ring", expected: "9\n" },
  { file: "for_range_break.ring", expected: "10\n" },
  { file: "for_range_inclusive.ring", expected: "15\n1\n" },
  { file: "range_as_value.ring", expected: "pass: range as value\n" },
  { file: "range_inclusive_var.ring", expected: "pass: inclusive range var\n" },
  { file: "match_multi_stmt.ring", expected: "1\n2\n3\n" },
  { file: "match_string.ring", expected: "match_string: all tests passed\n" },
  { file: "str_methods.ring", expected: "13\ntrue\ntrue\ntrue\nHello\nHello, World!\nABC\nxyz\na_b_c\n" },
  { file: "str_methods_extended.ring", expected: "all str method tests passed\n" },
  { file: "str_split_index.ring", expected: "3\n2\nb\n" },
  { file: "list_basic.ring", expected: "3\nfalse\ntrue\n20\n10\n30\n" },
  { file: "list_transform.ring", expected: "4\n5\n2\n2\n" },
  { file: "list_concat_extend.ring", expected: "list_concat_extend: all tests passed\n" },
  { file: "list_hof.ring", expected: "5\n2\n2\ntrue\ntrue\n4\n" },
  { file: "list_fold.ring", expected: "10\n4\n" },
  { file: "list_for_in.ring", expected: "60\n" },
  { file: "list_hof_effect.ring", expected: "1\n2\n3\n3\n" },
  { file: "tuple_basic.ring", expected: "10\nhello\nx\n" },
  { file: "tuple_fn.ring", expected: "answer\n42\n" },
  { file: "tuple_multi_destructure.ring", expected: "9\n19\n" },
  { file: "tuple_exhaustive.ring", expected: "tf\nft\nt*\nf*\nxf\nft\n" },
  { file: "map_basic.ring", expected: "3\ntrue\nfalse\n4\n3\n" },
  { file: "map_methods.ring", expected: "b\n3\n3\ntrue\n2\n" },
  { file: "map_hof.ring", expected: "40\n2\n60\ntrue\n" },
  { file: "set_basic.ring", expected: "3\ntrue\nfalse\n4\n3\n" },
  { file: "set_ops.ring", expected: "4\n2\n1\n3\n" },
  { file: "set_for_in.ring", expected: "60\n" },
  { file: "set_hof.ring", expected: "2\n15\ntrue\ntrue\n" },
  { file: "if_let_basic.ring", expected: "42\nwas none\n" },
  { file: "if_let_map.ring", expected: "one\nnot found\n" },
  { file: "if_let_no_else.ring", expected: "4\n" },
  { file: "custom_effect.ring", expected: "hello\nworld\n" },
  { file: "trait_multi_bound.ring", expected: "btn: 12\n" },
  { file: "nested_handler.ring", expected: "inner-inner-file-outer-outer-file\n" },
  { file: "for_in_continue.ring", expected: "35\n" },
  { file: "empty_collection.ring", expected: "0\n0\n0\nfalse\ntrue\nnone\n0\nfalse\n0\nfalse\n0\nfalse\n" },
  { file: "extern_fn_basic.ring", expected: "42\n3.14\n" },
  { file: "str_byte_at.ring", expected: "h\no\nnone\n" },
  { file: "str_extra_methods.ring", expected: "00042\nababab\n65\nnone\n" },
  { file: "string_builder.ring", expected: "string_builder: all tests passed\n" },
  { file: "num_parse_format.ring", expected: "42\n-1\n3.14\n99\n" },
  { file: "type_alias.ring", expected: "42: hello\n" },
  { file: "for_map_destructure.ring", expected: "6\n" },
  { file: "block_expr_complex_stmts.ring", expected: "all block expr tests passed\n" },
  { file: "trait_hof_effect.ring", expected: "trait_hof_effect: all tests passed\n" },
  { file: "recursive_enum.ring", expected: "recursive_enum: all tests passed\n" },
  { file: "recursive_struct.ring", expected: "recursive_struct: all tests passed\n" },
  { file: "mutual_recursive_types.ring", expected: "Int\nfail<Int>\nFoo\n" },
  { file: "list_extra_methods.ring", expected: "list_extra_methods: all tests passed\n" },
  { file: "sort_by.ring", expected: "sort_by: all tests passed\n" },
  { file: "map_clone.ring", expected: "map_clone: all tests passed\n" },
  { file: "os_api_basic.ring", expected: "os_api_basic: all tests passed\n" },
  { file: "var_self_test.ring", expected: "all var_self tests passed\n" },
  { file: "enum_qualified.ring", expected: "red\nenum_qualified: all tests passed\n" },
  { file: "api_clone.ring", expected: "api_clone: all tests passed\n" },
  { file: "rc_mutator_share_ops.ring", expected: "rc_mutator_share_ops: all tests passed\n" },
  { file: "list_pop.ring", expected: "list_pop: all tests passed\n" },
  { file: "str_pad_end.ring", expected: "str_pad_end: all tests passed\n" },
  { file: "collection_clear.ring", expected: "collection_clear: all tests passed\n" },
  { file: "option_methods.ring", expected: "option_methods: all tests passed\n" },
  { file: "eq_struct.ring", expected: "eq_struct: all tests passed\n" },
  { file: "eq_enum.ring", expected: "eq_enum: all tests passed\n" },
  { file: "eq_generic.ring", expected: "eq_generic: all tests passed\n" },
  { file: "eq_nested.ring", expected: "eq_nested: all tests passed\n" },
  { file: "clone_struct.ring", expected: "clone_struct: all tests passed\n" },
  { file: "clone_enum.ring", expected: "clone_enum: all tests passed\n" },
  { file: "ord_struct.ring", expected: "ord_struct: all tests passed\n" },
  { file: "ord_enum.ring", expected: "ord_enum: all tests passed\n" },
  { file: "debug_basic.ring", expected: "debug_basic: all tests passed\n" },
  { file: "debug_generic.ring", expected: "debug_generic: all tests passed\n" },
  { file: "nested-closure-eq.ring", expected: "nested closure eq: all passed\n" },
  { file: "trait_generic_impl.ring", expected: "trait_generic_impl: all passed\n" },
  { file: "empty_list.ring", expected: "empty_list: all tests passed\n" },
  { file: "tuple_field_access.ring", expected: "tuple_field_access: all tests passed\n" },
  { file: "tuple_eq.ring", expected: "tuple_eq: all tests passed\n" },
  { file: "result_basic.ring", expected: "result_basic: all tests passed\n" },
  { file: "const_basic.ring", expected: "const_basic: all tests passed\n" },
  { file: "loop_basic.ring", expected: "loop_basic: all tests passed\n" },
  { file: "enum_variant_brace_disambig.ring", expected: "enum_variant_brace_disambig: all tests passed\n" },
  { file: "list_set.ring", expected: "list_set: all tests passed\n" },
  { file: "stdlib_native_methods.ring", expected: "stdlib_native_methods: all tests passed\n" },
  { file: "effect_annotation.ring", expected: "Hello, Ring\n5\n3\n6\n" },
  { file: "effect_annotation_extern.ring", expected: "effect_annotation_extern: passed\n" },
  { file: "cell_update.ring", expected: "cell_update: all tests passed\n" },
  { file: "closure_capture.ring", expected: "closure_capture: all tests passed\n" },
  { file: "effect_cell_method.ring", expected: "effect_cell_method: all tests passed\n" },
  { file: "effect_custom_multi_op.ring", expected: "effect_custom_multi_op: all tests passed\n" },
  { file: "effect_fail_or.ring", expected: "effect_fail_or: all tests passed\n" },
  { file: "enum_single_variant.ring", expected: "enum_single_variant: all tests passed\n" },
  { file: "expr_block.ring", expected: "expr_block: all tests passed\n" },
  { file: "for_list_methods.ring", expected: "for_list_methods: all tests passed\n" },
  { file: "generic_enum.ring", expected: "generic_enum: all tests passed\n" },
  { file: "generic_struct.ring", expected: "generic_struct: all tests passed\n" },
  { file: "handle_while_test.ring", expected: "3\n" },
  { file: "if_expr_type.ring", expected: "if_expr_type: all tests passed\n" },
  { file: "if_let_enum.ring", expected: "if_let_enum: all tests passed\n" },
  { file: "lambda_closure_effect.ring", expected: "lambda_closure_effect: all tests passed\n" },
  { file: "list_flat_map.ring", expected: "list_flat_map: all tests passed\n" },
  { file: "list_method_chain.ring", expected: "list_method_chain: all tests passed\n" },
  { file: "list_push_mutate.ring", expected: "list_push_mutate: all tests passed\n" },
  { file: "iterator.ring", expected: "iterator: all tests passed\n" },
  { file: "map_iteration.ring", expected: "map_iteration: all tests passed\n" },
  { file: "map_ufcs_bug.ring", expected: "ok\n" },
  { file: "match_enum_deep.ring", expected: "match_enum_deep: all tests passed\n" },
  { file: "match_literal.ring", expected: "match_literal: all tests passed\n" },
  { file: "match_return.ring", expected: "match_return: all tests passed\n" },
  { file: "match_tuple_pattern.ring", expected: "match_tuple_pattern: all tests passed\n" },
  { file: "recursive_fn.ring", expected: "recursive_fn: all tests passed\n" },
  { file: "set_methods.ring", expected: "set_methods: all tests passed\n" },
  { file: "string_escape.ring", expected: "string_escape: all tests passed\n" },
  { file: "struct_empty.ring", expected: "struct_empty: all tests passed\n" },
  { file: "struct_multi_impl.ring", expected: "struct_multi_impl: all tests passed\n" },
  { file: "trait_impl_method.ring", expected: "trait_impl_method: all tests passed\n" },
  { file: "type_alias_generic.ring", expected: "type_alias_generic: all tests passed\n" },
  { file: "ufcs_in_lambda.ring", expected: "ufcs_in_lambda: all tests passed\n" },
  { file: "var_reassign.ring", expected: "var_reassign: all tests passed\n" },
  { file: "while_nested.ring", expected: "while_nested: all tests passed\n" },
  { file: "mod_basic.ring", expected: "7\n25\n" },
  { file: "mod_struct.ring", expected: "75\n" },
  { file: "mod_impl.ring", expected: "75\nred\ngreen\n" },
  { file: "mod_qualified_type.ring", expected: "3,4\n" },
  { file: "mod_enum_variant.ring", expected: "red\ngreen-42\n1-2-3\n" },
  { file: "mod_alias_collision.ring", expected: "42\nhello\n" },
  { file: "mod_const_trait.ring", expected: "release-v42\n" },
  { file: "effect_annotation_multi.ring", expected: "reading 5\n5\ndefault\nreading 42\n42\nreading 10\n10\ncaught\n" },
  { file: "mut_param.ring", expected: "mut_param: all tests passed\n" },
  { file: "mod_self_path.ring", expected: "mod_self_path: all tests passed\n" },
  { file: "mod_relative_path.ring", expected: "mod_relative_path: all tests passed\n" },
  { file: "sig_basic.ring", expected: "sig_basic: all tests passed\n" },
  { file: "sig_with_effects.ring", expected: "sig_with_effects: all tests passed\n" },
  { file: "mod_capability.ring", expected: "Hello, world!\nmod_capability: all tests passed\n" },
  { file: "mod_requires_pure_fn.ring", expected: "hello world\nmod requires pure fn: ok\n" },
  { file: "fn_type_effect.ring", expected: "converting\nfn_type_effect: all tests passed\n" },
  { file: "fn_type_effect_poly.ring", expected: "fn_type_effect_poly: all tests passed\n" },
  { file: "impl_bounds.ring", expected: "impl_bounds: all tests passed\n" },
  { file: "bounded_impl_cross_type.ring", expected: "bounded_impl_cross_type: all tests passed\n" },
  { file: "collection_struct_equality.ring", expected: "collection_struct_equality: all tests passed\n" },
  { file: "int_division.ring", expected: "int_division: all tests passed\n" },
  { file: "effect_custom_typed.ring", expected: "effect_custom_typed: all tests passed\n" },
  { file: "effect_custom_and_fail.ring", expected: "effect_custom_and_fail: all tests passed\n" },
  { file: "effect_custom_catch.ring", expected: "effect_custom_catch: all tests passed\n" },
  { file: "effect_custom_deep_call.ring", expected: "effect_custom_deep_call: all tests passed\n" },
  { file: "effect_custom_multi_effect.ring", expected: "effect_custom_multi_effect: all tests passed\n" },
  { file: "effect_custom_nested_handle.ring", expected: "effect_custom_nested_handle: all tests passed\n" },
  { file: "let_mut_basic.ring", expected: "let_mut_basic: all tests passed\n" },
  { file: "let_mut_param.ring", expected: "let_mut_param: all tests passed\n" },
  { file: "let_mut_method.ring", expected: "let_mut_method: all tests passed\n" },
  { file: "let_mut_enforcement.ring", expected: "let_mut_enforcement: all tests passed\n" },
  { file: "impl_effect_propagation.ring", expected: "impl_effect_propagation: all tests passed\n" },
  { file: "impl_effect_chain.ring", expected: "impl_effect_chain: all tests passed\n" },
  { file: "impl_effect_order.ring", expected: "impl_effect_order: all tests passed\n" },
  { file: "impl_effect_intra.ring", expected: "impl_effect_intra: all tests passed\n" },
  { file: "catch_exhaustive.ring", expected: "catch exhaustive tests passed\n" },
  { file: "multiline_string.ring", expected: "multiline_string: all tests passed\n" },
  { file: "raw_string.ring", expected: "raw_string: all tests passed\n" },
  { file: "index_expr.ring", expected: "index_expr: all tests passed\n" },
  { file: "mut_param_enforcement.ring", expected: "mut_param_enforcement: all tests passed\n" },
  { file: "mod_nested_block.ring", expected: "mod_nested_block: all tests passed\n" },
  { file: "mod_nested_impl.ring", expected: "mod_nested_impl: all tests passed\n" },
  { file: "mod_struct_literal.ring", expected: "mod struct literal: ok\n" },
  { file: "mod_struct_pattern.ring", expected: "mod struct pattern: ok\n" },
  { file: "mod_struct_pattern_external.ring", expected: "mod struct pattern external: ok\n" },
  { file: "derive_tuple_fields.ring", expected: "pass: derive tuple\n" },
  { file: "nested_generic_ufcs.ring", expected: "nested generic ufcs: all ok\n" },
  { file: "derive_mod_qualified.ring", expected: "ok\n" },
  { file: "safe_ident_globals.ring", expected: "pass: safe_ident globals\n" },
  { file: "match_tuple_option.ring", expected: "pass: match tuple bare variant\n" },
  { file: "result_prelude.ring", expected: "pass: result prelude\n" },
  { file: "tuple_eq_struct.ring", expected: "pass: tuple eq struct\n" },
  { file: "tuple_option_sugar.ring", expected: "pass: tuple option sugar\n" },
  { file: "set_struct_eq.ring", expected: "pass: set struct eq consistency\n" },
  { file: "catch_pure_expr.ring", expected: "pass: catch on pure warning\n" },
  { file: "set_ops_deep_eq.ring", expected: "Set ops deep equality: all passed\n" },
  { file: "list_first_last.ring", expected: "List first/last empty: all passed\n" },
  { file: "effect_alias.ring", expected: "Hello, world\nEffect alias: all passed\n" },
  { file: "effect_alias_generic.ring", expected: "Generic effect alias: all passed\n" },
  { file: "effect_alias_shadowing.ring", expected: "hello world\nEffect alias shadowing: all passed\n" },
  { file: "supertrait_basic.ring", expected: "Supertrait basic: all passed\n" },
  { file: "supertrait_multi_level.ring", expected: "Supertrait multi-level: all passed\n" },
  { file: "supertrait_default_method.ring", expected: "Supertrait default method: passed\n" },
  { file: "effect_annot_fail_type_match.ring", expected: "0\n" },
  { file: "prelude_bounded_impl_call.ring", expected: "ok\n" },
  { file: "default_effect_handler.ring", expected: "Hello, World!\nHello, deep!\n" },
  { file: "default_effect_override.ring", expected: "DEFAULT: Hello, default!\nCUSTOM: Hello, override!\n" },
  { file: "default_effect_partial.ring", expected: "LOG: config\ndefault_effect_partial: all tests passed\n" },
  { file: "audit_partial_handle_default.ring", expected: "accessed: config\naudit_partial_handle_default: all tests passed\n" },
  { file: "default_effect_multi_op.ring", expected: "Name? \ndefault_effect_multi_op: all tests passed\n" },
  { file: "default_effect_sibling_op.ring", expected: "default effect sibling op: ok\n" },
  { file: "mut_effect_basic.ring", expected: "mut_effect_basic: all tests passed\n" },
  { file: "mut_effect_multi_type.ring", expected: "mut_effect_multi_type: all tests passed\n" },
  { file: "mut_effect_multi_match.ring", expected: "mut effect multi match: ok\n" },
  { file: "local_effect_cancellation.ring", expected: "1\n1\n2\n" },
  { file: "delegate_basic.ring", expected: "delegate_basic: all tests passed\n" },
  { file: "delegate_multi_trait.ring", expected: "delegate_multi_trait: all tests passed\n" },
  { file: "delegate_with_args.ring", expected: "delegate_with_args: all tests passed\n" },
  { file: "delegate_generic.ring", expected: "delegate_generic: all tests passed\n" },
  { file: "delegate_supertrait_bound.ring", expected: "Alice\nHello, Alice!\ndelegate_supertrait_bound: all tests passed\n" },
  { file: "effect_alias_dedup.ring", expected: "hello\neffect_alias_dedup: all tests passed\n" },
  { file: "io_effect_annotation.ring", expected: "hello world\nhello ring\nio_effect_annotation: all tests passed\n" },
  { file: "delegate_in_mod.ring", expected: "delegate_in_mod: all tests passed\n" },
  { file: "delegate_eq.ring", expected: "delegate_eq: all tests passed\n" },
  { file: "delegate_default_method.ring", expected: "delegate_default_method: all tests passed\n" },
  { file: "delegate_with_effects.ring", expected: "logging: test\ndelegate with effects: ok\n" },
  { file: "delegate_mut_self.ring", expected: "ok\n" },
  { file: "delegate_assoc_type.ring", expected: "delegate_assoc_type: ok\n" },
  { file: "mod_effect_evidence.ring", expected: "mod effect evidence: ok\n" },
  { file: "mod_derive_no_dup.ring", expected: "mod derive no dup: ok\n" },
  { file: "mod_effect_qualified.ring", expected: "mod effect qualified: ok\n" },
  { file: "trait_default_ufcs.ring", expected: "trait default ufcs: ok\n" },
  { file: "default_effect_body_io.ring", expected: "TAG\nLOG: hello tagged\ndefault effect body io: ok\n" },
  { file: "mod_supertrait_incremental.ring", expected: "mod supertrait incremental: ok\n" },
  { file: "auto_boxing_closure.ring", expected: "auto_boxing_closure: all tests passed\n" },
  { file: "auto_boxing_mut_param.ring", expected: "auto_boxing_mut_param: all tests passed\n" },
  { file: "auto_boxing_local.ring", expected: "auto_boxing_local: all tests passed\n" },
  { file: "mod_effect_qualified_op.ring", expected: "hello\nworld\n" },
  { file: "default_effect_topo.ring", expected: "default_effect_topo: ok\n" },
  { file: "impl_qualified_path.ring", expected: "ok\n" },
  { file: "return_in_expr_block.ring", expected: "return_in_expr_block: ok\n" },
  { file: "trait_fn_param.ring", expected: "trait fn param: ok\n" },
  { file: "effect_merge_same_kind.ring", expected: "effect merge same kind: ok\n" },
  { file: "debug_fn_field.ring", expected: "Callback { name: double, action: <fn> }\n" },
  { file: "assoc_type_basic.ring", expected: "assoc type basic: ok\n" },
  { file: "assoc_type_qualified.ring", expected: "assoc type qualified: ok\n" },
  { file: "assoc_type_default.ring", expected: "assoc type default: ok\n" },
  { file: "assoc_type_constraint.ring", expected: "assoc type constraint: ok\n" },
  { file: "assoc_type_qualified_multi.ring", expected: "assoc_type_qualified_multi: ok\n" },
  { file: "assoc_type_bound.ring", expected: "assoc type bound: ok\n" },
  { file: "assoc_type_self_item.ring", expected: "assoc_type_self_item: ok\n" },
  { file: "or_pattern.ring", expected: "or pattern: ok\n" },
  { file: "exhaustive_generic_payload.ring", expected: "exhaustive_generic_payload: all tests passed\n" },
  { file: "where_clause_warning.ring", expected: "5\n" },
];

describe("e2e: ring run", { concurrency: true }, () => {
  for (const tc of cases) {
    test(`ring run ${tc.file}`, () => {
      const filePath = path.join(CASES_DIR, tc.file);
      assert.ok(fs.existsSync(filePath), `Test file not found: ${filePath}`);
      const output = ring_run(filePath);
      assert.strictEqual(output, tc.expected);
    });
  }
});

describe("e2e: ring check (negative — should reject)", { concurrency: true }, () => {
  const negative_cases = [
    { file: "row_reject.ring", error_pattern: "E0301" },
    { file: "error_multi_parse.ring", error_pattern: "E0103" },
    { file: "error_type_context.ring", error_pattern: "E0301" },
    { file: "error_multi_type.ring", error_pattern: "E0301" },
    { file: "error_multi_type_fn.ring", error_pattern: "E0301" },
    { file: "error_arity.ring", error_pattern: "E0301" },
    { file: "error_undefined.ring", error_pattern: "E0201" },
    { file: "error_operator.ring", error_pattern: "E0303" },
    { file: "error_nonexhaustive.ring", error_pattern: "E0601" },
    { file: "error_undef_method.ring", error_pattern: "E0305" },
    { file: "error_missing_field.ring", error_pattern: "E0203" },
    { file: "error_assign_immutable.ring", error_pattern: "E0205" },
    { file: "error_break_outside.ring", error_pattern: "E0206" },
    { file: "error_unterminated_str.ring", error_pattern: "E0102" },
    { file: "error_unterminated_interp.ring", error_pattern: "Unterminated string interpolation" },
    { file: "error_unknown_type.ring", error_pattern: "E0204" },
    { file: "error_numeric_required.ring", error_pattern: "E0303" },
    { file: "error_field_non_struct.ring", error_pattern: "E0304" },
    { file: "error_unknown_effect_op.ring", error_pattern: "E0402" },
    { file: "error_unknown_trait.ring", error_pattern: "E0501" },
    { file: "error_unsatisfied_bound.ring", error_pattern: "E0503" },
    { file: "error_occurs_check.ring", error_pattern: "E0302" },
    { file: "error_tuple_cross_exhaust.ring", error_pattern: "E0601" },
    { file: "enum_named_wrong_field.ring", error_pattern: "E0203" },
    { file: "enum_named_missing_field.ring", error_pattern: "E0203" },
    { file: "negative/struct_update_wrong_type.ring", error_pattern: "E0301" },
    { file: "neg_field_assign_immutable.ring", error_pattern: "E0205" },
    { file: "neg_let_field_assign.ring", error_pattern: "E0205" },
    { file: "error_no_eq.ring", error_pattern: "E0307" },
    { file: "error_no_ord.ring", error_pattern: "E0308" },
    { file: "error_tuple_oob.ring", error_pattern: "E0304" },
    { file: "error_enum_empty_parens.ring", error_pattern: "E0104" },
    { file: "error_const_reassign.ring", error_pattern: "E0205" },
    { file: "error_with_suggestion.ring", error_pattern: "E0301" },
    { file: "effect_annotation_violation.ring", error_pattern: "E0404" },
    { file: "mut_param_mismatch.ring", error_pattern: "E0404" },
    { file: "error_missing_impl_method.ring", error_pattern: "E0502" },
    { file: "error_nested_match.ring", error_pattern: "E0601" },
    { file: "error_unexpected_token.ring", error_pattern: "E0101" },
    { file: "error_duplicate_def.ring", error_pattern: "E0207" },
    { file: "error_use_after_decl.ring", error_pattern: "E0706" },
    { file: "error_mut_method_on_let.ring", error_pattern: "E0208" },
    { file: "error_mut_param_enforcement.ring", error_pattern: "E0208" },
    { file: "errors/mod_super_out_of_scope.ring", error_pattern: "E0705" },
    { file: "errors/mod_capability_violation.ring", error_pattern: "E0405" },
    { file: "errors/mod_capability_impl.ring", error_pattern: "E0405" },
    { file: "catch_non_exhaustive_fail.ring", error_pattern: "E0601" },
    { file: "error_unhandled_effect.ring", error_pattern: "E0403" },
    { file: "error_assign_temp_field.ring", error_pattern: "E0205" },
    { file: "try_reserved.ring", error_pattern: "E0101" },
    { file: "exhaustive_nonfinite_msg.ring", error_pattern: "non-finite type" },
    { file: "effect_alias_cycle.ring", error_pattern: "E0406" },
    { file: "unknown_effect.ring", error_pattern: "E0407" },
    { file: "effect_annot_fail_type_mismatch.ring", error_pattern: "E0301" },
    { file: "error_supertrait_missing_impl.ring", error_pattern: "E0505" },
    { file: "error_supertrait_cycle.ring", error_pattern: "E0501" },
    { file: "error_generic_numeric_op.ring", error_pattern: "E0303" },
    { file: "error_default_effect_partial_unhandled.ring", error_pattern: "E0403" },
    { file: "error_mut_effect_in_pure_mod.ring", error_pattern: "E0405" },
    { file: "error_delegate_no_field.ring", error_pattern: "E0507" },
    { file: "error_delegate_no_impl.ring", error_pattern: "E0508" },
    { file: "delegate_conflict.ring", error_pattern: "E0509" },
    { file: "error_default_effect_cycle.ring", error_pattern: "E0410" },
    { file: "error_default_effect_no_default.ring", error_pattern: "E0409" },
    { file: "error_assoc_type_missing.ring", error_pattern: "E0510" },
    { file: "error_assoc_type_unknown.ring", error_pattern: "E0511" },
    { file: "error_assoc_type_constraint_mismatch.ring", error_pattern: "E0513" },
    { file: "error_assoc_type_bound.ring", error_pattern: "E0513" },
    { file: "error_assoc_type_name_display.ring", error_pattern: "Item" },
    { file: "error_impl_target_type_arg.ring", error_pattern: "E0105" },
    { file: "error_diagnostic_notes.ring", error_pattern: "E0301" },
  ];

  for (const tc of negative_cases) {
    test(`ring check ${tc.file} should fail with "${tc.error_pattern}"`, () => {
      const filePath = path.join(CASES_DIR, tc.file);
      assert.ok(fs.existsSync(filePath), `Test file not found: ${filePath}`);
      const result = ring_check(filePath);
      assert.ok(!result.success, `Expected ${tc.file} to fail type checking`);
      assert.ok(
        result.error_output.toLowerCase().includes(tc.error_pattern.toLowerCase()),
        `Expected error containing "${tc.error_pattern}", got: ${result.error_output.slice(0, 200)}`
      );
    });
  }
});

// ============================================================
// Warning tests — should pass type-check but emit warnings
// ============================================================

describe("e2e: warnings (should pass check but emit warning)", { concurrency: true }, () => {
  test("catch on pure expression emits W0001 warning but succeeds", () => {
    const filePath = path.join(CASES_DIR, "catch_pure_expr.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    const result = check(ast, sink, fail_ev);
    // Should have no errors
    assert.ok(!has_errors(sink), "Expected no errors");
    // Should have at least one warning with W0001
    const warnings = sink.items.filter((d: any) => d.severity._tag === "SevWarning");
    assert.ok(warnings.length > 0, "Expected at least one warning");
    assert.ok(warnings.some((w: any) => w.code === "W0001"), "Expected W0001 warning code");
  });

  // B-112: refinement 'where' clauses parse but are not enforced; W0002 makes
  // that visible. Remove these three tests together with the warning when
  // refinement types (B-001) land.
  test("refinement where clause emits W0002 warning but succeeds", () => {
    const filePath = path.join(CASES_DIR, "where_clause_warning.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    parse(source, filePath, sink);
    assert.ok(!has_errors(sink), "Expected no errors");
    const warnings = sink.items.filter((d: any) => d.severity._tag === "SevWarning");
    assert.ok(warnings.some((w: any) => w.code === "W0002"), "Expected W0002 warning code");
    const w = warnings.find((w: any) => w.code === "W0002") as any;
    // Span must point at the 'where' token (line 11 of the test case)
    assert.equal(w.span.start.line, 11, "Expected W0002 span on the where clause line");
  });

  test("CLI check surfaces W0002 on stderr (human format), exit 0", () => {
    const filePath = path.join(CASES_DIR, "where_clause_warning.ring");
    const r = spawnSync("node", [RING, "check", filePath], { encoding: "utf-8", timeout: 15000 });
    assert.equal(r.status, 0, `Expected exit 0, got ${r.status}; stderr: ${(r.stderr || "").slice(0, 200)}`);
    assert.ok(r.stdout.includes("OK"), `Expected 'OK' on stdout, got: ${r.stdout.slice(0, 200)}`);
    assert.ok(r.stderr.includes("warning[W0002]"), `Expected 'warning[W0002]' on stderr, got: ${r.stderr.slice(0, 300)}`);
  });

  test("CLI check --error-format=llm surfaces W0002 as JSON on stderr, exit 0", () => {
    const filePath = path.join(CASES_DIR, "where_clause_warning.ring");
    const r = spawnSync("node", [RING, "check", filePath, "--error-format=llm"], { encoding: "utf-8", timeout: 15000 });
    assert.equal(r.status, 0, `Expected exit 0, got ${r.status}; stderr: ${(r.stderr || "").slice(0, 200)}`);
    assert.ok(r.stdout.includes("OK"), `Expected 'OK' on stdout, got: ${r.stdout.slice(0, 200)}`);
    const parsed = JSON.parse(r.stderr);
    assert.ok(
      parsed.diagnostics.some((d: any) => d.code === "W0002" && d.severity === "warning"),
      `Expected W0002 warning in LLM JSON, got: ${r.stderr.slice(0, 300)}`
    );
  });
});

// ============================================================
// Diagnostic quality tests — suggestions and categories
// ============================================================

describe("e2e: diagnostic suggestions and categories", { concurrency: true }, () => {
  test("type mismatch Str/Int produces conversion suggestion", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const diags = sink.items.filter((d: any) => d.severity._tag === "SevError");
    assert.ok(diags.length > 0, "Expected at least one error diagnostic");
    const d = diags[0] as any;
    // Verify category is set
    assert.ok(d.category._tag === "some", "Expected category to be set");
    assert.equal(d.category._0, "type", "Expected category 'type' for E0301");
    // Verify suggestions contain conversion hint
    assert.ok(d.suggestions.length > 0, "Expected at least one suggestion");
    const sugText = d.suggestions.map((s: any) => s.message).join(" ");
    assert.ok(sugText.includes("parse_int"), `Expected suggestion about parse_int, got: ${sugText}`);
  });

  test("format_llm includes category field", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const json_output = format_llm(sink.items, filePath);
    const parsed = JSON.parse(json_output);
    assert.ok(parsed.diagnostics.length > 0, "Expected diagnostics in LLM output");
    const d = parsed.diagnostics[0];
    assert.equal(d.category, "type", "Expected category 'type' in LLM JSON output");
    assert.ok(d.suggestions.length > 0, "Expected suggestions in LLM JSON output");
    assert.ok(d.suggestions[0].message.includes("parse_int"), "Expected parse_int in suggestion");
  });

  test("format_human includes help line for suggestions", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const human_output = format_human(sink.items, source);
    assert.ok(human_output.includes("help:"), `Expected 'help:' in human output, got: ${human_output.slice(0, 300)}`);
    assert.ok(human_output.includes("parse_int"), `Expected 'parse_int' in human output, got: ${human_output.slice(0, 300)}`);
  });

  test("type mismatch diagnostic includes notes with constraint source", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const diags = sink.items.filter((d: any) => d.severity._tag === "SevError");
    assert.ok(diags.length > 0, "Expected at least one error diagnostic");
    const d = diags[0] as any;
    // Verify notes are present
    assert.ok(d.notes.length >= 2, `Expected at least 2 notes, got ${d.notes.length}`);
    // First note explains why the type was expected
    assert.ok(d.notes[0].message.includes("expected") && d.notes[0].message.includes("Int"),
      `Expected note about expected type, got: ${d.notes[0].message}`);
    // Second note explains the actual type
    assert.ok(d.notes[1].message.includes("Str"),
      `Expected note about actual type Str, got: ${d.notes[1].message}`);
  });

  test("format_human renders note: lines", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const human_output = format_human(sink.items, source);
    assert.ok(human_output.includes("note:"), `Expected 'note:' in human output, got: ${human_output.slice(0, 500)}`);
    assert.ok(human_output.includes("expected"), `Expected 'expected' in note text, got: ${human_output.slice(0, 500)}`);
  });

  test("format_llm includes notes array in JSON output", () => {
    const filePath = path.join(CASES_DIR, "error_with_suggestion.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const json_output = format_llm(sink.items, filePath);
    const parsed = JSON.parse(json_output);
    assert.ok(parsed.diagnostics.length > 0, "Expected diagnostics in LLM output");
    const d = parsed.diagnostics[0];
    assert.ok(Array.isArray(d.notes), "Expected notes to be an array in LLM JSON");
    assert.ok(d.notes.length >= 2, `Expected at least 2 notes in LLM JSON, got ${d.notes.length}`);
    assert.ok(d.notes[0].message.includes("expected"), `Expected constraint source note, got: ${d.notes[0].message}`);
  });

  test("function return type mismatch includes constraint notes", () => {
    const filePath = path.join(CASES_DIR, "error_diagnostic_notes.ring");
    const source = fs.readFileSync(filePath, "utf-8");
    const sink = new_collecting_sink();
    const ast = parse(source, filePath, sink);
    const fail_ev = { raise: (err: any) => { throw { _effect: "fail", _value: err }; } };
    try { check(ast, sink, fail_ev); } catch {}
    const diags = sink.items.filter((d: any) => d.severity._tag === "SevError");
    assert.ok(diags.length > 0, "Expected at least one error for return type mismatch");
    const d = diags[0] as any;
    assert.ok(d.notes.length >= 2, `Expected at least 2 notes for return type mismatch, got ${d.notes.length}`);
    // Notes should explain the function return type and body type
    const noteText = d.notes.map((n: any) => n.message).join(" ");
    assert.ok(noteText.includes("return type") || noteText.includes("declared"),
      `Expected note about declared return type, got: ${noteText}`);
    assert.ok(noteText.includes("body") || noteText.includes("evaluates"),
      `Expected note about function body type, got: ${noteText}`);
  });
});

// ============================================================
// Multi-file module tests
// ============================================================

interface ModuleTestCase {
  dir: string;
  expected: string;
}

const module_cases: ModuleTestCase[] = [
  { dir: "basic_import", expected: "hello from lib\n" },
  { dir: "import_struct", expected: "5\n" },
  { dir: "import_enum", expected: "red\n" },
  { dir: "multi_import", expected: "7\n12\n" },
  { dir: "diamond_dep", expected: "11\n12\n" },
  { dir: "pub_use", expected: "re-exported\n" },
  { dir: "cross_module_method", expected: "75\n" },
  { dir: "io_in_main", expected: "7\n" },
  { dir: "cross_option", expected: "42\n99\n" },
  { dir: "cross_effect", expected: "5\n-1\n" },
  { dir: "cross_trait", expected: "Rex\n" },
  { dir: "extern_fn", expected: "100\n2.5\n42\n" },
  { dir: "extern_type", expected: "42\n7\n" },
  { dir: "esm_verify", expected: "hello, world\n3\n" },
  { dir: "mod_export_effect", expected: "Hello, World!\n" },
  { dir: "multifile_mut_export", expected: "multifile_mut_export: all tests passed\n" },
  { dir: "cross_module_const", expected: "cross_module_const: all tests passed\n" },
];

describe("e2e: multi-file modules (ring run)", { concurrency: true }, () => {
  for (const tc of module_cases) {
    test(`modules/${tc.dir}`, () => {
      const mainFile = path.join(MODULES_DIR, tc.dir, "main.ring");
      assert.ok(fs.existsSync(mainFile), `Test entry not found: ${mainFile}`);
      const tmp_dir = fs.mkdtempSync(path.join(REPO_ROOT, "tests/.tmp_esm_"));
      try {
        fs.mkdirSync(tmp_dir, { recursive: true });
      execSync(`node "${RING}" build "${mainFile}" --out-dir="${tmp_dir}"`, {
          encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
        });
        const output = execSync(`node "${path.join(tmp_dir, "main.js")}"`, {
          encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 10000,
        });
        assert.strictEqual(output, tc.expected);
      } finally {
        fs.rmSync(tmp_dir, { recursive: true, force: true });
      }
    });
  }
});

describe("e2e: multi-file modules (ring check)", { concurrency: true }, () => {
  for (const tc of module_cases) {
    test(`modules/${tc.dir} check`, () => {
      const mainFile = path.join(MODULES_DIR, tc.dir, "main.ring");
      const result = ring_check(mainFile);
      assert.ok(result.success, `Expected check to pass, got: ${result.error_output.slice(0, 200)}`);
    });
  }
});

describe("e2e: multi-file modules (negative)", () => {
  const module_negative_cases = [
    { dir: "error_not_found", desc: "missing module", error_pattern: "E0702" },
    { dir: "error_circular", desc: "circular dependency", error_pattern: "E0704" },
    { dir: "error_private_import", desc: "private symbol import", error_pattern: "E0703" },
    { dir: "error_symbol_not_found", desc: "symbol not found in module", error_pattern: "E0703" },
    { dir: "error_cross_mut_immutable", desc: "immutable binding calling cross-module mut method", error_pattern: "E0208" },
  ];

  for (const tc of module_negative_cases) {
    test(`modules/${tc.dir} should fail with ${tc.error_pattern} (${tc.desc})`, () => {
      const mainFile = path.join(MODULES_DIR, tc.dir, "main.ring");
      assert.ok(fs.existsSync(mainFile), `Test entry not found: ${mainFile}`);
      const result = ring_check(mainFile);
      assert.ok(!result.success, `Expected compilation to fail for ${tc.dir}`);
      assert.ok(
        result.error_output.includes(tc.error_pattern),
        `Expected error containing "${tc.error_pattern}", got: ${result.error_output.slice(0, 300)}`
      );
    });
  }
});

describe("e2e: --error-format=llm", { concurrency: true }, () => {
  test("outputs valid JSON for parse errors", () => {
    let output: string;
    try {
      output = execSync(`node "${RING}" check "${path.join(CASES_DIR, "error_multi_parse.ring")}" --error-format=llm`, {
        encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
      }).trim();
    } catch (err: any) {
      // Process exits with code 1 on parse errors — stdout has the JSON
      output = (err.stdout || "").trim();
    }
    const parsed = JSON.parse(output);
    assert.equal(parsed.version, 1);
    assert.ok(parsed.diagnostics.length >= 1);
    assert.ok(parsed.diagnostics[0].code.startsWith("E01"));
  });

  test("outputs nothing special for valid files", () => {
    const result = ring_check(path.join(CASES_DIR, "hello.ring"));
    assert.ok(result.success);
  });
});

// ============================================================
// Compiler determinism — same input must produce identical JS
// ============================================================

describe("determinism: single-file", { concurrency: true }, () => {
  for (const tc of cases) {
    test(`build ${tc.file} is deterministic`, () => {
      const filePath = path.join(CASES_DIR, tc.file);
      const js1 = ring_build_single(filePath);
      const js2 = ring_build_single(filePath);
      assert.strictEqual(js1, js2);
    });
  }
});

describe("determinism: multi-file modules", { concurrency: true }, () => {
  for (const tc of module_cases) {
    test(`build modules/${tc.dir} is deterministic`, () => {
      const mainFile = path.join(MODULES_DIR, tc.dir, "main.ring");
      const js1 = ring_build_multi_esm(mainFile);
      const js2 = ring_build_multi_esm(mainFile);
      assert.strictEqual(js1.size, js2.size, "different number of output files");
      for (const [file, content] of js1) {
        assert.ok(js2.has(file), `file ${file} missing in second build`);
        assert.strictEqual(content, js2.get(file), `content differs: ${file}`);
      }
    });
  }
});

describe("e2e: ESM output structure", () => {
  test("ring build produces dist/ with separate .js files", () => {
    const mainFile = path.join(MODULES_DIR, "esm_verify", "main.ring");
    const dist_dir = path.join(MODULES_DIR, "esm_verify", "dist");

    if (fs.existsSync(dist_dir)) fs.rmSync(dist_dir, { recursive: true, force: true });
    fs.mkdirSync(dist_dir, { recursive: true });

    execSync(`node "${RING}" build "${mainFile}" --out-dir="${dist_dir}"`, {
      encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
    });

    assert.ok(fs.existsSync(path.join(dist_dir, "__ring_runtime.js")), "runtime.js exists");
    assert.ok(fs.existsSync(path.join(dist_dir, "main.js")), "main.js exists");
    assert.ok(fs.existsSync(path.join(dist_dir, "lib.js")), "lib.js exists");

    const main_js = fs.readFileSync(path.join(dist_dir, "main.js"), "utf-8");
    assert.ok(main_js.includes("import "), "main.js has import statements");
    assert.ok(main_js.includes("__ring_runtime.js"), "main.js imports runtime");
    assert.ok(main_js.includes("from \"./lib.js\""), "main.js imports lib");

    const lib_js = fs.readFileSync(path.join(dist_dir, "lib.js"), "utf-8");
    assert.ok(lib_js.includes("export {"), "lib.js has export statement");
    assert.ok(lib_js.includes("greet"), "lib.js exports greet");

    const output = execSync(`node "${path.join(dist_dir, "main.js")}"`, {
      encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000,
    });
    assert.strictEqual(output, "hello, world\n3\n");

    fs.rmSync(dist_dir, { recursive: true, force: true });
  });
});
