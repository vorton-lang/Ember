# LLVM 迁移日记

> 纯 append 日记。记录 Ring 编译器从 JS 后端迁移到 LLVM native 后端的全过程——想法、决策、踩坑、经验。
> 迁移完成后归档到个人 context。

---

## 2026-05-24 设计讨论：确定 LLVM 后端整体方案

### 背景

Phase C 层 1+2 全部完成（effect aliases、supertrait、mut\<T\>、default handler、关联类型、Iterator trait、delegate、语义规范）。LLVM 的所有前置依赖清零，可以启动。

### 核心决策

**1. Codegen 只写一次**

最初考虑了三个方案：emit LLVM 文本 IR (.ll)、LLVM C API via FFI、先 .ll 后 C API。

.ll 文本方案的问题：控制不了优化 pass，拖慢编译速度，用户还得自己装 LLVM CLI 工具。但直接用 C API 有个鸡生蛋问题——Ring 当前只能跑在 JS 上，无法调用 C API。

解法藏在 Ring 已有的 `extern fn` 机制里：LLVM codegen 用 Ring 写，通过 `extern fn` 调用 LLVM-C API。Bootstrap 阶段用一个本地的 Node N-API addon（C++ 薄皮）桥接 JS → LLVM-C；自举完成后同样的 `extern fn` 直接映射到 C ABI 调用 statically linked libLLVM。一份代码，两个运行时。

N-API addon 是一次性本地工具，不入仓库，不分发，自举后直接删掉。

**2. 内存管理：不回收 → Perceus RC**

不搞中间方案（Boehm GC 之类的）。编译器是短命进程，malloc 不释放完全可用。等 Perceus RC 直接一步到位。

**3. 值表示：Uniform Boxing**

所有 Ring 值在 LLVM 层面统一为 `void*`，包括 Int/Float/Bool。这让容器天然类型擦除（`void*` 数组）、闭包捕获统一、递归类型自然工作。代价是 `1 + 2` 要多几步 load/store/malloc，但编译器的瓶颈在 I/O 和树遍历，不在算术。Perceus RC 阶段再引入 unboxing 优化。

**4. Runtime：C++ STL wrapper**

最初计划自己写 ~1200 行 C（手写动态数组、哈希表、字符串操作）。后来发现可以蹭 C++ STL——`std::vector<void*>` 做 List，`std::unordered_map<std::string, void*>` 做 Map，`std::string*` 做 Str。用 `extern "C"` 包一层薄皮，~300 行搞定。libstdc++ 随 clang 自带，零额外依赖。

Map 的 key 在 bootstrap 阶段统一为 Str（编译器的 Map 几乎全是 `Map<Str, ...>`），避免泛型 hash 问题。

**5. 闭包：{fn_ptr, env_ptr}**

每个 lambda 生成环境 struct + 带 env 参数的函数。已知函数（非 lambda，直接调用）不走闭包。Trait dict 中的方法也是 `RingClosure*`。

**6. Enum 布局：tag + 内联 fields**

`{tag: i64, fields: void*[N]}`，N = 该 enum 最大变体的字段数。Uniform boxing 下所有字段本来就是 `void*`，递归类型（AST/HIR/Type 全是递归 enum）天然工作。

**7. fail/catch：setjmp/longjmp**

JS 后端用 `throw`/`try-catch`。LLVM 端用 setjmp/longjmp。Bootstrap 阶段没有 Drop/RAII，不需要栈展开。等 Ownership 上来后可以切换到 C++ exceptions 或自定义 unwind 机制。

**8. 多文件编译：单 Module**

Bootstrap 阶段所有 .ring 文件编译到一个 LLVM Module → 一个 .o → 链接为单一二进制。不需要处理跨模块符号解析。增量编译留给后续。

### 工作量评估

| 组件 | 说明 |
|------|------|
| LLVM FFI 层 | ~50-80 个 `extern fn` 声明 |
| LLVM codegen 模块 | codegen_llvm.ring + codegen_llvm_expr.ring + codegen_llvm_decl.ring |
| ring_runtime.cpp | ~300 行 C++ STL wrapper |
| N-API addon | ~300 行 C++（本地临时，不入仓库） |
| 标准库 extern fn 迁移 | 编译器用到多少就迁多少 |

### 未来演进路径

- Uniform boxing → Perceus RC 阶段引入 unboxing（基础类型不装箱）
- setjmp/longjmp → Ownership/RAII 阶段切换栈展开机制
- 单 Module → 增量编译（每个 .ring → 一个 .o）
- C++ STL runtime → RIIR（纯 Ring 重写，有 raw pointer 后）
- Map Str-only key → 泛型 Hash trait

---

## 2026-05-28 详细执行计划

### 环境

- **LLVM 版本**：22（opaque pointers 唯一选项，typed pointers 已移除）
- **工具链**：Windows MSVC + prebuilt LLVM 22
- **目标三元组**：`x86_64-pc-windows-msvc`
- **N-API addon 位置**：`compiler/llvm-addon/`（.gitignore，不入版本控制）
- **链接器**：LLVM 22 自带 clang（`--target=x86_64-pc-windows-msvc`）或 MSVC `link.exe`

### LLVM 22 API 要点

- 所有指针类型用 `LLVMPointerTypeInContext(ctx, 0)`（opaque ptr，无类型参数）
- Load/Store/GEP/Call 全部用 `*2` 变体（显式传类型）：`LLVMBuildLoad2(builder, ty, ptr, name)`、`LLVMBuildGEP2`、`LLVMBuildCall2`
- Uniform boxing 下几乎所有值的 LLVM 类型都是 `ptr`，类型参数通过 LLVM type 体系显式传递

### Wave 1: 地基层

> 三个独立子任务可并行（1a/1b/1c），1d 依赖 1a 的声明骨架。

#### Wave 1a: `compiler/llvm_ffi.ring` — LLVM-C API 声明

~80 个 `extern fn` + ~15 个 `extern type`，按功能分组：

**extern type（~15 个）**：
```
LLVMContextRef, LLVMModuleRef, LLVMBuilderRef,
LLVMTypeRef, LLVMValueRef, LLVMBasicBlockRef,
LLVMTargetRef, LLVMTargetMachineRef, LLVMTargetDataRef,
LLVMPassManagerRef, LLVMMemoryBufferRef,
LLVMAttributeRef, LLVMMetadataRef
```

**Context/Module（~10 个）**：
- LLVMContextCreate, LLVMContextDispose
- LLVMModuleCreateWithNameInContext, LLVMDisposeModule
- LLVMSetTarget, LLVMSetDataLayout
- LLVMPrintModuleToString, LLVMDisposeMessage
- LLVMVerifyModule（返回 bool + error message）
- LLVMWriteBitcodeToFile（可选，调试用）

**Types（~10 个）**：
- LLVMVoidTypeInContext, LLVMInt1TypeInContext, LLVMInt8TypeInContext, LLVMInt32TypeInContext, LLVMInt64TypeInContext
- LLVMDoubleTypeInContext
- LLVMPointerTypeInContext（opaque ptr，address space = 0）
- LLVMFunctionType（vararg 参数）
- LLVMStructTypeInContext, LLVMArrayType2

**Values/Constants（~10 个）**：
- LLVMConstInt, LLVMConstReal
- LLVMConstNull, LLVMConstPointerNull
- LLVMConstStringInContext
- LLVMConstArray2
- LLVMGetUndef, LLVMSizeOf
- LLVMConstBitCast, LLVMConstIntToPtr

**Functions（~8 个）**：
- LLVMAddFunction, LLVMGetNamedFunction
- LLVMGetParam, LLVMCountParams
- LLVMSetLinkage（external/internal）
- LLVMSetFunctionCallConv
- LLVMGetEntryBasicBlock
- LLVMAddAttributeAtIndex（可选）

**Basic Blocks（~5 个）**：
- LLVMAppendBasicBlockInContext
- LLVMGetInsertBlock
- LLVMPositionBuilderAtEnd
- LLVMCreateBuilderInContext, LLVMDisposeBuilder

**IR Builder 指令（~25 个）**：
- 算术：LLVMBuildAdd, LLVMBuildSub, LLVMBuildMul, LLVMBuildSDiv, LLVMBuildSRem, LLVMBuildFAdd, LLVMBuildFSub, LLVMBuildFMul, LLVMBuildFDiv
- 比较：LLVMBuildICmp, LLVMBuildFCmp
- 内存：LLVMBuildAlloca, LLVMBuildLoad2, LLVMBuildStore, LLVMBuildGEP2, LLVMBuildStructGEP2
- 控制流：LLVMBuildBr, LLVMBuildCondBr, LLVMBuildRet, LLVMBuildRetVoid, LLVMBuildUnreachable, LLVMBuildSwitch, LLVMAddCase
- 调用：LLVMBuildCall2
- 类型转换：LLVMBuildBitCast, LLVMBuildIntToPtr, LLVMBuildPtrToInt, LLVMBuildTrunc, LLVMBuildZExt
- Phi：LLVMBuildPhi, LLVMAddIncoming
- 全局：LLVMAddGlobal, LLVMSetInitializer, LLVMSetGlobalConstant, LLVMBuildGlobalStringPtr

**Target Machine（~8 个）**：
- LLVMInitializeX86TargetInfo, LLVMInitializeX86Target, LLVMInitializeX86TargetMC, LLVMInitializeX86AsmPrinter
- LLVMGetDefaultTargetTriple, LLVMGetTargetFromTriple
- LLVMCreateTargetMachine, LLVMDisposeTargetMachine
- LLVMTargetMachineEmitToFile

**外部 C 标准库**（非 LLVM，但 codegen 需要声明）：
- setjmp, longjmp（或 `_setjmp`/`longjmp` on MSVC）
- malloc, free（备用）

#### Wave 1b: N-API Addon（`compiler/llvm-addon/`）

**目的**：在 Node.js 中调用 LLVM-C API，让 JS 版 Ring 编译器能运行 LLVM codegen 代码。

**结构**：
```
compiler/llvm-addon/
├── binding.gyp          # node-gyp 构建配置
├── llvm_addon.cpp       # N-API 包装层（~300 行）
└── README.md            # 本地构建说明
```

**llvm_addon.cpp 模式**：
```cpp
// 每个 Ring extern fn 对应一个 N-API wrapper
napi_value wrap_LLVMContextCreate(napi_env env, napi_callback_info info) {
    LLVMContextRef ctx = LLVMContextCreate();
    napi_value result;
    napi_create_external(env, ctx, nullptr, nullptr, &result);
    return result;
}
// ... 重复 ~80 次
```

**注入方式**：
Ring 的 JS codegen 在 `--target=llvm` 模式下，runtime 头部追加：
```javascript
const __llvm = require('./llvm-addon/build/Release/llvm_addon.node');
// 将 __llvm 的所有函数注入全局作用域
Object.assign(globalThis, __llvm);
```
这样 Ring 的 `extern fn LLVMContextCreate()` 编译为 JS 的 `LLVMContextCreate()` 调用自然解析。

**构建**：
```bash
cd compiler/llvm-addon
npm init -y
npm install node-gyp
node-gyp configure --arch=x64
node-gyp build
```
`binding.gyp` 需引用 LLVM 22 的 include 和 lib 路径。

#### Wave 1c: `ring_runtime.cpp`（入仓库）

**目的**：为 LLVM native binary 提供 Ring 标准库的 C ABI 实现。

**约定**：
- 所有函数 `extern "C"`，参数/返回值全是 `void*`（或 `int64_t`/`double` 用于 unboxing）
- Str = `std::string*`，List = `std::vector<void*>*`，Map = `std::unordered_map<std::string, void*>*`
- Set = `std::unordered_set<std::string>*`
- 命名规则：`ring_<type>_<method>`，如 `ring_str_len`、`ring_list_push`

**函数清单（按编译器自用需求驱动）**：

Boxing/Unboxing（6 个）：
- `ring_box_int(int64_t) -> void*`：malloc int64_t，store，return
- `ring_unbox_int(void*) -> int64_t`：cast，load
- `ring_box_float(double) -> void*`、`ring_unbox_float`
- `ring_box_bool(int64_t) -> void*`、`ring_unbox_bool`

Str（~15 个）：
- new, from_cstr, len, concat, eq, lt, get, slice
- contains, starts_with, ends_with, split, join, replace
- to_int, to_float, to_str（Int/Float → Str）

List（~15 个）：
- new, push, get, set, len, concat, slice, pop
- contains, index_of, reverse, sort（接受 closure comparator）
- map, filter, for_each（接受 RingClosure*）
- is_empty, last, first

Map（~10 个）：
- new, get, set, has, delete, keys, values, entries, len, for_each

Set（~8 个）：
- new, add, has, delete, to_list, len, from_list, for_each

IO/FS/Process（~8 个）：
- print, eprintln, panic
- read_file, write_file
- exit, args, cwd

StringBuilder（~4 个）：
- new, add, to_str, len

setjmp/longjmp 辅助（~3 个）：
- `ring_catch_init() -> void*`：分配 jmp_buf，push 到全局 handler 栈
- `ring_catch_setjmp(void*) -> int64_t`：调用 setjmp（因为 setjmp 是宏，需要 C wrapper）
- `ring_raise(void*) -> void`：store error value，longjmp 到栈顶 handler

**总计**：~70 个函数，~300-400 行 C++（STL 一行式实现）。

#### Wave 1d: CLI + Pipeline 骨架

**`compiler/cli.ring`**：
- 新增 `--target` 选项，值为 `"js"` | `"llvm"`，默认 `"js"`
- 解析后存入编译选项结构

**`compiler/compiler_mod.ring`**：
- `compile_single_file` / `compile_multi_file` 根据 target 分派：
  - `"js"` → 现有 `generate()` → JS string → write .js
  - `"llvm"` → `generate_llvm()` → emit .o → 调用 clang 链接 → 产出 .exe

**`compiler/codegen_llvm.ring`（stub）**：
```ring
fn generate_llvm(program: HProgram, ...) -> Unit {
    panic("LLVM codegen not yet implemented")
}
```

### Wave 2: Codegen 核心

> 依赖 Wave 1 完成。内部按 2a → (2b+2c 并行) → (2d+2e+2f 增量) 推进。

#### Wave 2a: `codegen_llvm.ring` — 编排器

**数据结构**：
```ring
struct LlvmCtx {
    context: LLVMContextRef,
    module: LLVMModuleRef,
    builder: LLVMBuilderRef,
    target_machine: LLVMTargetMachineRef,

    // 类型缓存
    ptr_type: LLVMTypeRef,        // opaque ptr
    i64_type: LLVMTypeRef,
    i1_type: LLVMTypeRef,
    void_type: LLVMTypeRef,
    double_type: LLVMTypeRef,

    // 值映射
    named_values: Map<Str, LLVMValueRef>,   // 局部变量 name → alloca
    functions: Map<Str, LLVMValueRef>,       // 函数 name → LLVMValueRef
    struct_types: Map<Str, StructInfo>,      // struct name → 字段信息
    enum_types: Map<Str, EnumInfo>,          // enum name → 变体信息
    trait_dicts: Map<Str, DictInfo>,         // trait impl → dict 信息

    // Runtime 函数缓存
    rt_fns: Map<Str, LLVMValueRef>,         // "ring_box_int" → LLVMValueRef

    // 编译器元数据（从 JS codegen ctx 搬运）
    module_prefix: Option<Str>,
    local_fn_effects: Map<Str, EffectRow>,
    fn_mut_params: Map<Str, Set<Str>>,
    boxed_vars: Set<Str>,
    // ... 其他从 CodegenCtx 需要的字段

    // 计数器
    tmp_counter: Int,             // 临时变量命名
}
```

**入口函数 `generate_llvm(program, ...)`**：
1. 初始化 target（`LLVMInitializeX86*`）
2. 创建 context + module + builder
3. 设置 target triple (`x86_64-pc-windows-msvc`) + data layout
4. 缓存基础类型（ptr, i64, i1, void, double）
5. 声明所有 runtime 函数（`declare_runtime_fns(ctx)`）
6. **第一遍**：前向声明所有 Ring 函数（遍历 HDecl::Fn/HDecl::Impl 中的方法）
7. **第二遍**：生成所有声明的函数体（`emit_llvm_decl(ctx, decl)`）
8. 生成 `main()` wrapper（C main → 调用 Ring main 函数）
9. `LLVMVerifyModule` → 打印错误（如果有）
10. `LLVMTargetMachineEmitToFile` → 生成 .o
11. 调用 clang 链接：`clang ring_output.o ring_runtime.o -o output.exe -lmsvcrt`

**前向声明逻辑**：
- 遍历所有 HDecl，对每个 Fn/Impl method/ExternFn：
  - 计算参数数量（Ring params + effect evidence params）
  - 所有参数类型 = `ptr`（uniform boxing）
  - 返回类型 = `ptr`（或 `void` 对 Unit 返回）
  - `LLVMAddFunction(module, mangled_name, fn_type)`
  - **属性标注**（从第一天就做，成本极低收益大，见 design.md 13.6）：
    - 检查 effect row：无 effect → 标 `readnone`；只有 fail → 不标（可能 longjmp）；有 io/mut → 不标
    - 检查参数类型：非 Option 参数 → 标 `nonnull`
    - 检查 fail 可能性：不 raise → 标 `nounwind`
    - 穷尽 match 的 default 分支 → `unreachable`（在 codegen_llvm_expr 中处理）

**名称 mangling 规则**：
- 顶层函数：`ring_<name>`（避免与 C 符号冲突）
- 方法：`ring_<Type>_<method>`
- 模块函数：`ring_<module>_<name>`
- Lambda：`ring_lambda_<counter>`
- Trait dict：`ring_dict_<Trait>_for_<Type>`

#### Wave 2b: `codegen_llvm_expr.ring` — 表达式生成

每个 HExpr variant 对应一个分支。所有表达式返回 `LLVMValueRef`（类型为 `ptr`）。

**字面量**：
- `IntLit(n)` → `LLVMBuildCall2(builder, ..., rt_fns["ring_box_int"], [LLVMConstInt(i64, n)])`
- `FloatLit(f)` → 类似，调用 `ring_box_float`
- `StrLit(s)` → `LLVMBuildGlobalStringPtr` + `LLVMBuildCall2(rt_fns["ring_str_from_cstr"], [global_str])`
- `BoolLit(b)` → `ring_box_bool(0 或 1)`
- `UnitLit` → `LLVMConstPointerNull(ptr_type)`

**二元运算 BinOp(op, lhs, rhs)**：
```
lhs_val = gen_expr(ctx, lhs)
rhs_val = gen_expr(ctx, rhs)
// 根据操作数类型（从 HIR type 信息判断 Int/Float/Str/Bool）
lhs_raw = call ring_unbox_int(lhs_val)  // 或 float
rhs_raw = call ring_unbox_int(rhs_val)
result_raw = LLVMBuildAdd/Sub/Mul/... (lhs_raw, rhs_raw)
result = call ring_box_int(result_raw)
return result
```
比较运算：`LLVMBuildICmp` → `i1` → `ring_box_bool`
Str 运算（==, +, etc）：直接调用 runtime 函数（`ring_str_eq`, `ring_str_concat`）

**函数调用 Call(callee, args, evidence_args)**：
```
fn_val = lookup function in ctx.functions (or gen_expr for closure call)
arg_vals = args.map(|a| gen_expr(ctx, a))
ev_vals = evidence_args.map(|e| gen_expr(ctx, e))
all_args = arg_vals ++ ev_vals
LLVMBuildCall2(builder, fn_type, fn_val, all_args)
```

**闭包调用**（callee 是 closure pair `{fn_ptr, env_ptr}`）：
```
closure_val = gen_expr(ctx, callee)
fn_ptr = LLVMBuildStructGEP2 + LLVMBuildLoad2 → 取 fn_ptr
env_ptr = LLVMBuildStructGEP2 + LLVMBuildLoad2 → 取 env_ptr
LLVMBuildCall2(builder, fn_type, fn_ptr, [env_ptr] ++ arg_vals)
```

**字段访问 FieldAccess(expr, field)**：
```
obj_val = gen_expr(ctx, expr)                // void*
// 查 struct_types 获取 field 索引
field_idx = ctx.struct_types[type_name].field_index(field)
struct_type = ctx.struct_types[type_name].llvm_type  // {ptr, ptr, ptr, ...}
struct_ptr = LLVMBuildBitCast(obj_val, ptr_to(struct_type))
field_ptr = LLVMBuildStructGEP2(builder, struct_type, struct_ptr, field_idx)
LLVMBuildLoad2(builder, ptr_type, field_ptr)
```

**If(cond, then_body, else_body)**：
```
cond_val = gen_expr(ctx, cond)
cond_bool = call ring_unbox_bool(cond_val)
cond_i1 = LLVMBuildTrunc(cond_bool, i1)

then_bb = LLVMAppendBasicBlock("then")
else_bb = LLVMAppendBasicBlock("else")
merge_bb = LLVMAppendBasicBlock("merge")

LLVMBuildCondBr(cond_i1, then_bb, else_bb)

position_at(then_bb)
then_val = gen_expr(ctx, then_body)
LLVMBuildBr(merge_bb)
then_bb_end = LLVMGetInsertBlock()  // lambda 可能改变当前 bb

position_at(else_bb)
else_val = gen_expr(ctx, else_body)
LLVMBuildBr(merge_bb)
else_bb_end = LLVMGetInsertBlock()

position_at(merge_bb)
phi = LLVMBuildPhi(ptr_type)
LLVMAddIncoming(phi, [then_val, else_val], [then_bb_end, else_bb_end])
return phi
```

**Match(scrutinee, arms)**：
对 enum scrutinee：
```
scrut_val = gen_expr(ctx, scrutinee)
// 提取 tag
tag_ptr = LLVMBuildStructGEP2(builder, enum_struct_type, scrut_val, 0)
tag = LLVMBuildLoad2(builder, i64_type, tag_ptr)

// 为每个 arm 创建 basic block
arm_bbs = arms.map(|_| LLVMAppendBasicBlock("match_arm"))
merge_bb = LLVMAppendBasicBlock("match_merge")

// switch on tag
switch = LLVMBuildSwitch(tag, default_bb, arms.len())
for (arm, bb) in arms.zip(arm_bbs):
    LLVMAddCase(switch, LLVMConstInt(i64, arm.tag), bb)

// 每个 arm body
arm_vals = []
arm_end_bbs = []
for (arm, bb) in arms.zip(arm_bbs):
    position_at(bb)
    // 绑定 pattern 变量（从 enum fields 提取）
    bind_pattern_vars(ctx, scrut_val, arm.pattern)
    val = gen_expr(ctx, arm.body)
    LLVMBuildBr(merge_bb)
    arm_vals.push(val)
    arm_end_bbs.push(LLVMGetInsertBlock())

position_at(merge_bb)
phi = LLVMBuildPhi(ptr_type)
LLVMAddIncoming(phi, arm_vals, arm_end_bbs)
return phi
```

**Block(stmts, tail_expr)**：
```
for stmt in stmts:
    emit_llvm_stmt(ctx, stmt)
if tail_expr:
    gen_expr(ctx, tail_expr)
else:
    LLVMConstPointerNull(ptr_type)  // Unit
```

**Lambda(params, body, captures)**：
```
// 1. 生成 closure 环境 struct 类型
env_type = LLVMStructTypeInContext([ptr, ptr, ...])  // 每个 capture 一个 ptr
// 2. 生成带 env 参数的函数
fn_name = "ring_lambda_${ctx.tmp_counter++}"
fn_type = LLVMFunctionType(ptr, [ptr, params.map(|_| ptr)...])
fn_val = LLVMAddFunction(fn_name, fn_type)
// 3. 函数体中从 env 参数提取 captures
old_named = ctx.named_values.clone()
entry = LLVMAppendBasicBlock(fn_val, "entry")
position_at(entry)
env_param = LLVMGetParam(fn_val, 0)
for (i, cap) in captures.enumerate():
    cap_ptr = LLVMBuildStructGEP2(env_type, env_param, i)
    cap_val = LLVMBuildLoad2(ptr_type, cap_ptr)
    ctx.named_values[cap.name] = cap_val
for (i, param) in params.enumerate():
    ctx.named_values[param.name] = LLVMGetParam(fn_val, i + 1)
body_val = gen_expr(ctx, body)
LLVMBuildRet(body_val)
ctx.named_values = old_named

// 4. 在调用点构造 closure pair
env_val = malloc(env_type)
for (i, cap) in captures.enumerate():
    cap_src = lookup(ctx, cap.name)
    ptr = LLVMBuildStructGEP2(env_type, env_val, i)
    LLVMBuildStore(cap_src, ptr)
closure = malloc({ptr, ptr})
LLVMBuildStore(fn_val as ptr, closure.fn_ptr)
LLVMBuildStore(env_val, closure.env_ptr)
return closure
```

**StringInterpolation(parts)**：
```
// 生成 StringBuilder 调用序列
sb = call ring_sb_new()
for part in parts:
    if part is literal_str:
        call ring_sb_add(sb, ring_str_from_cstr(part))
    else:
        val = gen_expr(ctx, part)
        str_val = call ring_to_str(val)  // 或根据类型选择 int_to_str/float_to_str
        call ring_sb_add(sb, str_val)
call ring_sb_to_str(sb)
```

**MethodCall(obj, method, args, dict_dispatch)**：
如果 `dict_dispatch` 为 some → 走 trait dict 路径（Wave 2f）
否则 → 转为普通函数调用 `ring_<Type>_<method>(obj, args...)`

#### Wave 2c: `codegen_llvm_decl.ring` — 声明生成

**HDecl::Fn(name, params, body, effects, ...)**：
```
fn_val = ctx.functions[mangled_name]  // 已在前向声明阶段注册
entry = LLVMAppendBasicBlock(fn_val, "entry")
position_at(entry)

// 映射参数
for (i, param) in params.enumerate():
    alloca = LLVMBuildAlloca(ptr_type, param.name)
    LLVMBuildStore(LLVMGetParam(fn_val, i), alloca)
    ctx.named_values[param.name] = alloca
// evidence 参数（如有）
for (i, ev) in evidence_params.enumerate():
    ctx.named_values[ev.name] = LLVMGetParam(fn_val, params.len() + i)

body_val = gen_expr(ctx, body)
LLVMBuildRet(body_val)
```

**HDecl::Struct(name, fields, ...)**：
- 注册 struct 信息到 `ctx.struct_types`：字段名 → 索引映射
- 生成构造函数 `ring_<Name>_new(field1, field2, ...) -> ptr`：
  - malloc struct（N 个 ptr 的 struct）
  - store 每个字段
  - 返回 ptr

**HDecl::Enum(name, variants, ...)**：
- 注册 enum 信息到 `ctx.enum_types`：variant name → (tag, field count)
- 每个 variant 生成构造函数：
  - `ring_<Enum>_<Variant>(fields...) -> ptr`
  - malloc `{i64, ptr, ptr, ...}`（tag + N fields，N = 该 enum 最大变体字段数）
  - store tag
  - store fields（剩余 slot 为 undef）
  - 返回 ptr

**HDecl::Impl(trait_name, type_name, methods, ...)**：
- 每个 method 生成为普通函数（self 是首参数）
- 如果是 trait impl → 生成 dict struct（Wave 2f）

**HDecl::Effect(name, ops, ...)**：
- 每个 effect op 注册为需要 evidence 的函数签名
- evidence struct 类型定义

**HDecl::ExternFn / ExternType**：
- Skip（声明已在 runtime 函数声明中处理）

**HDecl::Const(name, value, ...)**：
- 生成为 LLVM 全局变量 + 初始化表达式

#### Wave 2d: fail/catch — setjmp/longjmp

**数据结构**：
```c
// 在 ring_runtime.cpp 中
struct RingCatchFrame {
    jmp_buf buf;
    void* error_value;
    RingCatchFrame* prev;
};
thread_local RingCatchFrame* ring_catch_stack = nullptr;
```

**catch 点生成**：
```
// catch { arms } 的 codegen
frame = call ring_catch_push()     // 分配 frame，push 到栈
result = call ring_catch_setjmp(frame)  // setjmp wrapper
// result: 0 = 正常路径，1 = 被 raise 跳回
cond = LLVMBuildICmp(result, 0)
LLVMBuildCondBr(cond, normal_bb, catch_bb)

normal_bb:
    ... gen body expr ...
    call ring_catch_pop()
    br merge_bb

catch_bb:
    error = call ring_catch_get_error(frame)
    ... gen catch arms (match on error) ...
    call ring_catch_pop()
    br merge_bb

merge_bb:
    phi result
```

**raise 点生成**：
```
// fail.raise(error) 的 codegen
call ring_raise(error_val)  // → store error, longjmp
LLVMBuildUnreachable()      // raise 不返回
```

#### Wave 2e: Effect Evidence 线程

**原理**：有 effect 签名的函数在 LLVM codegen 中额外接收 evidence 参数。

**传递规则**（镜像 JS codegen）：
- 函数签名中的 effect → 对应 evidence 参数（`void*`）
- 调用有 effect 的函数时，从当前作用域传递 evidence
- `handle` 表达式构造新的 evidence struct → 传入 body
- 默认 evidence 从全局变量加载

**与 JS codegen 的差异**：
- JS 用函数参数名匹配 evidence（字符串）
- LLVM 用参数位置（按 effect 声明顺序排列的额外参数）
- 需要参考 `codegen.ring` 中 `compute_transitive_effect_closure` 的逻辑

#### Wave 2f: Trait Dictionary Dispatch

**Dict struct 生成**：
```
// trait Foo { fn bar(self) -> Int; fn baz(self, x: Str) -> Bool }
// impl Foo for MyType { ... }

// Dict 类型（全局生成一次）
ring_dict_Foo = LLVMStructTypeInContext([ptr, ptr])  // 两个 RingClosure*

// Dict 实例（每个 impl 生成一次）
ring_dict_Foo_for_MyType = LLVMAddGlobal(ring_dict_Foo)
// 初始化：构造 closure pair {fn_ptr, null_env} for each method
```

**泛型函数 trait bound dispatch**：
```
fn do_something<T: Foo>(x: T) → 编译为 fn ring_do_something(x: ptr, dict_Foo: ptr)
// 调用 dict 中的方法：
method_closure = load dict_Foo[method_index]
fn_ptr = load method_closure.fn_ptr
env_ptr = load method_closure.env_ptr
result = call fn_ptr(env_ptr, x, ...)
```

**delegate**：
委托方法直接指向被委托字段的 dict 对应方法。

#### Wave 2g: 闭包 Codegen 细节

**已知函数优化**：
如果调用点的 callee 是已知函数名（非 lambda、非高阶参数），直接 `LLVMBuildCall2` 调用函数本身，不走 closure 间接调用。

**Trait method 闭包**：
Dict 中的方法存为 `{fn_ptr, env_ptr}` 对。大多数 trait method 的 env_ptr 为 null（无捕获）。

**`mut` 参数的 boxing**（与 JS 后端的差异）：
JS 后端对 `mut` 参数做 `{value: x}` boxing 以实现引用传递。
LLVM 后端 `mut` 参数直接传 `ptr`（已经是指针），修改通过 store 到 alloca 实现。
→ 不需要额外 boxing wrapper。

### Wave 3: 迁移 + 自举

#### Wave 3a: Std Lib Extern Fn C ABI 实现补全

遍历编译器源码的 `import` 声明，确定实际用到的 std 函数：
- `std/io.ring`：print, eprintln, panic
- `std/fs.ring`：read_file, write_file
- `std/path.ring`：join, dirname, basename, resolve, is_absolute
- `std/process.ring`：args, exit, cwd
- `std/str.ring`：Str 方法 + StringBuilder
- `std/num.ring`：Int/Float 方法
- `std/list.ring`：List 方法
- `std/map.ring`：Map 方法
- `std/set.ring`：Set 方法
- `std/result.ring`：纯 Ring 代码，无 extern fn（无需迁移）
- `std/iterator.ring`：纯 Ring 代码（trait + 默认实现），无 extern fn

每个 extern fn 在 `ring_runtime.cpp` 中提供 C ABI 实现，命名与 std 中 extern fn 声明一致。

#### Wave 3b: 首次 Bootstrap

```bash
# 1. 构建 N-API addon（一次性）
cd compiler/llvm-addon && node-gyp build

# 2. JS 编译器 + LLVM codegen → 编译自身
node compiler/dist/main.js build compiler/main.ring --out-dir=compiler/dist-llvm --target=llvm

# 3. 链接为 native binary
clang compiler/dist-llvm/main.o ring_runtime.o -o ring.exe -lmsvcrt
```

**预期问题**：
- 编译器源码中可能用到未覆盖的 std 函数 → 补充 runtime
- 某些 HIR 节点在 codegen 中未处理 → 补全 match 分支
- 边界情况（空 list、None 值、递归类型）→ 调试修复

#### Wave 3c: 双重 Bootstrap

```bash
# Native 编译器编译自身
ring.exe build compiler/main.ring --out-dir=compiler/dist-native --target=llvm
clang compiler/dist-native/main.o ring_runtime.o -o ring2.exe -lmsvcrt

# 验证一致性
# 两次编译产出的 .o 应该字节一致（或 LLVM IR 文本一致）
```

#### Wave 3d: E2E 验证

```bash
# Native 编译器运行 JS 后端测试
ring.exe run tests/run_tests.ring  # 或等价的测试运行命令

# 逐个修复 divergence
```

**验收标准**（最终）：
1. Ring 编译器编译自身为 native binary ✅
2. Native 编译器编译自身（二次自举一致性）✅
3. E2E 测试在 native 编译器上全部通过 ✅

---

## 2026-05-31 Session 4：前端自举打通，卡在内存墙

ring.exe 从"文件编译 segfault"推进到"编译单文件字节级一致 + 多模块端到端跑通"。方法论的关键转变：**不再加 runtime workaround 硬扛 800k 步的巨型 crash，而是用最小 repro + JS 对照逐个定位 codegen bug**——每个 bug 都先在几行的程序上复现，确认 JS 对、LLVM 错，再修根因。

### 修掉的 9 个 codegen bug
1. 移除上个 session 的 `ring_sanitize_type` workaround——它注入每个 enum match、无条件解引用指针，词法分析 chk=323 就自己炸了，是当时的真正 crash 源，把"List-as-Type in apply_subst"的诊断带偏了。
2. **tuple-match Phase1 不检查 NamedConstructor 子模式的 tag**：`match (a,b) { (Type::FnType{..}, ..) => }` 会无条件匹配第一个 arm，把 list 字段当 Type 读出来喂给 apply_subst——这才是 List-as-Type 的根因。unify 大量用这个模式。
3. OR-pattern（`A | B`）在 enum switch 路径不生成 case。
4. gen_match_if_else 尾部向已终结 block 重复发 br（terminator-in-middle，LLVM verifier 抓到）。
5. pad_start/pad_end/list_set 的参数 unbox 是 all-or-nothing，把 fill 字符串错 unbox 成 i64。
6. `for x in set` 当 list 迭代——Set 是哈希表不是 vector。
7. `List.contains`/`index_of` 映射到指针比较的 runtime——删掉映射走 Ring impl（用 Eq trait）。
8. **泛型 `==` 落到整数比较**：SSO 短串巧合正确、堆分配长串比的是堆指针 → false。`gen_binop` 改用 HIR 的 `eq_dispatch`/`ord_dispatch` 经 dict 派发；runtime 补 `ring_get_builtin_dict`。
9. **fail/catch 的 setjmp-in-wrapper**：`ring_catch_setjmp` 在 wrapper 函数里 setjmp 然后返回，longjmp 目标成死帧。改成 runtime `ring_try(body_closure, catch_closure)`——setjmp 在 ring_try 帧内、body 嵌套调用，longjmp 回的是活帧。20 万帧深栈 unwind 验证通过。

### 最终阻塞：内存（非 bug）
编译整个编译器峰值 **25.9GB**，在系统 commit 上限崩（0xC0000028）。1MB 和 512MB 栈同一步崩，排除栈深度。根因是 uniform boxing + 不回收：HM 推断的 apply_subst 疯狂造 Type（2.51 亿 chk），树/list/string 全 malloc 不 free，JS 后端靠 GC 没事。试过 box_int/box_bool 缓存无效（内存由结构体主导）。**codegen 已证明正确，内存归 Perceus RC 解决。**

### 经验
- 内存峰值监控（Start-Process + PeakWorkingSet64 轮询）是定位"非 codegen crash"的关键——0xC0000028 一开始误判成栈/longjmp，实际是 commit 耗尽。
- 链接 map（`-Wl,/MAP`）+ VA=base+rva 把崩溃地址映射回函数名，确认 sanitize_type 自己是 crash 源。
- "同一 bug 在 js 和 llvm 都触发"曾被误读成 apply_subst 逻辑 bug——实际是 ring.exe 自身（LLVM 编译的）在 checker 阶段崩，与它产出什么 target 无关。

---
