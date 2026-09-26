use ast::{Program}
use hir::{HProgram}
use diagnostics::{CollectingSink, Diagnostic, new_collecting_sink}
use formatter::{format_human, format_llm}
use checker::{CheckResult, check as check_single}
use codegen::{generate}
use codegen_llvm::{generate_llvm}
use compiler_mod::{compile_project, compile_project_esm, compile_project_llvm}
use parser::{parse}
use perceus::{perceus_transform}

pub fn cli_main() {
    let args = argv()
    let parsed = parse_cli_args(args)

    if parsed.command == "help" || parsed.command == "" {
        usage()
        return
    }

    if parsed.command == "lsp" {
        // LSP not yet supported in Ring bootstrap
        eprintln("LSP mode not available in Ring compiler")
        exit_process(1)
        return
    }

    if parsed.file == "" {
        eprintln("Error: no input file specified.")
        exit_process(1)
        return
    }

    let file_path = path_resolve(parsed.file)
    if file_exists(file_path) == false {
        eprintln("Error: file not found: ${file_path}")
        exit_process(1)
        return
    }

    let source = read_file(file_path)
    let parse_sink = new_collecting_sink()
    let ast = parse(source, file_path, parse_sink)

    if parse_sink.has_errors() {
        let diagnostics = parse_sink.items
        if parsed.error_format == "llm" {
            print(format_llm(diagnostics, file_path))
        } else {
            eprintln(format_human(diagnostics, source))
        }
        exit_process(1)
        return
    }

    // Multi-file mode
    if ast.uses.len() > 0 {
        if parsed.target == "llvm" {
            // LLVM multi-file mode: all modules → single .o
            if parsed.command == "check" {
                let result = compile_project(file_path)
                if result.success {
                    print("OK")
                } else {
                    eprintln("Compilation failed")
                    exit_process(1)
                }
            } else {
                if parsed.command == "build" {
                    let out_dir = path_resolve(parsed.out_dir)
                    let out_path = path_join(out_dir, path_basename(file_path).replace(".ring", ".o"))
                    let result = compile_project_llvm(file_path, out_path)
                    if result.success {
                        // success message printed by generate_llvm_project
                    } else {
                        eprintln("Compilation failed")
                        exit_process(1)
                    }
                } else {
                    eprintln("LLVM target only supports 'build' and 'check' commands")
                    exit_process(1)
                }
            }
            return
        }
        if parsed.command == "check" {
            let result = compile_project(file_path)
            if result.success {
                print("OK")
            } else {
                eprintln("Compilation failed")
                exit_process(1)
            }
        } else {
            if parsed.command == "build" {
                let out_dir = path_resolve(parsed.out_dir)
                let result = compile_project_esm(file_path, out_dir)
                if result.success {
                    print("Compiled: ${out_dir}/")
                } else {
                    eprintln("Compilation failed")
                    exit_process(1)
                }
            } else {
                if parsed.command == "run" {
                    // Use temp dir for ESM output
                    let tmp_dir = path_join(path_dirname(file_path), ".ring_tmp")
                    let result = compile_project_esm(file_path, tmp_dir)
                    if result.success {
                        // Execute the entry JS file
                        // Note: exec_sync not yet available as extern fn
                        eprintln("Multi-file run not yet implemented in Ring bootstrap")
                        exit_process(1)
                    } else {
                        eprintln("Compilation failed")
                        exit_process(1)
                    }
                } else {
                    eprintln("Unknown command: ${parsed.command}")
                    exit_process(1)
                }
            }
        }
        return
    }

    // Single-file mode
    let sink = new_collecting_sink()
    let check_result = check_single(ast, sink)

    if sink.has_errors() {
        let diagnostics = sink.items
        if parsed.error_format == "llm" {
            print(format_llm(diagnostics, file_path))
        } else {
            eprintln(format_human(diagnostics, source))
        }
        exit_process(1)
        return
    }

    // Surface warnings (non-error diagnostics) even on success — to stderr,
    // so stdout keeps its success contract ("OK" / "Compiled: ...") and the
    // exit code is unchanged. Includes parser warnings (e.g. W0002 refinement
    // 'where' clause) and checker warnings (e.g. W0001 catch on pure expr).
    let mut warning_diags: List<Diagnostic> = []
    for d in parse_sink.items { warning_diags.push(d) }
    for d in sink.items { warning_diags.push(d) }
    if warning_diags.len() > 0 {
        if parsed.error_format == "llm" {
            eprintln(format_llm(warning_diags, file_path))
        } else {
            eprintln(format_human(warning_diags, source))
        }
    }

    if parsed.target == "llvm" {
        if parsed.command == "check" {
            print("OK")
        } else {
            if parsed.command == "build" {
                let out_path = file_path.replace(".ring", ".o")
                let rc_program = perceus_transform(check_result.program)
                generate_llvm(rc_program, out_path)
            } else {
                eprintln("LLVM target only supports 'build' and 'check' commands")
                exit_process(1)
            }
        }
        return
    }

    let js = generate(check_result.program, false, false, none, none, none, none, none, none, none)

    if parsed.command == "check" {
        print("OK")
    } else {
        if parsed.command == "build" {
            let out_path = file_path.replace(".ring", ".js")
            write_file(out_path, js)
            print("Compiled: ${out_path}")
        } else {
            if parsed.command == "run" {
                let tmp_file = path_join(path_dirname(file_path), ".ring_tmp_run.js")
                write_file(tmp_file, js)
                // Note: exec_sync needed for run
                eprintln("Single-file run not yet implemented in Ring bootstrap")
                exit_process(1)
            } else {
                eprintln("Unknown command: ${parsed.command}")
                exit_process(1)
            }
        }
    }
}

// ============================================================
// Argument parsing
// ============================================================

struct CliArgs {
    command: Str,
    file: Str,
    debug: Bool,
    error_format: Str,
    out_dir: Str,
    target: Str
}

fn parse_cli_args(args: List<Str>) -> CliArgs {
    let mut debug = false
    let mut error_format = "human"
    let mut out_dir = "dist"
    let mut target = "js"
    let mut positional: List<Str> = []

    for arg in args {
        if arg == "--debug" {
            debug = true
        } else {
            if arg.starts_with("--error-format=") {
                error_format = arg.slice(15, arg.len())
            } else {
                if arg.starts_with("--out-dir=") {
                    out_dir = arg.slice(10, arg.len())
                } else {
                    if arg.starts_with("--target=") {
                        target = arg.slice(9, arg.len())
                    } else {
                        positional.push(arg)
                    }
                }
            }
        }
    }

    let command = match positional.get(0) { some(c) => c, none => "help" }
    let file = match positional.get(1) { some(f) => f, none => "" }

    CliArgs {
        command: command,
        file: file,
        debug: debug,
        error_format: error_format,
        out_dir: out_dir,
        target: target
    }
}

fn usage() {
    print("Ring-lang compiler v0.1.0 (Ring bootstrap)")
    print("")
    print("Usage:")
    print("  ring build <file.ring>    Compile to .js file(s)")
    print("  ring run <file.ring>      Compile and execute with Node.js")
    print("  ring check <file.ring>    Type-check only")
    print("  ring help                 Show this help")
    print("")
    print("Options:")
    print("  --debug                   Print intermediate info")
    print("  --error-format=human|llm  Error output format (default: human)")
    print("  --out-dir=<path>          Output directory (default: dist)")
    print("  --target=js|llvm          Code generation target (default: js)")
}
