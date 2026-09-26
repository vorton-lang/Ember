use ast::{Pattern, NamedPatternField, span_zero, LiteralValue}
use types::{Type, StructField, type_to_string}
use union_find::{UnionFind}
use env::{apply_subst}
use hir::{HMatchArm}

struct Ctor {
    name: Str,
    arity: Int,
    field_types: List<Type>,
    field_names: List<Str>?,
    is_tuple: Bool
}

fn pat_at(list: List<Pattern>, i: Int) -> Pattern {
    match list.get(i) { some(v) => v, none => panic("unreachable: pat_at out of bounds") }
}

fn type_at(list: List<Type>, i: Int) -> Type {
    match list.get(i) { some(v) => v, none => panic("unreachable: type_at out of bounds") }
}

fn str_at(list: List<Str>, i: Int) -> Str {
    match list.get(i) { some(v) => v, none => panic("unreachable: str_at out of bounds") }
}

fn row_at(list: List<List<Pattern>>, i: Int) -> List<Pattern> {
    match list.get(i) { some(v) => v, none => panic("unreachable: row_at out of bounds") }
}

fn ctor_at(list: List<Ctor>, i: Int) -> Ctor {
    match list.get(i) { some(v) => v, none => panic("unreachable: ctor_at out of bounds") }
}

// Check if a type recursively contains itself (used to decide expanding set)
fn type_is_recursive(ty: Type, key: Str) -> Bool {
    match ty {
        Type::EnumType { variants, .. } => {
            let mut visited: Set<Str> = set_new()
            visited.insert(key)
            for v in variants {
                for ft in v.fields {
                    if type_contains_key(ft, key, visited) { return true }
                }
            }
            false
        },
        _ => false,
    }
}

fn type_contains_key(ty: Type, key: Str, mut visited: Set<Str>) -> Bool {
    let ty_str = type_to_string(ty)
    if ty_str == key { return true }
    if visited.contains(ty_str) { return false }
    visited.insert(ty_str)
    match ty {
        Type::EnumType { variants, .. } => {
            for v in variants {
                for ft in v.fields {
                    if type_contains_key(ft, key, visited) { return true }
                }
            }
            false
        },
        Type::StructType { fields, .. } => {
            for f in fields {
                if type_contains_key(f.ty, key, visited) { return true }
            }
            false
        },
        Type::TupleType { elements } => {
            for e in elements {
                if type_contains_key(e, key, visited) { return true }
            }
            false
        },
        Type::FnType { params, return_type, .. } => {
            for p in params {
                if type_contains_key(p, key, visited) { return true }
            }
            type_contains_key(return_type, key, visited)
        },
        _ => false,
    }
}

pub fn check_exhaustive(arms: List<HMatchArm>, scrutinee_type: Type, subst: UnionFind) -> Str? {
    let mut patterns: List<Pattern> = []
    for arm in arms {
        match arm.guard {
            some(_) => {},
            none => patterns.push(arm.pattern),
        }
    }
    check_patterns(patterns, scrutinee_type, subst)
}

// Expand or-patterns into flat list of patterns for exhaustiveness checking
fn expand_or_patterns(patterns: List<Pattern>) -> List<Pattern> {
    let mut result: List<Pattern> = []
    for p in patterns {
        match p {
            Pattern::OrPattern { patterns: sub_pats, .. } => {
                for sp in sub_pats {
                    result.push(sp)
                }
            },
            _ => result.push(p),
        }
    }
    result
}

fn check_patterns(patterns: List<Pattern>, ty: Type, subst: UnionFind) -> Str? {
    let resolved = apply_subst(subst, ty)
    let expanded = expand_or_patterns(patterns)

    for p in expanded {
        match p {
            Pattern::Wildcard { .. } => { return none },
            Pattern::Binding { .. } => { return none },
            _ => {},
        }
    }

    match resolved {
        Type::EnumType { name, type_params, variants } => {
            let variant_names = variants.map(fn(v) { v.name })
            let mut covered = set_new()

            for v in variants {
                let mut sub_patterns_for_variant: List<List<Pattern>> = []
                for p in expanded {
                    match p {
                        Pattern::Constructor { name: pname, fields, .. } => {
                            if pname == v.name {
                                covered.insert(v.name)
                                sub_patterns_for_variant.push(fields)
                            }
                        },
                        Pattern::NamedConstructor { name: pname, fields: nfields, .. } => {
                            match v.field_names {
                                some(fnames) => {
                                    if pname == v.name {
                                        covered.insert(v.name)
                                        let positional = named_pattern_to_positional(nfields, fnames, v.fields.len())
                                        sub_patterns_for_variant.push(positional)
                                    }
                                },
                                none => {},
                            }
                        },
                        _ => {},
                    }
                }

                if covered.contains(v.name) == false {
                    // not covered yet, skip field checking
                } else {
                    if v.fields.len() > 0 {
                        let wild = Pattern::Wildcard { span: span_zero() }
                        let mut normalized: List<List<Pattern>> = []
                        for row in sub_patterns_for_variant {
                            let mut padded = list_clone(row)
                            while padded.len() < v.fields.len() {
                                padded.push(wild)
                            }
                            normalized.push(padded)
                        }
                        let mut expanding = set_new()
                        expanding.insert(type_to_string(resolved))
                        let missing_fields = check_matrix(normalized, v.fields, subst, expanding)
                        match missing_fields {
                            some(mf) => {
                                let joined = join_strs(mf, ", ")
                                return some("${v.name}(${joined})")
                            },
                            none => {},
                        }
                    }
                }
            }

            for vn in variant_names {
                if covered.contains(vn) == false {
                    return some(vn)
                }
            }
            none
        },
        Type::BoolType => {
            let mut has_true = false
            let mut has_false = false
            for p in expanded {
                match p {
                    Pattern::Literal { value, .. } => match value {
                        LiteralValue::BoolVal(b) => {
                            if b { has_true = true } else { has_false = true }
                        },
                        _ => {},
                    },
                    _ => {},
                }
            }
            if has_true == true {
                if has_false == true {
                    none
                } else {
                    some("false")
                }
            } else {
                some("true")
            }
        },
        Type::StructType { name: sname, fields: sfields, .. } => {
            let mut covered = false
            let mut sub_patterns: List<List<Pattern>> = []
            let mut field_names: List<Str> = []
            let mut field_types: List<Type> = []
            for f in sfields {
                field_names.push(f.name)
                field_types.push(f.ty)
            }
            for p in expanded {
                match p {
                    Pattern::NamedConstructor { name: pname, fields: nfields, .. } => {
                        if names_match_struct(pname, sname) {
                            covered = true
                            let positional = named_pattern_to_positional(nfields, field_names, sfields.len())
                            sub_patterns.push(positional)
                        }
                    },
                    Pattern::Constructor { name: pname, fields: cfields, .. } => {
                        if names_match_struct(pname, sname) {
                            covered = true
                            sub_patterns.push(cfields)
                        }
                    },
                    _ => {},
                }
            }
            if covered == false {
                return some(sname)
            }
            if sfields.len() > 0 {
                let wild = Pattern::Wildcard { span: span_zero() }
                let mut normalized: List<List<Pattern>> = []
                for row in sub_patterns {
                    let mut padded = list_clone(row)
                    while padded.len() < sfields.len() {
                        padded.push(wild)
                    }
                    normalized.push(padded)
                }
                let mut expanding = set_new()
                expanding.insert(type_to_string(resolved))
                let missing_fields = check_matrix(normalized, field_types, subst, expanding)
                match missing_fields {
                    some(mf) => {
                        let joined = join_strs(mf, ", ")
                        return some("${sname}(${joined})")
                    },
                    none => {},
                }
            }
            none
        },
        Type::UnitType => none,
        Type::TupleType { elements } => {
            let mut matrix: List<List<Pattern>> = []
            for p in expanded {
                match p {
                    Pattern::TuplePattern { elements: pelems, .. } => {
                        if pelems.len() == elements.len() {
                            matrix.push(pelems)
                        }
                    },
                    _ => {},
                }
            }
            if matrix.len() == 0 {
                let underscores = elements.map(fn(e: Type) { "_" })
                let joined = join_strs(underscores, ", ")
                return some("(${joined})")
            }
            let missing = check_matrix(matrix, elements, subst, set_new())
            match missing {
                some(m) => {
                    let joined = join_strs(m, ", ")
                    some("(${joined})")
                },
                none => none,
            }
        },
        _ => some("_"),
    }
}

// === Maranget-style pattern matrix exhaustiveness ===

fn finite_type_ctors(ty: Type) -> List<Ctor>? {
    match ty {
        Type::BoolType => {
            let mut result: List<Ctor> = []
            result.push(Ctor { name: "true", arity: 0, field_types: [], field_names: none, is_tuple: false })
            result.push(Ctor { name: "false", arity: 0, field_types: [], field_names: none, is_tuple: false })
            some(result)
        },
        Type::EnumType { variants, .. } => {
            let mut result: List<Ctor> = []
            for v in variants {
                result.push(Ctor { name: v.name, arity: v.fields.len(), field_types: v.fields, field_names: v.field_names, is_tuple: false })
            }
            some(result)
        },
        Type::StructType { name, fields, .. } => {
            let mut field_types: List<Type> = []
            let mut field_names: List<Str> = []
            for f in fields {
                field_types.push(f.ty)
                field_names.push(f.name)
            }
            let mut result: List<Ctor> = []
            result.push(Ctor { name: name, arity: fields.len(), field_types: field_types, field_names: some(field_names), is_tuple: false })
            some(result)
        },
        Type::UnitType => {
            let mut result: List<Ctor> = []
            result.push(Ctor { name: "()", arity: 0, field_types: [], field_names: none, is_tuple: false })
            some(result)
        },
        Type::TupleType { elements } => {
            let mut result: List<Ctor> = []
            result.push(Ctor { name: "", arity: elements.len(), field_types: elements, field_names: none, is_tuple: true })
            some(result)
        },
        _ => none,
    }
}

fn wild_pattern() -> Pattern {
    Pattern::Wildcard { span: span_zero() }
}

fn named_pattern_to_positional(fields: List<NamedPatternField>, field_names: List<Str>, arity: Int) -> List<Pattern> {
    let wild = wild_pattern()
    let mut result: List<Pattern> = []
    for i in 0..arity {
        result.push(wild)
    }
    for f in fields {
        let idx = index_of(field_names, f.name)
        if idx >= 0 {
            if idx < arity {
                // Replace result[idx] with f.pattern
                // Ring has no List.set — rebuild with replacement
                let mut new_result: List<Pattern> = []
                for j in 0..result.len() {
                    if j == idx {
                        new_result.push(f.pattern)
                    } else {
                        new_result.push(pat_at(result, j))
                    }
                }
                result = new_result
            }
        }
    }
    result
}

fn index_of(list: List<Str>, target: Str) -> Int {
    for i in 0..list.len() {
        if str_at(list, i) == target { return i }
    }
    0 - 1
}

fn specialize_row(row: List<Pattern>, ctor: Ctor) -> List<Pattern>? {
    let first = pat_at(row, 0)
    let mut rest: List<Pattern> = []
    for i in 1..row.len() {
        rest.push(pat_at(row, i))
    }

    match first {
        Pattern::Wildcard { .. } => {
            let mut result: List<Pattern> = []
            let wild = wild_pattern()
            for i in 0..ctor.arity {
                result.push(wild)
            }
            result.extend(rest)
            some(result)
        },
        Pattern::Binding { .. } => {
            let mut result: List<Pattern> = []
            let wild = wild_pattern()
            for i in 0..ctor.arity {
                result.push(wild)
            }
            result.extend(rest)
            some(result)
        },
        Pattern::Literal { value, .. } => {
            match value {
                LiteralValue::BoolVal(b) => {
                    let match_name = if b { "true" } else { "false" }
                    if match_name == ctor.name {
                        some(rest)
                    } else {
                        none
                    }
                },
                _ => none,
            }
        },
        Pattern::Constructor { name, fields, .. } => {
            if names_match_struct(name, ctor.name) {
                let mut sub = list_clone(fields)
                let wild = wild_pattern()
                while sub.len() < ctor.arity {
                    sub.push(wild)
                }
                sub.extend(rest)
                some(sub)
            } else {
                none
            }
        },
        Pattern::NamedConstructor { name, fields: nfields, .. } => {
            if names_match_struct(name, ctor.name) {
                let field_names = match ctor.field_names {
                    some(fns) => fns,
                    none => {
                        let empty: List<Str> = []
                        empty
                    },
                }
                let mut positional = named_pattern_to_positional(nfields, field_names, ctor.arity)
                positional.extend(rest)
                some(positional)
            } else {
                none
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            if ctor.is_tuple == true {
                if elements.len() == ctor.arity {
                    let mut result = list_clone(elements)
                    result.extend(rest)
                    some(result)
                } else {
                    none
                }
            } else {
                none
            }
        },
        Pattern::OrPattern { patterns: sub_pats, .. } => {
            // Try each sub-pattern; return the first that matches
            for sp in sub_pats {
                let mut trial_row: List<Pattern> = [sp]
                trial_row.extend(rest)
                let result = specialize_row(trial_row, ctor)
                match result {
                    some(_) => { return result },
                    none => {},
                }
            }
            none
        },
    }
}

fn check_matrix(rows: List<List<Pattern>>, col_types: List<Type>, subst: UnionFind, expanding: Set<Str>) -> List<Str>? {
    if col_types.len() == 0 {
        if rows.len() > 0 {
            return none
        } else {
            let empty: List<Str> = []
            return some(empty)
        }
    }

    let first_type = apply_subst(subst, type_at(col_types, 0))
    let mut rest_types: List<Type> = []
    for i in 1..col_types.len() {
        rest_types.push(type_at(col_types, i))
    }

    let type_key = match first_type {
        Type::EnumType { .. } => type_to_string(first_type),
        _ => "",
    }
    let is_reentrant = if type_key != "" { expanding.contains(type_key) } else { false }
    let ctors = if is_reentrant { none } else { finite_type_ctors(first_type) }

    match ctors {
        some(ctor_list) => {
            let mut new_expanding = set_clone(expanding)
            if type_key != "" {
                if type_is_recursive(first_type, type_key) {
                    new_expanding.insert(type_key)
                }
            }
            for ctor in ctor_list {
                let mut specialized: List<List<Pattern>> = []
                for row in rows {
                    match specialize_row(row, ctor) {
                        some(s) => specialized.push(s),
                        none => {},
                    }
                }
                let mut new_types: List<Type> = []
                new_types.extend(ctor.field_types)
                new_types.extend(rest_types)
                let sub = check_matrix(specialized, new_types, subst, new_expanding)
                match sub {
                    some(sub_result) => {
                        let mut ctor_sub: List<Str> = []
                        for i in 0..ctor.arity {
                            ctor_sub.push(str_at(sub_result, i))
                        }
                        let mut rest_sub: List<Str> = []
                        for i in ctor.arity..sub_result.len() {
                            rest_sub.push(str_at(sub_result, i))
                        }
                        let mut ctor_str = ""
                        if ctor.is_tuple {
                            let joined_sub = join_strs(ctor_sub, ", ")
                            ctor_str = "(${joined_sub})"
                        } else {
                            if ctor.arity == 0 {
                                ctor_str = ctor.name
                            } else {
                                let joined_sub2 = join_strs(ctor_sub, ", ")
                                ctor_str = "${ctor.name}(${joined_sub2})"
                            }
                        }
                        let mut result: List<Str> = []
                        result.push(ctor_str)
                        result.extend(rest_sub)
                        return some(result)
                    },
                    none => {},
                }
            }
            none
        },
        none => {
            let mut defaults: List<List<Pattern>> = []
            for row in rows {
                let first = pat_at(row, 0)
                let mut is_default = false
                match first {
                    Pattern::Wildcard { .. } => { is_default = true },
                    Pattern::Binding { .. } => { is_default = true },
                    Pattern::OrPattern { patterns: sub_pats, .. } => {
                        for sp in sub_pats {
                            match sp {
                                Pattern::Wildcard { .. } => { is_default = true },
                                Pattern::Binding { .. } => { is_default = true },
                                _ => {},
                            }
                        }
                    },
                    _ => {},
                }
                if is_default {
                    let mut tail: List<Pattern> = []
                    for i in 1..row.len() {
                        tail.push(pat_at(row, i))
                    }
                    defaults.push(tail)
                }
            }
            let sub = check_matrix(defaults, rest_types, subst, expanding)
            match sub {
                some(s) => {
                    let mut result: List<Str> = []
                    result.push("_")
                    result.extend(s)
                    some(result)
                },
                none => none,
            }
        },
    }
}

// Compare pattern name (raw, e.g. "Pair") against type name (possibly qualified, e.g. "inner::Pair").
// Returns true if they are equal or if type_name ends with "::pattern_name" (mod-qualified).
fn names_match_struct(pattern_name: Str, type_name: Str) -> Bool {
    if pattern_name == type_name { return true }
    type_name.ends_with("::${pattern_name}")
}

fn join_strs(parts: List<Str>, sep: Str) -> Str {
    let mut result = ""
    for i in 0..parts.len() {
        if i > 0 { result = "${result}${sep}" }
        let part = str_at(parts, i)
        result = "${result}${part}"
    }
    result
}
