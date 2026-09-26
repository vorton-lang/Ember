# CLAUDE.md

## 项目概述

Ring-lang：写起来像 Python，编译器看到 Rust 级别的类型和副作用信息。代数 effect system + HM 类型推断 + trait 多态，编译器全推断，零标注负担。当前编译到 JS/V8（bootstrap 后端），目标后端为 LLVM native。

编译器已自举（Ring 写 Ring），完整设计文档见 `docs/design.md`。

## 技术栈

- **编译器**：Ring 自举，编译为 JS 运行（bootstrap 后端）；LLVM native 后端开发中
- **LLVM 后端**：codegen_llvm*.ring（5 个模块，~3500 行 Ring），通过 N-API addon 桥接 LLVM-C 22 API。编译器自身已能生成 .o（1.5MB，212K 行 IR），链接+运行验证进行中
- **测试**：node:test，零外部依赖
- **参考实现**：Koka 编译器（MIT），用于 effect 推断、evidence passing 等算法翻译
- **历史**：TS 原始实现归档于 git tag `ts-compiler-final`

## 项目结构

```
Ring-lang/
├── compiler/          编译器源码（*.ring）+ dist/（JS 产出，入 git）+ dist-llvm/（.o 产出）
│   ├── codegen*.ring      JS 后端 codegen
│   ├── codegen_llvm*.ring LLVM 后端 codegen（5 个模块）
│   ├── llvm_ffi.ring      LLVM-C API 声明（59 extern fn + 13 extern type）
│   └── llvm-addon/        N-API addon（本地构建，.gitignore）
├── ring_runtime.cpp   LLVM native backend 的 C ABI runtime（~1100 行 C++ STL wrapper）
├── std/               标准库（io/fs/path/process/str/num/list/map/set/result/iterator）
├── tests/             E2E 测试用例 + 测试运行器
├── examples/          示例程序
├── editor/vscode/     VSCode 插件（语法高亮，LSP 暂不可用）
└── docs/              设计文档、技术债清单、竞品分析
```

## 编译器管线

```
源码 (.ring) → Lexer → Parser → AST → Checker (HM + effects) → HIR → Codegen → JavaScript
                                  ↓ (errors)                           ↘ Codegen LLVM → .o → native binary
                           DiagnosticSink → format_human / format_llm
```

- **AST**：忠实反映源码结构，所有节点带 Span
- **HIR**：独立数据结构，每个表达式带推断的 Type + EffectRow，语法糖已展开
- **DiagnosticSink**：Lexer/Parser/Checker 错误统一收集，支持多错误报告
- HIR 独立于 AST，后续优化 pass 在 HIR → Codegen 之间插入
- **Perceus RC pass**（`perceus.ring`，仅 `--target=llvm`）：HIR → [escape-clone/drop 插入] → RC 标注 HIR → Codegen LLVM。**L1 借用引擎 clone-all-escape**（读取 borrow、逃逸点 `HExpr::Clone`、scope-end-drop-once，已撤 branch-balancing），翻译 Koka POPL'21 borrowing 扩展。实现模型见 design.md §7.11
- **双后端**：`--target=js`（默认，bootstrap）和 `--target=llvm`（native，开发中）共享同一 HIR

## 开发约定

- 编译器源码是 Ring（`compiler/*.ring`），snake_case 命名
- 编译器各阶段共享约定放 `hir.ring`（如 `variant_js_name`），不允许跨阶段硬编码字符串契约
- **修改编译器后必须重新编译 dist/**：`node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist`，并提交更新后的 dist/ 文件。**Worktree merge 后的 rebuild 必须 amend 进 merge commit**——不允许 broken intermediate state（dist/ 失配）作为独立 commit 存在。同理，merge 后的 bookkeeping（更新 audit-report/backlog 删除已完成条目）也 amend 进 merge commit。**数据结构级重构**（如 `trait_impls` 从 List 改为 Map）merge 后需要 double bootstrap——旧 dist 编译新源码的产出可能有引用错误，需先用 worktree 的 dist 做中间 bootstrap 再 double bootstrap。
- 注释语法 `//`，无 pipe 运算符，UFCS `.method()` 是唯一链式调用方式
- 生成的 JS 代码应可读——方便调试
- 复杂算法参考 Koka 的 Haskell 实现翻译，标注来源
- 新增 AST/HIR 节点后必须处理所有 match 穷尽分支（编译器自动检查）
- 每个 PR 至少包含一个 e2e 测试，合入前必须通过 `npm test`（从 `compiler/` 目录运行）
- **Worktree 隔离规则**：Agent 工具可使用 `isolation: "worktree"` 进行并行开发。worktree 完成后必须通过 `git merge` CLI 命令同步回主分支，禁止用 Edit 工具手动搬迁。Worktree agent 启动后必须立即 `git log --oneline -1` 验证 base commit。**每次任务完成后必须清理 stale worktree**：`git worktree remove -f -f <path>`。
- **决策必须讨论**：发现问题后不得自行决定修复方案，除非问题 trivial 且有唯一正确修复方式。不讨论就动手 = 错误。
- **禁止忽略问题**：不能以"推迟"、"很难触发"等原因主动替用户忽略问题，必须上报由用户拍板。
- **文档时效性**：修改编译器功能后同步更新 CLAUDE.md 和 docs/design.md。已完成的 review/plan/spec 文件应删除。
- **禁止 temp fix**：修复应提升项目健壮性，不增加技术债，即使工作量更大。
- bug fix 后如果问题典型，补充 regression test。

## 测试策略

- **E2E 语义测试**（`tests/cases/*.ring`）：语言规范的可执行版本，每个特性一个文件
- **负面测试**（期望编译错误）：定义类型系统边界，含 pending 测试标记未来特性
- **回归测试写 E2E 层**：不写 "第 X 行生成的 JS 应该是 Y"——codegen 实现可变
- **度量语义覆盖**，不度量代码行覆盖
- **LLVM 差分回归测试**（`tests/cases/llvm/*.ring` + `tests/llvm_diff.test.mjs`，`npm run test:llvm`）：每个用例用 JS 和 LLVM 两个后端编译运行，断言输出一致（JS 后端是 oracle）。锁定 LLVM codegen 修复（tuple-match tag、OR-pattern、Set 迭代、泛型 Eq/Ord dict 派发、List.contains、fail/catch via ring_try、闭包捕获 RC（mut-cell 写穿 + env owned-capture drop）、泛型 trait 方法 dict 派发、双后端 parity 收口（一等多态函数值 / wrapped dict / 闭包捕获 dict / mut 参数 writeback / print Int / tuple-literal pattern）、自定义 effect handler（tail-resumptive evidence struct 派发 + handler-arm 捕获外层 local 的 Perceus RC dup/move，#133）等）。需本地 clang，无则自动 skip。

## 已知限制

### Effect / Codegen

- **Handler 只支持 tail-resumptive + abort**：非 abort effect 的 handler 返回值即 resume 值；`fail.raise` 为 abort。Full AE（post-resume / multi-resume）不计划实现
- **Trait dictionary dispatch 的 evidence 转发已基本修复**（#77），delegate 复杂路径仍有低风险残留问题（见 audit-report #93/#123）
- **`catch` 总是消除 fail effect**：完整捕获点，catch arms 经穷尽性检查。需要部分处理时在 catch 内部 match + re-raise

### 类型系统

- Record row types 仅在参数位置使用（无匿名 record 字面量）
- Refinement `where` 子句只解析不验证（tokens 消费后丢弃）
- 不支持 `dyn Trait` 动态分发、GATs
- `pub` 可见性在单文件模式不强制（向后兼容）
- 穷尽性检查：嵌套模式递归检查正常，多字段交叉组合不验证
- `List.find` / `Map` key 查找仍用 JS `===`（其他 contains 方法已用 Eq trait）

### 语法

- 字符串无 `+` 拼接：用插值 `"${a}${b}"` 或 `join()`
- `return` 不能出现在 match arm 表达式位置
- `list[i]` / `map[key]` / `str[i]` 越界 panic，安全访问用 `.get()`
- `.map()` 闭包不能捕获 `let mut` 变量，改用 `for` 循环
- Struct literal 不能直接出现在 if/while/for/match 条件位置（`{` 歧义），需加括号或用变量

### 基础设施

- 无 CI（test 手动执行）
- 模块系统不支持 first-class modules、`mod : SigName` 一致性检查
- Checker 多错误恢复是 declaration 级（同一函数内停于首错）
- LSP 暂不可用（TS 实现未移植）
- Impl 方法 effect 传播有 `__ring_raise_fail` workaround（跨模块 effect 传播的独立问题）

## 路线图

**当前**：L0 RC 基础设施（B-012，2026-06-01）+ **L1 借用引擎（B-098，2026-06-04）已落地**——`perceus.ring` 从 owned-everywhere 改为 clone-all-escape（读取 borrow、逃逸点 `HExpr::Clone`、scope-end-drop-once、删 branch-balancing），**从根消除 #134 系统性 move-analysis double-free 崩溃类**：native ring.exe 编 `a_empty.ring` EXIT 0、JS 731×3 + llvm_diff 49×3 全绿、dist double-bootstrap 字节一致。**推进中**：B-089 native 自举终验 capstone——定位 native `print` builtin bug（可能残留 RC over-free builtins 环境，待 native 调试）、内存峰值实测（G-a）、native LLVM-C 链接（B-099）。

**后续**：B-089 native 自举终验（G-a/b/c）→ L1 用户面（B-068）/ L2 Drop/RAII（B-002）→ async effect + 结构化并发 → Refinement types（Z3 集成）→ GADTs

**遗留**：impl effect 传播修复、LSP 移植、技术债清理（见 `docs/audit-report.md`）

**长期**：语义驱动编译优化（AOT + JIT）、Formatter 等级系统

## 常用命令

```bash
# 运行
node compiler/dist/main.js run examples/hello.ring

# 编译为 JS
node compiler/dist/main.js build examples/hello.ring

# 类型检查
node compiler/dist/main.js check examples/effects.ring

# LLM 格式错误输出
node compiler/dist/main.js check --error-format=llm examples/effects.ring

# E2E 测试（JS 后端）
cd compiler && npm test

# LLVM 后端差分回归测试（需 clang）
cd compiler && npm run test:llvm

# 重新编译编译器自身
node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist

# 调试模式
node compiler/dist/main.js run --debug examples/hello.ring

# LLVM 后端：编译为 native .o
node compiler/dist/main.js build examples/hello.ring --target=llvm

# LLVM 后端：编译编译器自身（多文件）
node compiler/dist/main.js build compiler/main.ring --target=llvm --out-dir=compiler/dist-llvm
```
