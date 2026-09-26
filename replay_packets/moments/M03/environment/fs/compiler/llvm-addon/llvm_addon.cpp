// Ring LLVM N-API Addon — bridges LLVM-C 22 API for the Ring compiler.
// Auto-generated from compiler/llvm_ffi.ring declarations.

#include <node_api.h>
#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/BitWriter.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <vector>
#include <string>

// ============================================================
// Helper: extract values from napi
// ============================================================

static void* get_ext(napi_env env, napi_value v) {
    void* p = nullptr;
    napi_get_value_external(env, v, &p);
    return p;
}

static napi_value make_ext(napi_env env, void* p) {
    napi_value r;
    napi_create_external(env, p, nullptr, nullptr, &r);
    return r;
}

static int64_t get_i64(napi_env env, napi_value v) {
    int64_t n = 0;
    napi_get_value_int64(env, v, &n);
    return n;
}

static napi_value make_i64(napi_env env, int64_t n) {
    napi_value r;
    napi_create_int64(env, n, &r);
    return r;
}

static double get_f64(napi_env env, napi_value v) {
    double d = 0;
    napi_get_value_double(env, v, &d);
    return d;
}

static napi_value make_f64(napi_env env, double d) {
    napi_value r;
    napi_create_double(env, d, &r);
    return r;
}

static std::string get_str(napi_env env, napi_value v) {
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, &s[0], len + 1, &len);
    return s;
}

static napi_value make_str(napi_env env, const char* s) {
    napi_value r;
    napi_create_string_utf8(env, s ? s : "", NAPI_AUTO_LENGTH, &r);
    return r;
}

static napi_value make_undef(napi_env env) {
    napi_value r;
    napi_get_undefined(env, &r);
    return r;
}

static napi_value get_arg(napi_env env, napi_callback_info info, size_t idx, size_t* argc_out = nullptr) {
    napi_value argv[16];
    size_t argc = 16;
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc_out) *argc_out = argc;
    return (idx < argc) ? argv[idx] : nullptr;
}

// Extract array of externals (for List<LLVMTypeRef> etc.)
static std::vector<void*> get_ext_array(napi_env env, napi_value arr) {
    uint32_t len = 0;
    napi_get_array_length(env, arr, &len);
    std::vector<void*> v(len);
    for (uint32_t i = 0; i < len; i++) {
        napi_value elem;
        napi_get_element(env, arr, i, &elem);
        napi_get_value_external(env, elem, &v[i]);
    }
    return v;
}

// Multi-arg helper
#define ARGS(n) \
    napi_value _argv[n]; size_t _argc = n; \
    napi_get_cb_info(env, info, &_argc, _argv, nullptr, nullptr)

// ============================================================
// Context / Module
// ============================================================

static napi_value w_LLVMContextCreate(napi_env env, napi_callback_info info) {
    return make_ext(env, LLVMContextCreate());
}

static napi_value w_LLVMContextDispose(napi_env env, napi_callback_info info) {
    ARGS(1);
    LLVMContextDispose((LLVMContextRef)get_ext(env, _argv[0]));
    return make_undef(env);
}

static napi_value w_LLVMModuleCreateWithNameInContext(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto name = get_str(env, _argv[0]);
    auto ctx = (LLVMContextRef)get_ext(env, _argv[1]);
    return make_ext(env, LLVMModuleCreateWithNameInContext(name.c_str(), ctx));
}

static napi_value w_LLVMDisposeModule(napi_env env, napi_callback_info info) {
    ARGS(1);
    LLVMDisposeModule((LLVMModuleRef)get_ext(env, _argv[0]));
    return make_undef(env);
}

static napi_value w_LLVMSetTarget(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto triple = get_str(env, _argv[1]);
    LLVMSetTarget(m, triple.c_str());
    return make_undef(env);
}

static napi_value w_LLVMSetDataLayout(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto layout = get_str(env, _argv[1]);
    LLVMSetDataLayout(m, layout.c_str());
    return make_undef(env);
}

static napi_value w_LLVMPrintModuleToString(napi_env env, napi_callback_info info) {
    ARGS(1);
    char* s = LLVMPrintModuleToString((LLVMModuleRef)get_ext(env, _argv[0]));
    napi_value r = make_str(env, s);
    LLVMDisposeMessage(s);
    return r;
}

static napi_value w_LLVMDisposeMessage(napi_env env, napi_callback_info info) {
    // In JS land, strings are GC'd. This is a no-op.
    return make_undef(env);
}

static napi_value w_LLVMVerifyModule(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto action = (LLVMVerifierFailureAction)get_i64(env, _argv[1]);
    char* err = nullptr;
    int result = LLVMVerifyModule(m, action, &err);
    if (err) {
        if (result) fprintf(stderr, "LLVM verify: %s\n", err);
        LLVMDisposeMessage(err);
    }
    return make_i64(env, result);
}

static napi_value w_LLVMWriteBitcodeToFile(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto path = get_str(env, _argv[1]);
    return make_i64(env, LLVMWriteBitcodeToFile(m, path.c_str()));
}

// ============================================================
// Types
// ============================================================

static napi_value w_LLVMVoidTypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMVoidTypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMInt1TypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMInt1TypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMInt8TypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMInt8TypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMInt32TypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMInt32TypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMInt64TypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMInt64TypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMDoubleTypeInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMDoubleTypeInContext((LLVMContextRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMPointerTypeInContext(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto ctx = (LLVMContextRef)get_ext(env, _argv[0]);
    unsigned as = (unsigned)get_i64(env, _argv[1]);
    return make_ext(env, LLVMPointerTypeInContext(ctx, as));
}

static napi_value w_LLVMFunctionType(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto ret = (LLVMTypeRef)get_ext(env, _argv[0]);
    auto params = get_ext_array(env, _argv[1]);
    int va = (int)get_i64(env, _argv[2]);
    return make_ext(env, LLVMFunctionType(ret, (LLVMTypeRef*)params.data(), (unsigned)params.size(), va));
}

static napi_value w_LLVMStructTypeInContext(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto ctx = (LLVMContextRef)get_ext(env, _argv[0]);
    auto elems = get_ext_array(env, _argv[1]);
    int packed = (int)get_i64(env, _argv[2]);
    return make_ext(env, LLVMStructTypeInContext(ctx, (LLVMTypeRef*)elems.data(), (unsigned)elems.size(), packed));
}

static napi_value w_LLVMArrayType2(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto elem = (LLVMTypeRef)get_ext(env, _argv[0]);
    uint64_t count = (uint64_t)get_i64(env, _argv[1]);
    return make_ext(env, LLVMArrayType2(elem, count));
}

// ============================================================
// Values / Constants
// ============================================================

static napi_value w_LLVMConstInt(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[0]);
    unsigned long long val = (unsigned long long)get_i64(env, _argv[1]);
    int se = (int)get_i64(env, _argv[2]);
    return make_ext(env, LLVMConstInt(ty, val, se));
}

static napi_value w_LLVMConstReal(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[0]);
    double val = get_f64(env, _argv[1]);
    return make_ext(env, LLVMConstReal(ty, val));
}

static napi_value w_LLVMConstNull(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMConstNull((LLVMTypeRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMConstPointerNull(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMConstPointerNull((LLVMTypeRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMConstStringInContext(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto ctx = (LLVMContextRef)get_ext(env, _argv[0]);
    auto s = get_str(env, _argv[1]);
    int dnt = (int)get_i64(env, _argv[2]);
    return make_ext(env, LLVMConstStringInContext(ctx, s.c_str(), (unsigned)s.size(), dnt));
}

static napi_value w_LLVMConstArray2(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto elem_ty = (LLVMTypeRef)get_ext(env, _argv[0]);
    auto elems = get_ext_array(env, _argv[1]);
    return make_ext(env, LLVMConstArray2(elem_ty, (LLVMValueRef*)elems.data(), (uint64_t)elems.size()));
}

static napi_value w_LLVMGetUndef(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMGetUndef((LLVMTypeRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMSizeOf(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMSizeOf((LLVMTypeRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMConstBitCast(napi_env env, napi_callback_info info) {
    ARGS(2);
    return make_ext(env, LLVMConstBitCast((LLVMValueRef)get_ext(env, _argv[0]), (LLVMTypeRef)get_ext(env, _argv[1])));
}
static napi_value w_LLVMConstIntToPtr(napi_env env, napi_callback_info info) {
    ARGS(2);
    return make_ext(env, LLVMConstIntToPtr((LLVMValueRef)get_ext(env, _argv[0]), (LLVMTypeRef)get_ext(env, _argv[1])));
}

// ============================================================
// Functions
// ============================================================

static napi_value w_LLVMAddFunction(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto name = get_str(env, _argv[1]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[2]);
    return make_ext(env, LLVMAddFunction(m, name.c_str(), ty));
}

static napi_value w_LLVMGetNamedFunction(napi_env env, napi_callback_info info) {
    ARGS(2);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto name = get_str(env, _argv[1]);
    return make_ext(env, LLVMGetNamedFunction(m, name.c_str()));
}

static napi_value w_LLVMGetParam(napi_env env, napi_callback_info info) {
    ARGS(2);
    return make_ext(env, LLVMGetParam((LLVMValueRef)get_ext(env, _argv[0]), (unsigned)get_i64(env, _argv[1])));
}
static napi_value w_LLVMCountParams(napi_env env, napi_callback_info info) {
    ARGS(1); return make_i64(env, LLVMCountParams((LLVMValueRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMSetLinkage(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMSetLinkage((LLVMValueRef)get_ext(env, _argv[0]), (LLVMLinkage)get_i64(env, _argv[1]));
    return make_undef(env);
}
static napi_value w_LLVMSetFunctionCallConv(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMSetFunctionCallConv((LLVMValueRef)get_ext(env, _argv[0]), (unsigned)get_i64(env, _argv[1]));
    return make_undef(env);
}

static napi_value w_LLVMGetEntryBasicBlock(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMGetEntryBasicBlock((LLVMValueRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMGetBasicBlockParent(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMGetBasicBlockParent((LLVMBasicBlockRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMAddAttributeAtIndex(napi_env env, napi_callback_info info) {
    ARGS(3);
    LLVMAddAttributeAtIndex((LLVMValueRef)get_ext(env, _argv[0]), (LLVMAttributeIndex)get_i64(env, _argv[1]), (LLVMAttributeRef)get_ext(env, _argv[2]));
    return make_undef(env);
}

// ============================================================
// Basic Blocks / Builder
// ============================================================

static napi_value w_LLVMAppendBasicBlockInContext(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto ctx = (LLVMContextRef)get_ext(env, _argv[0]);
    auto fn = (LLVMValueRef)get_ext(env, _argv[1]);
    auto name = get_str(env, _argv[2]);
    return make_ext(env, LLVMAppendBasicBlockInContext(ctx, fn, name.c_str()));
}

static napi_value w_LLVMGetInsertBlock(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMGetInsertBlock((LLVMBuilderRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMCreateBuilderInContext(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMCreateBuilderInContext((LLVMContextRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMDisposeBuilder(napi_env env, napi_callback_info info) {
    ARGS(1); LLVMDisposeBuilder((LLVMBuilderRef)get_ext(env, _argv[0])); return make_undef(env);
}
static napi_value w_LLVMPositionBuilderAtEnd(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMPositionBuilderAtEnd((LLVMBuilderRef)get_ext(env, _argv[0]), (LLVMBasicBlockRef)get_ext(env, _argv[1]));
    return make_undef(env);
}

// ============================================================
// IR Builder — Arithmetic (builder, lhs, rhs, name) -> ValueRef
// ============================================================

#define BINOP(CNAME) \
static napi_value w_##CNAME(napi_env env, napi_callback_info info) { \
    ARGS(4); \
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]); \
    auto lhs = (LLVMValueRef)get_ext(env, _argv[1]); \
    auto rhs = (LLVMValueRef)get_ext(env, _argv[2]); \
    auto name = get_str(env, _argv[3]); \
    return make_ext(env, CNAME(b, lhs, rhs, name.c_str())); \
}

BINOP(LLVMBuildAdd)
BINOP(LLVMBuildSub)
BINOP(LLVMBuildMul)
BINOP(LLVMBuildSDiv)
BINOP(LLVMBuildSRem)
BINOP(LLVMBuildFAdd)
BINOP(LLVMBuildFSub)
BINOP(LLVMBuildFMul)
BINOP(LLVMBuildFDiv)

// ============================================================
// IR Builder — Comparison (builder, pred, lhs, rhs, name)
// ============================================================

static napi_value w_LLVMBuildICmp(napi_env env, napi_callback_info info) {
    ARGS(5);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto pred = (LLVMIntPredicate)get_i64(env, _argv[1]);
    auto lhs = (LLVMValueRef)get_ext(env, _argv[2]);
    auto rhs = (LLVMValueRef)get_ext(env, _argv[3]);
    auto name = get_str(env, _argv[4]);
    return make_ext(env, LLVMBuildICmp(b, pred, lhs, rhs, name.c_str()));
}
static napi_value w_LLVMBuildFCmp(napi_env env, napi_callback_info info) {
    ARGS(5);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto pred = (LLVMRealPredicate)get_i64(env, _argv[1]);
    auto lhs = (LLVMValueRef)get_ext(env, _argv[2]);
    auto rhs = (LLVMValueRef)get_ext(env, _argv[3]);
    auto name = get_str(env, _argv[4]);
    return make_ext(env, LLVMBuildFCmp(b, pred, lhs, rhs, name.c_str()));
}

// ============================================================
// IR Builder — Memory
// ============================================================

static napi_value w_LLVMBuildAlloca(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto name = get_str(env, _argv[2]);
    return make_ext(env, LLVMBuildAlloca(b, ty, name.c_str()));
}

static napi_value w_LLVMBuildLoad2(napi_env env, napi_callback_info info) {
    ARGS(4);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto ptr = (LLVMValueRef)get_ext(env, _argv[2]);
    auto name = get_str(env, _argv[3]);
    return make_ext(env, LLVMBuildLoad2(b, ty, ptr, name.c_str()));
}

static napi_value w_LLVMBuildStore(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto val = (LLVMValueRef)get_ext(env, _argv[1]);
    auto ptr = (LLVMValueRef)get_ext(env, _argv[2]);
    return make_ext(env, LLVMBuildStore(b, val, ptr));
}

static napi_value w_LLVMBuildGEP2(napi_env env, napi_callback_info info) {
    ARGS(5);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto ptr = (LLVMValueRef)get_ext(env, _argv[2]);
    auto indices = get_ext_array(env, _argv[3]);
    auto name = get_str(env, _argv[4]);
    return make_ext(env, LLVMBuildGEP2(b, ty, ptr, (LLVMValueRef*)indices.data(), (unsigned)indices.size(), name.c_str()));
}

static napi_value w_LLVMBuildStructGEP2(napi_env env, napi_callback_info info) {
    ARGS(5);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto ptr = (LLVMValueRef)get_ext(env, _argv[2]);
    unsigned idx = (unsigned)get_i64(env, _argv[3]);
    auto name = get_str(env, _argv[4]);
    return make_ext(env, LLVMBuildStructGEP2(b, ty, ptr, idx, name.c_str()));
}

// ============================================================
// IR Builder — Control Flow
// ============================================================

static napi_value w_LLVMBuildBr(napi_env env, napi_callback_info info) {
    ARGS(2);
    return make_ext(env, LLVMBuildBr((LLVMBuilderRef)get_ext(env, _argv[0]), (LLVMBasicBlockRef)get_ext(env, _argv[1])));
}

static napi_value w_LLVMBuildCondBr(napi_env env, napi_callback_info info) {
    ARGS(4);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto cond = (LLVMValueRef)get_ext(env, _argv[1]);
    auto then_bb = (LLVMBasicBlockRef)get_ext(env, _argv[2]);
    auto else_bb = (LLVMBasicBlockRef)get_ext(env, _argv[3]);
    return make_ext(env, LLVMBuildCondBr(b, cond, then_bb, else_bb));
}

static napi_value w_LLVMBuildRet(napi_env env, napi_callback_info info) {
    ARGS(2);
    return make_ext(env, LLVMBuildRet((LLVMBuilderRef)get_ext(env, _argv[0]), (LLVMValueRef)get_ext(env, _argv[1])));
}
static napi_value w_LLVMBuildRetVoid(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMBuildRetVoid((LLVMBuilderRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMBuildUnreachable(napi_env env, napi_callback_info info) {
    ARGS(1); return make_ext(env, LLVMBuildUnreachable((LLVMBuilderRef)get_ext(env, _argv[0])));
}

static napi_value w_LLVMBuildSwitch(napi_env env, napi_callback_info info) {
    ARGS(4);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto val = (LLVMValueRef)get_ext(env, _argv[1]);
    auto else_bb = (LLVMBasicBlockRef)get_ext(env, _argv[2]);
    unsigned nc = (unsigned)get_i64(env, _argv[3]);
    return make_ext(env, LLVMBuildSwitch(b, val, else_bb, nc));
}

static napi_value w_LLVMAddCase(napi_env env, napi_callback_info info) {
    ARGS(3);
    LLVMAddCase((LLVMValueRef)get_ext(env, _argv[0]), (LLVMValueRef)get_ext(env, _argv[1]), (LLVMBasicBlockRef)get_ext(env, _argv[2]));
    return make_undef(env);
}

// ============================================================
// IR Builder — Call
// ============================================================

static napi_value w_LLVMBuildCall2(napi_env env, napi_callback_info info) {
    ARGS(5);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto fn_ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto fn_val = (LLVMValueRef)get_ext(env, _argv[2]);
    auto args = get_ext_array(env, _argv[3]);
    auto name = get_str(env, _argv[4]);
    return make_ext(env, LLVMBuildCall2(b, fn_ty, fn_val, (LLVMValueRef*)args.data(), (unsigned)args.size(), name.c_str()));
}

// ============================================================
// IR Builder — Type Conversion
// ============================================================

#define CAST_OP(CNAME) \
static napi_value w_##CNAME(napi_env env, napi_callback_info info) { \
    ARGS(4); \
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]); \
    auto val = (LLVMValueRef)get_ext(env, _argv[1]); \
    auto ty = (LLVMTypeRef)get_ext(env, _argv[2]); \
    auto name = get_str(env, _argv[3]); \
    return make_ext(env, CNAME(b, val, ty, name.c_str())); \
}

CAST_OP(LLVMBuildBitCast)
CAST_OP(LLVMBuildIntToPtr)
CAST_OP(LLVMBuildPtrToInt)
CAST_OP(LLVMBuildTrunc)
CAST_OP(LLVMBuildZExt)

// ============================================================
// IR Builder — Phi
// ============================================================

static napi_value w_LLVMBuildPhi(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto name = get_str(env, _argv[2]);
    return make_ext(env, LLVMBuildPhi(b, ty, name.c_str()));
}

static napi_value w_LLVMAddIncoming(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto phi = (LLVMValueRef)get_ext(env, _argv[0]);
    auto vals = get_ext_array(env, _argv[1]);
    auto blocks = get_ext_array(env, _argv[2]);
    LLVMAddIncoming(phi, (LLVMValueRef*)vals.data(), (LLVMBasicBlockRef*)blocks.data(), (unsigned)vals.size());
    return make_undef(env);
}

// ============================================================
// IR Builder — Globals
// ============================================================

static napi_value w_LLVMAddGlobal(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto m = (LLVMModuleRef)get_ext(env, _argv[0]);
    auto ty = (LLVMTypeRef)get_ext(env, _argv[1]);
    auto name = get_str(env, _argv[2]);
    return make_ext(env, LLVMAddGlobal(m, ty, name.c_str()));
}

static napi_value w_LLVMSetInitializer(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMSetInitializer((LLVMValueRef)get_ext(env, _argv[0]), (LLVMValueRef)get_ext(env, _argv[1]));
    return make_undef(env);
}
static napi_value w_LLVMSetGlobalConstant(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMSetGlobalConstant((LLVMValueRef)get_ext(env, _argv[0]), (LLVMBool)get_i64(env, _argv[1]));
    return make_undef(env);
}

static napi_value w_LLVMBuildGlobalStringPtr(napi_env env, napi_callback_info info) {
    ARGS(3);
    auto b = (LLVMBuilderRef)get_ext(env, _argv[0]);
    auto s = get_str(env, _argv[1]);
    auto name = get_str(env, _argv[2]);
    return make_ext(env, LLVMBuildGlobalStringPtr(b, s.c_str(), name.c_str()));
}

// ============================================================
// Target Machine
// ============================================================

static napi_value w_LLVMInitializeX86TargetInfo(napi_env env, napi_callback_info info) {
    LLVMInitializeX86TargetInfo(); return make_undef(env);
}
static napi_value w_LLVMInitializeX86Target(napi_env env, napi_callback_info info) {
    LLVMInitializeX86Target(); return make_undef(env);
}
static napi_value w_LLVMInitializeX86TargetMC(napi_env env, napi_callback_info info) {
    LLVMInitializeX86TargetMC(); return make_undef(env);
}
static napi_value w_LLVMInitializeX86AsmPrinter(napi_env env, napi_callback_info info) {
    LLVMInitializeX86AsmPrinter(); return make_undef(env);
}

static napi_value w_LLVMGetDefaultTargetTriple(napi_env env, napi_callback_info info) {
    char* t = LLVMGetDefaultTargetTriple();
    napi_value r = make_str(env, t);
    LLVMDisposeMessage(t);
    return r;
}

static napi_value w_LLVMGetTargetFromTriple(napi_env env, napi_callback_info info) {
    ARGS(1);
    auto triple = get_str(env, _argv[0]);
    LLVMTargetRef target = nullptr;
    char* err = nullptr;
    if (LLVMGetTargetFromTriple(triple.c_str(), &target, &err)) {
        std::string msg = err ? err : "unknown error";
        if (err) LLVMDisposeMessage(err);
        napi_throw_error(env, nullptr, msg.c_str());
        return make_undef(env);
    }
    if (err) LLVMDisposeMessage(err);
    return make_ext(env, target);
}

static napi_value w_LLVMCreateTargetMachine(napi_env env, napi_callback_info info) {
    ARGS(7);
    auto target = (LLVMTargetRef)get_ext(env, _argv[0]);
    auto triple = get_str(env, _argv[1]);
    auto cpu = get_str(env, _argv[2]);
    auto features = get_str(env, _argv[3]);
    auto codegen = (LLVMCodeGenOptLevel)get_i64(env, _argv[4]);
    auto reloc = (LLVMRelocMode)get_i64(env, _argv[5]);
    auto code_model = (LLVMCodeModel)get_i64(env, _argv[6]);
    return make_ext(env, LLVMCreateTargetMachine(target, triple.c_str(), cpu.c_str(), features.c_str(), codegen, reloc, code_model));
}

static napi_value w_LLVMDisposeTargetMachine(napi_env env, napi_callback_info info) {
    ARGS(1); LLVMDisposeTargetMachine((LLVMTargetMachineRef)get_ext(env, _argv[0])); return make_undef(env);
}

// Extra helpers not in LLVM-C but needed by Ring codegen
static napi_value w_LLVMGetFirstInstruction(napi_env env, napi_callback_info info) {
    ARGS(1);
    return make_ext(env, LLVMGetFirstInstruction((LLVMBasicBlockRef)get_ext(env, _argv[0])));
}
static napi_value w_LLVMPositionBuilderBefore(napi_env env, napi_callback_info info) {
    ARGS(2);
    LLVMPositionBuilderBefore((LLVMBuilderRef)get_ext(env, _argv[0]), (LLVMValueRef)get_ext(env, _argv[1]));
    return make_undef(env);
}
static napi_value w_LLVMIsNullPtr(napi_env env, napi_callback_info info) {
    ARGS(1);
    void* p = get_ext(env, _argv[0]);
    return make_i64(env, p == nullptr ? 1 : 0);
}

static napi_value w_LLVMTargetMachineEmitToFile(napi_env env, napi_callback_info info) {
    ARGS(4);
    auto tm = (LLVMTargetMachineRef)get_ext(env, _argv[0]);
    auto m = (LLVMModuleRef)get_ext(env, _argv[1]);
    auto filename = get_str(env, _argv[2]);
    auto file_type = (LLVMCodeGenFileType)get_i64(env, _argv[3]);
    char* err = nullptr;
    // LLVMTargetMachineEmitToFile takes a non-const char* for filename on some versions
    std::vector<char> fn_buf(filename.begin(), filename.end());
    fn_buf.push_back('\0');
    int result = LLVMTargetMachineEmitToFile(tm, m, fn_buf.data(), file_type, &err);
    if (err) {
        if (result) fprintf(stderr, "LLVM emit: %s\n", err);
        LLVMDisposeMessage(err);
    }
    return make_i64(env, result);
}

// ============================================================
// Module registration
// ============================================================

#define REG(name) { #name, nullptr, w_##name, nullptr, nullptr, nullptr, napi_enumerable, nullptr }

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor props[] = {
        // Context / Module
        REG(LLVMContextCreate),
        REG(LLVMContextDispose),
        REG(LLVMModuleCreateWithNameInContext),
        REG(LLVMDisposeModule),
        REG(LLVMSetTarget),
        REG(LLVMSetDataLayout),
        REG(LLVMPrintModuleToString),
        REG(LLVMDisposeMessage),
        REG(LLVMVerifyModule),
        REG(LLVMWriteBitcodeToFile),
        // Types
        REG(LLVMVoidTypeInContext),
        REG(LLVMInt1TypeInContext),
        REG(LLVMInt8TypeInContext),
        REG(LLVMInt32TypeInContext),
        REG(LLVMInt64TypeInContext),
        REG(LLVMDoubleTypeInContext),
        REG(LLVMPointerTypeInContext),
        REG(LLVMFunctionType),
        REG(LLVMStructTypeInContext),
        REG(LLVMArrayType2),
        // Values / Constants
        REG(LLVMConstInt),
        REG(LLVMConstReal),
        REG(LLVMConstNull),
        REG(LLVMConstPointerNull),
        REG(LLVMConstStringInContext),
        REG(LLVMConstArray2),
        REG(LLVMGetUndef),
        REG(LLVMSizeOf),
        REG(LLVMConstBitCast),
        REG(LLVMConstIntToPtr),
        // Functions
        REG(LLVMAddFunction),
        REG(LLVMGetNamedFunction),
        REG(LLVMGetParam),
        REG(LLVMCountParams),
        REG(LLVMSetLinkage),
        REG(LLVMSetFunctionCallConv),
        REG(LLVMGetEntryBasicBlock),
        REG(LLVMGetBasicBlockParent),
        REG(LLVMAddAttributeAtIndex),
        // Basic Blocks / Builder
        REG(LLVMAppendBasicBlockInContext),
        REG(LLVMGetInsertBlock),
        REG(LLVMCreateBuilderInContext),
        REG(LLVMDisposeBuilder),
        REG(LLVMPositionBuilderAtEnd),
        // Arithmetic
        REG(LLVMBuildAdd),
        REG(LLVMBuildSub),
        REG(LLVMBuildMul),
        REG(LLVMBuildSDiv),
        REG(LLVMBuildSRem),
        REG(LLVMBuildFAdd),
        REG(LLVMBuildFSub),
        REG(LLVMBuildFMul),
        REG(LLVMBuildFDiv),
        // Comparison
        REG(LLVMBuildICmp),
        REG(LLVMBuildFCmp),
        // Memory
        REG(LLVMBuildAlloca),
        REG(LLVMBuildLoad2),
        REG(LLVMBuildStore),
        REG(LLVMBuildGEP2),
        REG(LLVMBuildStructGEP2),
        // Control Flow
        REG(LLVMBuildBr),
        REG(LLVMBuildCondBr),
        REG(LLVMBuildRet),
        REG(LLVMBuildRetVoid),
        REG(LLVMBuildUnreachable),
        REG(LLVMBuildSwitch),
        REG(LLVMAddCase),
        // Call
        REG(LLVMBuildCall2),
        // Casts
        REG(LLVMBuildBitCast),
        REG(LLVMBuildIntToPtr),
        REG(LLVMBuildPtrToInt),
        REG(LLVMBuildTrunc),
        REG(LLVMBuildZExt),
        // Phi
        REG(LLVMBuildPhi),
        REG(LLVMAddIncoming),
        // Globals
        REG(LLVMAddGlobal),
        REG(LLVMSetInitializer),
        REG(LLVMSetGlobalConstant),
        REG(LLVMBuildGlobalStringPtr),
        // Target
        REG(LLVMInitializeX86TargetInfo),
        REG(LLVMInitializeX86Target),
        REG(LLVMInitializeX86TargetMC),
        REG(LLVMInitializeX86AsmPrinter),
        REG(LLVMGetDefaultTargetTriple),
        REG(LLVMGetTargetFromTriple),
        REG(LLVMCreateTargetMachine),
        REG(LLVMDisposeTargetMachine),
        REG(LLVMTargetMachineEmitToFile),
        // Extra helpers
        REG(LLVMGetFirstInstruction),
        REG(LLVMPositionBuilderBefore),
        REG(LLVMIsNullPtr),
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
