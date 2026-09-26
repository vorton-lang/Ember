# Audit Report

> 活的 bug 看板。修复后删除条目，只在 git commit message 留记录。
> 条目格式：`### #xxx <标题> [严重度] [dispatch] [状态]`
> dispatch 标记：`mechanical`（DS 可执行）/ `judgment`（Claude 执行）
> 状态流转：`open` → `doing` → 删除
> 工作流规范见 `docs/workflow.md`

---

## 🔴 Critical（阻塞 native 自举）

（无 open 项。#134 已由 B-098 clone-all-escape 从根消除（2026-06-04，git `c54e7c6`）；native 自举余项归 B-089。）

## Checker



### #45 `StructType`/`EnumType` 在 `apply_subst` 中不替换 fields [low] [judgment] [open] [deferred: LLVM]

设计约束：fields 是模板字段（含递归引用），递归替换会导致 `Node<T>` 等递归类型栈溢出。当前 `infer_field_access` 的 inst_map 兜底是正确设计。如需修复需改为 nominal 表示（关联 #16）。

**决策（2026-05-23）**：长期容忍。当前方案正确且无性能问题，改动大（L-XL）收益主要在未来后端。等 LLVM 后端需要时与 #16 一并重构。







## Codegen

### #29 Runtime 耦合 Node.js ESM（createRequire）[low] [judgment] [open]

可移植性问题。

> #130（闭包 env 捕获泄漏）/ #131（perceus drop 落不了地，96 rc-warn）已于 2026-06-03 并入 backlog **B-084**（Perceus drop 精度 + drop_T 完整性），详见 backlog。

> #135（`ring_map_clone` / `ring_map_int_clone` 浅拷不 dup value，同 `ring_list_clone` 类）已于 2026-06-07 在 B-104 工作树修复（深拷 + 逐 value `ring_dup`）；`ring_set_clone`/`ring_set_int_clone` 核为非 bug（值内联）。

### #136 LLVM 后端 5 个 mapped-but-missing runtime 符号 [low] [judgment] [open]

B-103 全量枚举 ring_runtime.cpp 时发现：`method_to_runtime`（codegen_llvm_expr.ring）映射了 5 个 **ring_runtime.cpp 中不存在**的符号——`ring_str_to_int`（Str.to_int）、`ring_str_to_float`（Str.to_float）、`ring_list_enumerate`（List.enumerate，且在 codegen_llvm.ring:174 被无条件 declare）、`ring_map_is_empty`（Map.is_empty）、`ring_set_is_empty`（Set.is_empty）。任何程序在 `--target=llvm` 下调用这些方法 → 链接失败（undefined symbol）。当前编译器/测试零使用（`.enumerate` 仅注释提及）→ latent。修复方向：补 runtime 实现或删映射改走 Ring impl。发现者：B-103 Wave A。

### #137 List.reverse / List.sort 后端语义分歧（JS 原地 vs LLVM fresh 丢弃）[medium] [judgment] [open]

std/list.ring 声明 `reverse`/`sort` 返回 Unit（原地变异语义）；JS 后端确实原地（runtime.ring:87 `self.reverse()`，sort 同）。但 LLVM runtime `ring_list_reverse`/`ring_list_sort_default` **构造 fresh 副本返回、不动接收者**——语句位调用在 native 等于 no-op。编译器自身有 8 处 `.sort(`（穷尽性/codegen 排序等），native 自编译产出的 JS 与 node 版可能**顺序不一致 → G-b（double-bootstrap 字节一致门）地雷**。B-103 已为两个 runtime fn 补元素 dup（RC 健全），但语义分歧未动（修复方向需拍板：LLVM runtime 改原地、或 codegen 把结果写回 receiver alloca）。`tests/cases/llvm/list_share_ops_rc.ring` 的 reverse 用例刻意只断言 len 不断言顺序。发现者：B-103 Wave A。

### #138 std 已声明但 method_to_runtime 未映射的方法在 native 落 panic-stub [low] [judgment] [open]

`StringBuilder.line` / `StringBuilder.add_int`、`Set<Str>.clear`、`Set.union` / `intersect` / `difference`（runtime 符号 `ring_sb_line`/`ring_sb_add_int`/`ring_set_clear`/`ring_set_union`/... **存在**但 method 派发不可达），以及 str-keyed `Map.clone()` / `List.clone()` / `Set<Str>.clone()` 方法语法（int-keyed 分支有映射、str-keyed 落空；直呼 `map_clone(m)`/`list_clone(l)` 经 gen_direct_call 的 `ring_` fallback 正常）。这些方法调用在 native 生成 "unknown method" panic-stub，运行即 panic。当前编译器自身零使用（`.line(`/`.union(` 等 grep 为 0）→ latent。发现者：B-103 Wave A。

### #140 extern handle 的闭包捕获 dup 不受 #139 类型级排除覆盖 [low] [judgment] [open] [latent]

#139 的类型级排除盖住了 perceus 的四个机制（Clone/Drop/owned/materialise）+ codegen drop_T 字段递归，但 **gen_lambda 的捕获 dup 是第五条 RC 路径**：闭包构造时对每个捕获一律 `ring_dup`（B-098 all-owned captures），且 env 死亡时 `drop_closure_env` 逐 slot `ring_drop`——若 lambda 捕获 extern handle（或含 handle 的容器），dup 写外来内存 / env drop 释放外来指针，与 #139 同类损坏。**现状零实存站点**（grep 实证 codegen_llvm_* 五模块零闭包使用——无 .map/.filter/.fold/lambda），纯 latent；且与 #139 同等 dormant（仅 B-099 native 自跑 --target=llvm 触发）。修法方向：gen_lambda 捕获循环按捕获绑定的 HIR 类型跳过 dup + drop_closure_env 对应 slot 跳过（需 env 布局携带 per-slot 标志），或 D1 Stage 2 时统一处理。发现者：B-104 D1 Stage 1。

> （#139 本体已修复并删除，2026-06-11：类型级 RC 排除落地于 B-104 D1 Stage 1，git `bfd4fe6`..`b62423b`，回归 `tests/cases/llvm/extern_handle_rc_exclusion.ring`；runtime 级终验已挂 B-099 验收。）

### #146 extern type 经 `use` 导入（无本地重声明）时漏出类型级排除 [low] [judgment] [open] [latent]

`hir.ring: collect_extern_type_names` 按模块收集 `HDecl::ExternType`（perceus 逐模块运行；现状 codegen_llvm_* 五模块均本地重声明 extern types，模块内收集即覆盖全部使用点）。若未来某模块通过 `use` 导入 extern type 而不本地重声明，其值不被排除——dup/drop 触及外来指针（crash 方向，同 #139 类）。今日代码库零实存形态；出现时需把 extern 名集合从 checker 全局导出（如挂 HProgram）。已记 hir.ring 帮助函数注释，本条防注释埋没。发现者：B-104 D1 Stage 1。

### #147 跨模块裸名 nominal 碰撞可误伤 extern-handle 排除判定 [low] [judgment] [open] [latent]

`is_extern_handle_type` 按 `Type::StructType.name` 裸名匹配：若另一模块存在与某 extern type 同裸名的用户 struct，且其值流入声明该 extern type 的模块，会被误排除（漏 dup/drop → 潜在 double-free）。与既有「跨模块 nominal 类型按名 unify」语义同级（`types_equal` 本就按名），现实概率≈0（`LLVM*Ref` 命名空间独占）。真解 = extern 名集合带模块限定（可与 #146 的 checker 导出一并做）。发现者：B-104 D1 Stage 1。





### #145 Option HOF/find inline 模板硬编码 `_tag`/`"some"`/`_0` JS 字符串 [low] [mechanical] [open]

codegen_expr.ring 的 Option HOF（map/and_then/unwrap_or_else）与 find 模板硬编码 `_tag`/`"some"`/`_0`，而紧邻的 `to_fail` 分支用 `ENUM_TAG_FIELD`/`OPTION_SOME_TAG`/`OPTION_PAYLOAD_FIELD` 常量。pre-existing（#28 重构按「纯重构」如实保留）。修复：统一改用常量。发现者：#28 重构。

## 诊断 / CLI

### #141 parser.ring:301 catch 触发 W0001「handler 永不执行」[low] [judgment] [open]

`some(self.parse_use_decl(false)) catch { _ => none }` 被 checker 判定无 fail effect。B-112 把 warnings 接到出口后，每次 self-compile stderr 打 1 条。若 `parse_use_decl` 确实可 fail → impl-effect-propagation bug（CLAUDE.md 已知限制）的假阳性实证；若不可 fail → dead catch 应删。二者皆需拍板，顺带消除 self-compile 噪音。发现者：B-112。

### #142 多文件管线 `--error-format=llm` 整体失效 [low] [judgment] [open]

resolver / compiler_mod 的 error 与 warning 输出内联 `eprintln(format_human(...))`，`error_format` 未下传——multi-file 模式 `--error-format=llm` 静默退化为 human（error 与 warning 皆然，pre-existing）。修复方向：诊断收集上提至 cli.ring 统一格式化，或 plumbing error_format。发现者：B-112。

### #143 E0105 在 parser 硬编码且未注册 codes.ring [low] [mechanical] [open]

parser.ring:2143/2147 以字符串字面量 `"E0105"` 报错，codes.ring 无 const 也无 error_description 条目——违反「不允许跨阶段硬编码字符串契约」。修复：注册 E0105 + parser 改用 const。发现者：B-115。

### #144 单文件 `run` 子命令是 stub 且泄漏临时文件 [low] [judgment] [open]

cli.ring:177 "Single-file run not yet implemented"（EXIT 1），且在源文件目录残留 `.ring_tmp_run.js`（orchestrator 实测复现）。CLAUDE.md 常用命令已改为 build + node 流。修复方向：实现单文件 run（编译 + 执行 + 清理临时产物），或删 stub 改提示 build 流；`--debug` 同路径一并处理。发现者：B-115。

## 代码质量 / 可维护性

### #6 `runtime.ring` 用数百个 `.push()` 拼接 JS 运行时代码 [low] [mechanical] [open]

应改用 raw string 或外部 .js 文件。

### #7 `infer.ring` 2826 行单文件 [low] [judgment] [open]

编译器最大单文件，从 2565→2763→2826 行持续增长。应拆分为 infer_stmt/infer_expr/infer。





## 架构债

### #16 StructType/EnumType 携带冗余 fields/variants 数据 [low] [judgment] [open] [deferred: LLVM]

类型表示不一致。应改为 nominal 表示。

**决策（2026-05-23）**：长期容忍，与 #45 一并推迟到 LLVM 后端阶段。改 nominal 表示（只存 `name + type_args`，fields 走 registry 查）后，#45（apply_subst 不递归 fields）/ 原 #108（occurs check 不查 fields——2026-06-03 贴码核为正确 nominal 语义非 bug 已 wontfix 删除：fields/variants 是声明模板，环只能经 type_params 形成、occurs check 已覆盖，递归查模板 var 反而误判）随之一并消解——它们都是当前 fields-as-template 表示的衍生现象。

### #19 Ring 编译器缺少 `assertNever` 等效编译期保护 [low] [mechanical] [open]

新 variant 易遗漏。应确保所有 match 穷尽。

### #20 HExpr/HStmt match 在 5+ pass 中重复 [low] [judgment] [open]

维护负担。应扩展 hir-visitor。

## Delegate 完整性（2026-05-23 审计发现）


### #93 Delegate expansion 绕过类型推断直接合成 HIR [low] [judgment] [open]

`expand_delegate_impls` 直接合成 `HDecl::Fn`（HIR），绕过 `check_fn_decl` 的推断流程。当前所有被委托的 trait（Eq/Clone/Ord/Debug）均为无 effect 纯函数，因此无实际影响。但未来 `delegate` 用于带 effect 的自定义 trait 时，合成的 forwarding call 的 effect 仅取自 trait 声明而非实际推断，可能导致 effect 不匹配。

**#77 修复后的状态更新（2026-05-24）**：#77 修复了 `register_trait` 丢弃 `declared_effects` 的根因，trait 方法的 FnType 现在正确携带 effect 信息。同时修复了 dict dispatch 的 evidence 转发。因此 delegate expansion 合成的 forwarding call 现在能拿到正确的 effect 签名。但 expansion 仍绕过推断流程（直接合成 HIR），对于带复杂 effect 的 trait method，合成的 effect 可能与实际推断结果有细微差异。风险降低但架构问题仍在。

**文件**：`compiler/infer_decl.ring`（`expand_delegate_impls`）
**修复方向**：让合成的 forwarding 方法走完整的类型推断流程，或在合成时从实际 impl 的推断结果获取 effect 信息。

发现者：Opus

### #123 Delegate dict dispatch effect 转发在 catch 块内可能不足 [low] [judgment] [open]

`get_callee_evidence_args`（`codegen_expr.ring:352-393`）有两个路径：(1) callee_type 路径——从 FnType 提取 effect 并返回 evidence params；(2) callee_name 路径——从 `local_fn_effects` 查找实际 effect 并检查 `ctx.in_try_fail`。Delegate 的 dict dispatch 走路径 (1)（callee_name 为 `none`），其效应从 trait method 的 FnType 推导。路径 (1) 不检查 `ctx.in_try_fail`，这意味着如果在 `catch` 块内对 delegate field 调用带 `fail` 的 trait 方法，且该 `fail` effect 的 evidence 依赖 catch 上下文，evidence 可能不完整。当前实践中难触发—默认 trait（Eq/Clone/Ord/Debug）均无 `fail` effect，#77 修复后 trait method FnType 也正确携带 effect 信息。

**文件**：`compiler/codegen_expr.ring:352-360`
**修复方向**：在 callee_type 路径中也注入 `ctx.in_try_fail` 的 `fail` evidence（与 callee_name 路径一致）。

发现者：Opus




### #122 `gen_handle_body` IIFE 仅传递 handled effects 的 evidence，未 handling 的依赖闭包 [low] [judgment] [open]

`gen_handle_body`（`codegen_expr.ring:1421-1444`）的 IIFE 仅传 `by_effect.entries()` 中的 evidence params。若 body 中有 effect op 对应 unhandled effect（带默认 handler 但不在当前 `handle...with` 列表中），该 evidence 需通过 JS 闭包从外部作用域解析。嵌套 handle 时中间作用域若不保留 evidence 变量，闭包链可能断裂。

**文件**：`compiler/codegen_expr.ring:1421-1444`
**修复方向**：将 body 的 HExpr 中所有涉及 effects 的 evidence 都传入 IIFE（不仅是 handled effects），确保显式 evidence 访问不依赖闭包链。

发现者：Opus


## 设计-实现差距（参考，已在 backlog 跟踪）

> 以下为未实现特性的跟踪参考，不作为 Worker 任务源。实际实现由 backlog 对应条目驱动。

| # | 设计功能 | Backlog 对应 | 状态 |
|---|----------|--------------|------|
| 36 | Refinement types (where 子句) | B-001 | 语法解析但语义忽略 |
| 37 | `mut<S>` 参数化 effect | B-037 | ✅ 已实现（调用点注入） |
| 38 | Post-resume handler / Full AE | 已取消 (B-009) | 不实现 |
| 39 | `dyn Trait` 动态分发 | B-006 | 未实现 |
| 40 | Supertrait 继承 | B-005 | ✅ 已实现 |
| 41 | 关联类型 | B-004 | ✅ 已实现 |
