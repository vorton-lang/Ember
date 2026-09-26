# CLAUDE.md

## 项目概述

Ring-lang：写起来像 Python，编译器看到 Rust 级别的类型和副作用信息。代数 effect system + HM 类型推断 + trait 多态，编译器全推断，零标注负担。当前编译到 JS/V8（bootstrap 后端），目标后端为 LLVM native。

编译器已自举（Ring 写 Ring），完整设计文档见 `docs/design.md`。

## 设计公理（速查，全文唯一真值源 = `docs/philosophy.md`）

① 类型即模型，不是谜题 ② 效果即可见性 ③ 推断为王，标注为仆（标注是文档不是语义）④ 无人回路（失真必须响 / 优化不可观测 / 人类审查面可枚举 = unsafe discharge 清单）⑤ 编译器必须终止（可判定片段）⑥ 确定性资源语义（Drop 时机 = 语义；RC 无 GC；环用 Weak）。设计决策与公理冲突时公理优先；公理间冲突的仲裁记录入 design.md 决策表。

## 技术栈

- **编译器**：Ring 自举，编译为 JS 运行（bootstrap 后端）；LLVM native 后端开发中
- **LLVM 后端**：codegen_llvm*.ring（5 个模块，~6400 行 Ring），通过 N-API addon 桥接 LLVM-C 22 API。编译器自身已编译链接为 native ring.exe（前端自举打通、能编真实程序）；剩余硬墙 = 自编译内存（G-a），由 B-104 完整 Perceus RC 解决中
- **测试**：node:test，零外部依赖
- **参考实现**：Koka 编译器（MIT），用于 effect 推断、evidence passing 等算法翻译
- **历史**：TS 原始实现归档于 git tag `ts-compiler-final`

## 项目结构

```
Ring-lang/
├── compiler/          编译器源码（*.ring）+ dist/（JS 产出，入 git）+ dist-llvm/（.o 产出）
│   ├── codegen*.ring      JS 后端 codegen
│   ├── codegen_llvm*.ring LLVM 后端 codegen（5 个模块）
│   ├── llvm_ffi.ring      LLVM-C API 声明（91 extern fn + 13 extern type）
│   └── llvm-addon/        N-API addon（本地构建，.gitignore）
├── ring_runtime.cpp   LLVM native backend 的 C ABI runtime（~2200 行 C++ STL wrapper）
├── std/               标准库（io/fs/path/process/str/num/list/map/set/result/iterator）
├── tests/             E2E 测试用例 + 测试运行器
├── examples/          示例程序
├── editor/vscode/     VSCode 插件（语法高亮，LSP 暂不可用）
└── docs/              设计文档、技术债清单、竞品分析（含 lang-design.md：语言面长期决策——数值类型/@repr/TCO/comptime/包管理等）
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
- **LLVM 差分回归测试**（`tests/cases/llvm/*.ring` + `tests/llvm_diff.test.mjs`，`npm run test:llvm`）：每个用例用 JS 和 LLVM 两个后端编译运行，断言输出一致（JS 后端是 oracle）。锁定历次 LLVM codegen/RC/effect-handler 修复——用例即规约，修复明细在 git history。需本地 clang，无则自动 skip。**动 RC 的改动必须 ×3 跑全套**（间歇性堆损坏单跑约 1/3 命中，单跑假绿）。

## 已知限制

### Effect / Codegen

- **Handler 只支持 tail-resumptive + abort**：非 abort effect 的 handler 返回值即 resume 值；`fail.raise` 为 abort。Full AE（post-resume / multi-resume）不计划实现
- **Trait dictionary dispatch 的 evidence 转发已基本修复**（#77），delegate 复杂路径仍有低风险残留问题（见 audit-report #93/#123）
- **`catch` 总是消除 fail effect**：完整捕获点，catch arms 经穷尽性检查。需要部分处理时在 catch 内部 match + re-raise

### 类型系统

- Record row types 仅在参数位置使用（无匿名 record 字面量）
- Refinement `where` 子句只解析不验证（编译时发 W0002 warning 提示未强制；B-001 落地后移除）
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

**当前**：**B-104 完整 Perceus RC（里程碑，专门 session）= G-a 内存墙真解**。

- **已落地地基**：L0 RC 基础设施（B-012）→ L1 借用引擎 clone-all-escape（B-098，从根消除 #134 move-analysis double-free 崩溃类）→ over-free/UAF 链终结（B-101→B-102→B-103，细节见 git）→ **B-103 return-mode 分类 ✅（2026-06-11）**：ring_runtime.cpp ~170 函数全量分类表（FRESH/BORROW/SCALAR/NULL-NEVER，逐函数证据）落 `perceus.ring`、`is_borrow_returning_call` 曾含 9 个 receiver-returning mutator 字段名（D1 规则②落地后退役，Unit 类型级规则接管）、runtime dup-on-share 补全 ×9。
- **结论（2026-06-09 拍板，数据驱动）**：G-a 主因 = incomplete RC——clone-all-escape 只 drop named 绑定 + 逃逸，**不 drop 中间临时**；墙主体 74.5% 是非标量临时（STR/OPTION/CLOSURE/TUPLE）。标记指针只消 ~21%（BOOL+INT）→ **B-080 降级为后续 peak/perf，B-109 折入 B-104**。停 wave 式「哪里漏堵哪里」打地鼠，做完整 Perceus（garbage-free by construction，Koka POPL'21 定理）。
- **执行序**：**D1 total return-mode drop pass ✅（2026-06-11/12 全落地，Stage 1-3，git `bfd4fe6`..`26aadf1`）**——规则①②③④（extern/Unit 类型级排除、Str-IndexExpr=FRESH、runtime overwrite/remove drop）+ ANF 可达位置全收口 + 2 个新不变量（dropping-block tail-escape / unknown-ownership 守卫）；llvm_diff 57→68 例、自编译 leak 15.3%→14.1%@2.382B（残余主体 STR/BOOL/CLOSURE/TUPLE，头号嫌疑 audit #151 codegen 合成 dict——HIR 不可见，D1 范围外待独立收口）→ **D2** 静态 leak verifier（下一步；post-RC HIR 线性检查，编译期证明 0 泄露/0 UAF，挂 `npm test`）→ **D3** 0 泄露 = 无环 by-construction + 环用 `Weak<T>`（§7.9）→ native re-measure。实现模型见 design.md §7.11。
**后续**：B-089 native 自举终验（G-a/b/c）→ B-099 native LLVM-C 链接（Node 消除）→ L1 用户面（B-068）/ L2 Drop/RAII（B-002）→ async effect + 结构化并发 → Refinement types（Z3 集成）→ GADTs

**遗留**：impl effect 传播修复、LSP 移植、技术债清理（见 `docs/audit-report.md`）

**长期**：语义驱动编译优化（AOT + JIT）、Formatter 等级系统

## 常用命令

```bash
# 运行单文件（run 子命令对单文件是未实现 stub——audit #144；先 build 再 node）
node compiler/dist/main.js build examples/hello.ring && node examples/hello.js

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

# 调试模式（多文件入口；单文件同受 #144 限制）
node compiler/dist/main.js run --debug <project-entry>.ring

# LLVM 后端：编译为 native .o
node compiler/dist/main.js build examples/hello.ring --target=llvm

# LLVM 后端：编译编译器自身（多文件）
node compiler/dist/main.js build compiler/main.ring --target=llvm --out-dir=compiler/dist-llvm
```

## ASan 跑法（两档，2026-06-11 定）

ASan 对自编译（2.5 亿次分配）默认参数会放大 ~100x（每次 malloc/free 抓 30 帧栈 + redzone + quarantine），半小时起步。分两档：

- **gating（内循环 / ×3 例行 / llvm_diff + real_program）**：`ASAN_OPTIONS=malloc_context_size=0:quarantine_size_mb=16:max_redzone=32:detect_leaks=0`（**已设为 User 级默认 env，新 shell 自动继承**；已在跑的旧 session 需内联设置）。检测面不变（立即 UAF/over-free 照抓），代价 = 报告无 alloc/free 栈 + 延迟 UAF 覆盖缩小。**ASan self-compile 不进内循环**——内循环 self-compile 用非 ASan + alloc/free 计数器 + 退出码（20s/轮）。
- **capstone 终验（self-compile 全量 ASan，每个 milestone 一次，可过夜）**：必须显式覆盖回全强度 `$env:ASAN_OPTIONS='quarantine_size_mb=256:malloc_context_size=12'`。gating 抓到 bug 后对单用例用此档重跑拿完整 alloc/free 栈。
- ring_asan 构建建议 `-fsanitize=address -O1 -fno-omit-frame-pointer`（-O0 下减速翻数倍）。
- thrash 预警：31GB 物理内存，ASan self-compile 后段可能换页——CPU 掉零 + 磁盘狂转即杀，别等。
