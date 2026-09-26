use ast::{Program, Span, Position}
use parser::{parse}
use diagnostics::{CollectingSink, Diagnostic, Severity, DiagnosticContext,
    new_collecting_sink, make_diag}
use formatter::{format_human}
use codes::{E0702, E0704}

// ============================================================
// Types
// ============================================================

pub struct ModuleId {
    pub path_segments: List<Str>,
    pub file_path: Str
}

pub struct ModuleGraph {
    pub entry: ModuleId,
    pub modules: Map<Str, ModuleId>,
    pub dependencies: Map<Str, List<Str>>,
    pub topo_order: List<Str>,
    pub asts: Map<Str, Program>
}

pub struct GraphError {
    pub message: Str,
    pub cycle: List<Str>?
}

// ============================================================
// Utility functions
// ============================================================

pub fn module_key(segments: List<Str>) -> Str {
    segments.join("::")
}

pub fn module_prefix(segments: List<Str>) -> Str {
    segments.join("$")
}

pub fn resolve_module_file(use_path_segments: List<Str>, project_root: Str) -> Str? {
    let mut path_part = ""
    for i in 0..use_path_segments.len() {
        match use_path_segments.get(i) {
            some(seg) => {
                if i == 0 { path_part = seg }
                else { path_part = path_join(path_part, seg) }
            },
            none => {},
        }
    }
    let ring_file = "${path_part}.ring"
    let absolute = path_resolve(path_join(project_root, ring_file))
    if file_exists(absolute) { some(absolute) } else { none }
}

// ============================================================
// build_module_graph
// ============================================================

pub fn build_module_graph(entry_file: Str) -> ModuleGraph? {
    let abs_entry = path_resolve(entry_file)
    let project_root = path_dirname(abs_entry)

    let entry_basename = path_basename(abs_entry).replace(".ring", "")
    let entry_id = ModuleId {
        path_segments: [entry_basename],
        file_path: abs_entry
    }
    let entry_key = module_key(entry_id.path_segments)

    let mut modules: Map<Str, ModuleId> = map_new()
    let mut dependencies: Map<Str, List<Str>> = map_new()
    let mut asts_map: Map<Str, Program> = map_new()

    modules.insert(entry_key, entry_id)
    let mut empty_deps: List<Str> = []
    dependencies.insert(entry_key, empty_deps)

    let mut queue: List<Str> = [entry_key]

    while queue.len() > 0 {
        match queue.shift() {
            some(current_key) => {
                match modules.get(current_key) {
                    some(current_mod) => {
                        let source = read_file(current_mod.file_path)
                        let resolve_sink = new_collecting_sink()
                        let ast = parse(source, current_mod.file_path, resolve_sink)
                        if resolve_sink.has_errors() {
                            eprintln(format_human(resolve_sink.diagnostics(), source))
                            return none
                        }
                        // Surface parse warnings (non-error diagnostics) without failing the build
                        if resolve_sink.items.len() > 0 {
                            eprintln(format_human(resolve_sink.diagnostics(), source))
                        }
                        asts_map.insert(current_key, ast)

                        let mut deps: List<Str> = []
                        for use_decl in ast.uses {
                            let segments = use_decl.path.segments
                            let dep_key = module_key(segments)

                            if deps.contains(dep_key) { } else {
                                match resolve_module_file(segments, project_root) {
                                    some(resolved) => {
                                        let abs_resolved = path_resolve(resolved)
                                        match modules.get(dep_key) {
                                            none => {
                                                let dep_id = ModuleId {
                                                    path_segments: list_clone(segments),
                                                    file_path: abs_resolved
                                                }
                                                modules.insert(dep_key, dep_id)
                                                let mut empty: List<Str> = []
                                                dependencies.insert(dep_key, empty)
                                                queue.push(dep_key)
                                            },
                                            some(_) => {},
                                        }
                                        deps.push(dep_key)
                                    },
                                    none => {
                                        let mod_path = segments.join("::")
                                        let diag = make_diag(
                                            E0702,
                                            Severity::SevError,
                                            "Module '${mod_path}' not found",
                                            use_decl.span,
                                            DiagnosticContext::OtherContext { detail: some("no file '${mod_path}.ring' in project root") }
                                        )
                                        let mut err_sink = new_collecting_sink()
                                        err_sink.report(diag)
                                        eprintln(format_human(err_sink.diagnostics(), source))
                                        return none
                                    },
                                }
                            }
                        }
                        dependencies.insert(current_key, deps)
                    },
                    none => {},
                }
            },
            none => {},
        }
    }

    // Topological sort (Kahn's algorithm)
    let mut dep_count: Map<Str, Int> = map_new()
    for entry in dependencies.entries() {
        let (key, deps) = entry
        dep_count.insert(key, deps.len())
    }

    let mut topo_order: List<Str> = []
    let mut ready: List<Str> = []

    for entry in dep_count.entries() {
        let (key, count) = entry
        if count == 0 { ready.push(key) }
    }

    while ready.len() > 0 {
        match ready.shift() {
            some(node) => {
                topo_order.push(node)
                for entry in dependencies.entries() {
                    let (key, deps) = entry
                    if deps.contains(node) {
                        match dep_count.get(key) {
                            some(c) => {
                                let new_count = c - 1
                                dep_count.insert(key, new_count)
                                if new_count == 0 { ready.push(key) }
                            },
                            none => {},
                        }
                    }
                }
            },
            none => {},
        }
    }

    if topo_order.len() != modules.len() {
        // Cycle detected — find and report the cycle path
        let mut cycle_nodes: List<Str> = []
        for entry in modules.entries() {
            let (key, _) = entry
            if !topo_order.contains(key) {
                cycle_nodes.push(key)
            }
        }
        // Build a human-readable cycle path by following dependencies
        let cycle_path = find_cycle_path(cycle_nodes, dependencies)
        let cycle_desc = cycle_path.join(" -> ")
        let file_span = Span {
            file: abs_entry,
            start: Position { line: 1, column: 0, offset: 0 },
            end: Position { line: 1, column: 0, offset: 0 }
        }
        let diag = make_diag(
            E0704,
            Severity::SevError,
            "Circular dependency detected: ${cycle_desc}",
            file_span,
            DiagnosticContext::OtherContext { detail: some("modules form a dependency cycle") }
        )
        let mut err_sink = new_collecting_sink()
        err_sink.report(diag)
        let entry_source = read_file(abs_entry)
        eprintln(format_human(err_sink.diagnostics(), entry_source))
        return none
    }

    some(ModuleGraph {
        entry: ModuleId { path_segments: [entry_basename], file_path: abs_entry },
        modules: modules,
        dependencies: dependencies,
        topo_order: topo_order,
        asts: asts_map
    })
}

// Find a cycle path among the nodes that weren't topologically sorted.
// Returns a list like ["a", "b", "a"] showing the cycle.
fn find_cycle_path(cycle_nodes: List<Str>, dependencies: Map<Str, List<Str>>) -> List<Str> {
    if cycle_nodes.len() == 0 { return ["(unknown)"] }
    let cycle_set: Set<Str> = set_from(cycle_nodes)

    // Try each cycle node as a potential cycle start.
    // Follow a single path through cycle-member deps; if we return to start, that's the cycle.
    for start_node in cycle_nodes {
        let mut path: List<Str> = [start_node]
        let mut current = start_node
        let mut visited: Set<Str> = set_new()
        visited.insert(current)
        let mut found_cycle = false

        while !found_cycle {
            let maybe_deps = dependencies.get(current)
            if maybe_deps.is_none() { break }
            let deps = maybe_deps.unwrap()
            let mut advanced = false
            for dep in deps {
                if cycle_set.contains(dep) {
                    if dep == start_node {
                        path.push(dep)
                        found_cycle = true
                        advanced = true
                        break
                    }
                    if !visited.contains(dep) {
                        visited.insert(dep)
                        path.push(dep)
                        current = dep
                        advanced = true
                        break
                    }
                }
            }
            if !advanced { break }
        }

        if found_cycle { return path }
    }

    // Fallback: just list the cycle nodes
    let mut fallback: List<Str> = []
    for n in cycle_nodes { fallback.push(n) }
    match cycle_nodes.get(0) {
        some(first) => fallback.push(first),
        none => {},
    }
    fallback
}
