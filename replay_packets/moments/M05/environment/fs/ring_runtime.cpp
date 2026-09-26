// ring_runtime.cpp — C ABI runtime for Ring LLVM native backend
// Target: x86_64-pc-windows-msvc (MSVC compatible)
// Convention: all functions extern "C", void* in/out (or int64_t/double for unboxing)
// Memory: Perceus RC (L0) — every heap object has an 8-byte header [rc:u32 | typeid:u32]
//         before the data pointer.  ring_alloc returns data ptr; ring_dup/ring_drop
//         manage the refcount; ring_drop dispatches per-type destructors via drop_table.

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <csetjmp>
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>

#include <cctype>
#include <sstream>

#ifdef _WIN32
#include <direct.h>  // _getcwd
#include <io.h>      // _access
#include <windows.h> // GetFullPathName
#include <intrin.h>  // _ReturnAddress
#define PATH_SEP '\\'
#else
#include <unistd.h>  // getcwd, access
#define PATH_SEP '/'
#endif

// ============================================================================
// Type aliases (documentation only — all cross-boundary types are void*)
//   Str          = std::string*     (data ptr into ring_alloc'd block)
//   List         = std::vector<void*>*
//   Map          = std::unordered_map<std::string, void*>*
//   MapInt       = std::unordered_map<int64_t, void*>*
//   Set          = std::unordered_set<std::string>*
//   SetInt       = std::unordered_set<int64_t>*
//   StringBuilder = std::string*
//
// Object layout (after ring_alloc):
//   [rc:u32 | typeid:u32 | ...data...]
//    ^                     ^
//    ptr-8                 ptr  (returned by ring_alloc, used everywhere)
// ============================================================================

// ============================================================================
// Perceus RC L0 — TypeID constants
// ============================================================================

#define RING_TYPEID_INT       0
#define RING_TYPEID_FLOAT     1
#define RING_TYPEID_BOOL      2
#define RING_TYPEID_STR       3
#define RING_TYPEID_LIST      4
#define RING_TYPEID_MAP       5
#define RING_TYPEID_SET       6
#define RING_TYPEID_CLOSURE   7
#define RING_TYPEID_OPTION    8
#define RING_TYPEID_UNIT      9
#define RING_TYPEID_TUPLE    10
#define RING_TYPEID_MAP_INT  11
#define RING_TYPEID_SET_INT  12
#define RING_TYPEID_SB       13   // StringBuilder (same underlying type as Str)
#define RING_TYPEID_CELL     14   // boxed mut-cell: { void* value } — write-through closure capture (B-091)
#define RING_TYPEID_CLOSURE_ENV 15 // closure env struct: { int64 count, void* cap0, ... } — owned-capture drop (B-084)
#define RING_TYPEID_USER_BASE 64  // user-defined types start here

// ============================================================================
// Perceus RC L0 — drop dispatch table
// ============================================================================

typedef void (*ring_drop_fn)(void* data);
static ring_drop_fn drop_table[4096];
static int drop_table_size = RING_TYPEID_USER_BASE;

// Forward declarations for RC infrastructure
static void ring_drop_by_typeid(uint32_t tid, void* data);

// Crash context (defined here so the RC guards below can reference it; the CHK
// macro that mutates these lives further down, before the first runtime fn).
static int g_chk = 0;
static const char* g_last_fn = "";

// Diagnostic: print the call stack (as module RVAs) at an RC guard abort so the
// triggering Ring function can be mapped via the linker .map.  #134 hunt only.
#ifdef _WIN32
static void dump_rc_backtrace(const char* tag) {
    void* frames[40];
    USHORT n = CaptureStackBackTrace(2, 40, frames, NULL);  // skip this fn + the guard
    uintptr_t base = (uintptr_t)GetModuleHandle(NULL);
    fprintf(stderr, "  %s backtrace (RVA):", tag);
    for (USHORT i = 0; i < n; i++) {
        fprintf(stderr, " 0x%llx", (unsigned long long)((uintptr_t)frames[i] - base));
    }
    fprintf(stderr, "\n");
}
#else
static void dump_rc_backtrace(const char*) {}
#endif

// ============================================================================
// Perceus RC L0 — ring_alloc / ring_dup / ring_drop
// ============================================================================

extern "C" void* ring_alloc(int64_t size, int64_t typeid_val) {
    char* raw = (char*)malloc(8 + (size_t)size);
    if (!raw) {
        fprintf(stderr, "ring panic: ring_alloc failed (size=%lld, typeid=%lld)\n",
                (long long)size, (long long)typeid_val);
        exit(1);
    }
    *(uint32_t*)(raw)     = 1;                    // rc = 1 (new allocation)
    *(uint32_t*)(raw + 4) = (uint32_t)typeid_val; // typeid
    return raw + 8;                               // return data pointer
}

extern "C" void ring_dup(void* ptr) {
    if (!ptr) return;
    uint32_t* rc = (uint32_t*)((char*)ptr - 8);

    // UAF detection: sentinel means this memory was freed
    if (*rc == 0xDEADBEEF) {
        uint32_t freed_tid = *(uint32_t*)((char*)ptr - 4);  // preserved by ring_drop (diag)
        void* ret = __builtin_return_address(0);
#ifdef _WIN32
        uintptr_t base = (uintptr_t)GetModuleHandle(NULL);
        fprintf(stderr, "ring panic: dup on freed memory! ptr=%p freed_tid=%u chk=%d last_fn=%s caller=%p rva=0x%llx (use-after-free)\n",
                ptr, freed_tid, g_chk, g_last_fn, ret, (unsigned long long)((uintptr_t)ret - base));
#else
        fprintf(stderr, "ring panic: dup on freed memory! ptr=%p freed_tid=%u chk=%d last_fn=%s caller=%p (use-after-free)\n",
                ptr, freed_tid, g_chk, g_last_fn, ret);
#endif
        fflush(stderr);
        abort();
    }

    // rc==0 should never happen for live objects (alloc sets rc=1)
    if (*rc == 0) {
        fprintf(stderr, "ring panic: dup on zero-rc object! ptr=%p (likely double-free or corruption)\n", ptr);
        fflush(stderr);
        abort();
    }

    // Overflow detection
    if (*rc >= 0xFFFFFFF0) {
        fprintf(stderr, "ring panic: rc overflow! ptr=%p, rc=%u\n", ptr, *rc);
        fflush(stderr);
        abort();
    }

    *rc += 1;
}

extern "C" void ring_drop(void* ptr) {
    if (!ptr) return;
    uint32_t* rc = (uint32_t*)((char*)ptr - 8);

    // Double-free detection: rc==0 means already freed (or UAF sentinel hit)
    if (*rc == 0) {
        uint32_t tid = *(uint32_t*)((char*)ptr - 4);
        fprintf(stderr, "ring panic: double-free detected! ptr=%p, typeid=%u\n", ptr, tid);
        fflush(stderr);
        abort();
    }

    // UAF sentinel detection: 0xDEADBEEF in rc slot means freed memory
    if (*rc == 0xDEADBEEF) {
        uint32_t freed_tid = *(uint32_t*)((char*)ptr - 4);  // preserved by ring_drop (diag)
        void* ret = __builtin_return_address(0);
#ifdef _WIN32
        uintptr_t base = (uintptr_t)GetModuleHandle(NULL);
        fprintf(stderr, "ring panic: use-after-free detected! ptr=%p freed_tid=%u chk=%d last_fn=%s caller=%p rva=0x%llx (drop on freed)\n",
                ptr, freed_tid, g_chk, g_last_fn, ret, (unsigned long long)((uintptr_t)ret - base));
        dump_rc_backtrace("drop-uaf");
#else
        fprintf(stderr, "ring panic: use-after-free detected! ptr=%p freed_tid=%u chk=%d last_fn=%s caller=%p (drop on freed)\n",
                ptr, freed_tid, g_chk, g_last_fn, ret);
#endif
        fflush(stderr);
        abort();
    }

    if (*rc <= 1) {
        uint32_t tid = *(uint32_t*)((char*)ptr - 4);
        ring_drop_by_typeid(tid, ptr);
        // Write sentinel before free to detect UAF on this block.  Only the rc
        // slot (-8) gets the sentinel; the typeid slot (-4) is preserved so the
        // dup/drop UAF guards can report what kind of object was freed (diag).
        *(uint32_t*)((char*)ptr - 8) = 0xDEADBEEF;
        free((char*)ptr - 8);
    } else {
        *rc -= 1;
    }
}

extern "C" void ring_register_drop(int64_t typeid_val, void* drop_fn_ptr) {
    if (typeid_val >= 0 && typeid_val < 4096) {
        drop_table[(int)typeid_val] = (ring_drop_fn)drop_fn_ptr;
    }
#ifdef _WIN32
    if (getenv("RING_DUMP_TIDS")) {  // #134 diag: map typeid → drop_<Type> via ring.map
        fprintf(stderr, "regdrop tid=%lld rva=0x%llx\n", (long long)typeid_val,
                (unsigned long long)((uintptr_t)drop_fn_ptr - (uintptr_t)GetModuleHandle(NULL)));
    }
#endif
}

static void ring_drop_by_typeid(uint32_t tid, void* data) {
    if (tid < 4096 && drop_table[tid]) {
        drop_table[tid](data);
    }
    // If no drop function registered (e.g. user types without fields to drop),
    // the raw block is still freed by ring_drop — the destructor is a no-op.
}

// ============================================================================
// Perceus RC L0 — per-builtin drop functions (scalars + Str)
// Container drops are defined after RingClosure / Map / Set typedefs.
// ============================================================================

static void drop_int(void* /*data*/)   { /* no-op, scalar */ }
static void drop_float(void* /*data*/) { /* no-op, scalar */ }
static void drop_bool(void* /*data*/)  { /* no-op, scalar */ }
static void drop_unit(void* /*data*/)  { /* no-op, no payload */ }

static void drop_str(void* data) {
    // data points at an in-place std::string; destruct but don't free
    // (the whole block including header is freed by ring_drop).
    ((std::string*)data)->~basic_string();
}

static void drop_cell(void* data) {
    // Boxed mut-cell (B-091): { void* value }.  A `let mut` captured by a
    // write-through closure is auto-boxed into this single-slot heap cell so the
    // outer scope and the closure env share one mutable container.  When the cell
    // itself dies, release the value it currently holds.  Must NOT reuse the
    // CLOSURE typeid: drop_closure reads field[1] (env_ptr) which is OOB for a
    // 1-slot cell.
    void* value = *(void**)data;
    if (value) ring_drop(value);
}

// Forward-declared; defined after container typedefs are available.
static void drop_list(void* data);
static void drop_map(void* data);
static void drop_map_int(void* data);
static void drop_set(void* data);
static void drop_set_int(void* data);
static void drop_closure(void* data);
static void drop_closure_env(void* data);
static void drop_option(void* data);
static void drop_tuple(void* data);
static void drop_sb(void* data);

// ============================================================================
// RingClosure — closure representation for higher-order functions
// ============================================================================

struct RingClosure {
    void* fn_ptr;   // function pointer
    void* env_ptr;  // captured environment pointer
};

typedef void* (*ring_fn_1)(void* env, void* arg);
typedef void* (*ring_fn_2)(void* env, void* a, void* b);

// ============================================================================
// Forward declarations
// ============================================================================

static void* ring_enum_some(void* val);
static void* ring_enum_none();
extern "C" void ring_raise(void* error);

// ============================================================================
// Global state
// ============================================================================

static int g_argc = 0;
static char** g_argv = nullptr;

// Lightweight crash context: a step counter and the last runtime function entered.
// Two stores per runtime call — cheap enough to leave on, and lets the SEH crash
// handler / null guards report roughly where a fault occurred. (The previous
// 64-entry ring buffer was debug-only scaffolding and has been removed.)
// (g_chk / g_last_fn are defined above, near the RC guards that read them.)
#define CHK(name) do { g_chk++; g_last_fn = (name); } while(0)
#define CHK_ARG(name, arg) do { g_chk++; g_last_fn = (name); } while(0)

static void dump_trace() {
    fprintf(stderr, "=== ring: %d runtime calls, last = %s ===\n", g_chk, g_last_fn);
    fflush(stderr);
}

#ifdef _WIN32
static LONG WINAPI crash_handler(EXCEPTION_POINTERS* ep) {
    HMODULE mod = GetModuleHandle(NULL);
    uintptr_t rva = ep->ContextRecord->Rip - (uintptr_t)mod;
    fprintf(stderr, "CRASH chk=%d fn=%s code=0x%08lx rip=%p base=%p rva=0x%llx\n",
            g_chk, g_last_fn,
            ep->ExceptionRecord->ExceptionCode,
            (void*)ep->ContextRecord->Rip,
            (void*)mod,
            (unsigned long long)rva);
    fprintf(stderr, "  rax=%p rbx=%p rcx=%p rdx=%p\n  rsi=%p rdi=%p rsp=%p rbp=%p\n",
            (void*)ep->ContextRecord->Rax, (void*)ep->ContextRecord->Rbx,
            (void*)ep->ContextRecord->Rcx, (void*)ep->ContextRecord->Rdx,
            (void*)ep->ContextRecord->Rsi, (void*)ep->ContextRecord->Rdi,
            (void*)ep->ContextRecord->Rsp, (void*)ep->ContextRecord->Rbp);
    fprintf(stderr, "  fault_addr=%p\n", (void*)ep->ExceptionRecord->ExceptionInformation[1]);
    // Dump instruction bytes at crash point
    unsigned char* ip = (unsigned char*)ep->ContextRecord->Rip;
    fprintf(stderr, "  bytes at rip: ");
    for (int i = -5; i < 10; i++) fprintf(stderr, "%02x ", ip[i]);
    fprintf(stderr, "\n");
    // Stack walk: dump potential return addresses and raw stack data
    uintptr_t base = (uintptr_t)mod;
    uintptr_t text_end = base + 0xB4000;
    uintptr_t* sp = (uintptr_t*)ep->ContextRecord->Rsp;
    fprintf(stderr, "  stack return addresses (RVA):\n");
    int found = 0;
    for (int i = 0; i < 128 && found < 20; i++) {
        uintptr_t val = sp[i];
        if (val > base && val < text_end) {
            fprintf(stderr, "    [rsp+0x%x] = %p (rva=0x%llx)\n",
                    i * 8, (void*)val, (unsigned long long)(val - base));
            found++;
        }
    }
    // Dump raw stack for manual inspection (first 128 qwords)
    fprintf(stderr, "  raw stack dump:\n");
    for (int i = 0; i < 128; i += 4) {
        fprintf(stderr, "    [rsp+0x%03x] %016llx %016llx %016llx %016llx\n",
                i * 8, (unsigned long long)sp[i], (unsigned long long)sp[i+1],
                (unsigned long long)sp[i+2], (unsigned long long)sp[i+3]);
    }
    // Deep inspection: follow InferResult -> HExpr -> tag chain
    // apply_subst frame: push rsi,rdi,rbx (24) + sub rsp,0x150 → 0x168 total + 8 for ret addr
    uintptr_t caller_rsp = (uintptr_t)sp + 0x170;
    // InferResult* at [caller_rsp+0x78]
    fprintf(stderr, "  caller (infer_method_call) rsp=%p\n", (void*)caller_rsp);
    __try {
        uintptr_t infer_result_ptr = *(uintptr_t*)(caller_rsp + 0x78);
        fprintf(stderr, "  InferResult* = %p\n", (void*)infer_result_ptr);
        if (infer_result_ptr > 0x10000) {
            uintptr_t hexpr_ptr = *(uintptr_t*)infer_result_ptr;
            uintptr_t subst_ptr = *(uintptr_t*)(infer_result_ptr + 8);
            uintptr_t effects_ptr = *(uintptr_t*)(infer_result_ptr + 16);
            fprintf(stderr, "  InferResult.hexpr = %p, .subst = %p, .effects = %p\n",
                    (void*)hexpr_ptr, (void*)subst_ptr, (void*)effects_ptr);
            if (hexpr_ptr > 0x10000) {
                int64_t hexpr_tag = *(int64_t*)hexpr_ptr;
                fprintf(stderr, "  HExpr tag = %lld\n", (long long)hexpr_tag);
                uintptr_t* hdata = (uintptr_t*)hexpr_ptr;
                fprintf(stderr, "  HExpr data:");
                for (int k = 0; k < 9; k++) {
                    fprintf(stderr, " [%d]=%p", k, (void*)hdata[k]);
                }
                fprintf(stderr, "\n");
                // If tag=4 (Ident), field[1] is name (Str = std::string*)
                if (hexpr_tag == 4 && hdata[1] > 0x10000) {
                    std::string* name = (std::string*)hdata[1];
                    fprintf(stderr, "  Ident.name = \"%s\"\n", name->c_str());
                    // field[2] = resolved_name (Option<Str>), field[3] = def_id (Option<Int>)
                    if (hdata[2] > 0x10000) {
                        int64_t opt_tag = *(int64_t*)hdata[2];
                        if (opt_tag == 0 && ((uintptr_t*)hdata[2])[1] > 0x10000) {
                            fprintf(stderr, "  Ident.resolved_name = some(\"%s\")\n",
                                    ((std::string*)((uintptr_t*)hdata[2])[1])->c_str());
                        }
                    }
                }
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        fprintf(stderr, "  [failed to read caller data]\n");
    }
    fflush(stderr);
    dump_trace();
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

extern "C" void ring_runtime_init(int argc, char** argv) {
    g_argc = argc;
    g_argv = argv;
#ifdef _WIN32
    SetUnhandledExceptionFilter(crash_handler);
#endif

    // Perceus L0: register builtin drop functions
    drop_table[RING_TYPEID_INT]     = drop_int;
    drop_table[RING_TYPEID_FLOAT]   = drop_float;
    drop_table[RING_TYPEID_BOOL]    = drop_bool;
    drop_table[RING_TYPEID_STR]     = drop_str;
    drop_table[RING_TYPEID_LIST]    = drop_list;
    drop_table[RING_TYPEID_MAP]     = drop_map;
    drop_table[RING_TYPEID_SET]     = drop_set;
    drop_table[RING_TYPEID_CLOSURE] = drop_closure;
    drop_table[RING_TYPEID_OPTION]  = drop_option;
    drop_table[RING_TYPEID_UNIT]    = drop_unit;
    drop_table[RING_TYPEID_TUPLE]   = drop_tuple;
    drop_table[RING_TYPEID_MAP_INT] = drop_map_int;
    drop_table[RING_TYPEID_SET_INT] = drop_set_int;
    drop_table[RING_TYPEID_SB]      = drop_sb;
    drop_table[RING_TYPEID_CELL]    = drop_cell;
    drop_table[RING_TYPEID_CLOSURE_ENV] = drop_closure_env;
}

// ============================================================================
// Boxing / Unboxing (6)
// ============================================================================

extern "C" void* ring_box_int(int64_t val) {
    CHK("box_int");
    void* data = ring_alloc(sizeof(int64_t), RING_TYPEID_INT);
    *(int64_t*)data = val;
    return data;
}

extern "C" int64_t ring_unbox_int(void* p) {
    CHK("unbox_int");
    if (!p) { fprintf(stderr, "ring panic: unbox_int(null) chk=%d (last=%s)\n", g_chk, g_last_fn); dump_rc_backtrace("unbox-null"); exit(1); }
    return *(int64_t*)p;
}

extern "C" void* ring_box_float(double val) {
    void* data = ring_alloc(sizeof(double), RING_TYPEID_FLOAT);
    *(double*)data = val;
    return data;
}

extern "C" double ring_unbox_float(void* p) {
    return *(double*)p;
}

extern "C" void* ring_box_bool(int64_t val) {
    CHK("box_bool");
    void* data = ring_alloc(sizeof(int64_t), RING_TYPEID_BOOL);
    *(int64_t*)data = (val != 0) ? 1 : 0;
    return data;
}

extern "C" int64_t ring_unbox_bool(void* p) {
    CHK("unbox_bool");
    if (!p) { fprintf(stderr, "ring panic: unbox_bool(null) (last=%s)\n", g_last_fn); exit(1); }
    return *(int64_t*)p;
}

// ============================================================================
// Str (~15)
// ============================================================================

extern "C" void* ring_str_new() {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string();
    return data;
}

extern "C" void* ring_str_from_cstr(const char* cstr) {
    CHK("str_from_cstr");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(cstr);
    return data;
}

extern "C" int64_t ring_str_len(void* s) {
    CHK("str_len");
    return (int64_t)((std::string*)s)->size();
}

extern "C" void* ring_str_concat(void* a, void* b) {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(*(std::string*)a + *(std::string*)b);
    return data;
}

extern "C" int64_t ring_str_eq(void* a, void* b) {
    CHK("str_eq");
    if (!a || !b) return (a == b) ? 1 : 0;
    return (*(std::string*)a == *(std::string*)b) ? 1 : 0;
}

extern "C" int64_t ring_str_lt(void* a, void* b) {
    return (*(std::string*)a < *(std::string*)b) ? 1 : 0;
}

extern "C" void* ring_str_get(void* s, int64_t idx) {
    std::string* str = (std::string*)s;
    if (idx < 0 || idx >= (int64_t)str->size()) {
        fprintf(stderr, "ring panic: string index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)str->size());
        exit(1);
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(1, (*str)[(size_t)idx]);
    return data;
}

extern "C" void* ring_str_slice(void* s, int64_t start, int64_t end) {
    std::string* str = (std::string*)s;
    if (start < 0) start = 0;
    if (end > (int64_t)str->size()) end = (int64_t)str->size();
    if (start >= end) {
        void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string();
        return data;
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(str->substr((size_t)start, (size_t)(end - start)));
    return data;
}

extern "C" int64_t ring_str_contains(void* s, void* sub) {
    return ((std::string*)s)->find(*(std::string*)sub) != std::string::npos ? 1 : 0;
}

extern "C" int64_t ring_str_starts_with(void* s, void* prefix) {
    std::string* str = (std::string*)s;
    std::string* pre = (std::string*)prefix;
    if (pre->size() > str->size()) return 0;
    return str->compare(0, pre->size(), *pre) == 0 ? 1 : 0;
}

extern "C" int64_t ring_str_ends_with(void* s, void* suffix) {
    std::string* str = (std::string*)s;
    std::string* suf = (std::string*)suffix;
    if (suf->size() > str->size()) return 0;
    return str->compare(str->size() - suf->size(), suf->size(), *suf) == 0 ? 1 : 0;
}

extern "C" void* ring_str_split(void* s, void* delim) {
    std::string* str = (std::string*)s;
    std::string* del = (std::string*)delim;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    if (del->empty()) {
        // Split into individual characters
        for (size_t i = 0; i < str->size(); i++) {
            void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
            new (sd) std::string(1, (*str)[i]);
            result->push_back(sd);
        }
        return ldata;
    }
    size_t pos = 0, found;
    while ((found = str->find(*del, pos)) != std::string::npos) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(str->substr(pos, found - pos));
        result->push_back(sd);
        pos = found + del->size();
    }
    void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (sd) std::string(str->substr(pos));
    result->push_back(sd);
    return ldata;
}

extern "C" void* ring_str_join(void* sep, void* list) {
    std::string* separator = (std::string*)sep;
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    auto* result = new (data) std::string();
    for (size_t i = 0; i < vec->size(); i++) {
        if (i > 0) *result += *separator;
        *result += *(std::string*)((*vec)[i]);
    }
    return data;
}

extern "C" void* ring_str_replace(void* s, void* from, void* to) {
    std::string result = *(std::string*)s;
    std::string* f = (std::string*)from;
    std::string* t = (std::string*)to;
    if (f->empty()) {
        void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(result);
        return data;
    }
    size_t pos = 0;
    while ((pos = result.find(*f, pos)) != std::string::npos) {
        result.replace(pos, f->size(), *t);
        pos += t->size();
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(result);
    return data;
}

extern "C" void* ring_int_to_str(int64_t val) {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(std::to_string(val));
    return data;
}

// JS-parity double formatting: ECMAScript Number→String (String(x) / console.log)
// produces the *shortest* decimal that round-trips back to the same double
// (3.5 → "3.5", 3.0 → "3", 100.0 → "100", not std::to_string's "3.500000"), and
// chooses fixed vs exponential notation by the ECMA-262 §6.1.6.1.20 rules — NOT by
// printf's "%g" thresholds, which diverge (e.g. "%g" of 100.0 at 1 sig-fig is
// "1e+02" but JS yields "100"). Used by Float.to_str and by print() of a Float arg
// so the LLVM backend matches the JS oracle.
//
// Algorithm: (1) find the fewest significant digits (1..17) whose decimal rendering
// round-trips, capturing the digit string `digits` (no '.') and the base-10 point
// exponent `n` such that value = sign * digits * 10^(n - k) where k=len(digits).
// (2) Apply the ECMAScript ToString(Number) case split on n and k.
static std::string js_double_to_string(double val) {
    if (val != val) return "NaN";
    if (val == 0.0) return "0";          // -0.0 → "0" too (String(-0) === "0")
    bool neg = val < 0.0;
    double a = neg ? -val : val;
    if (a == 1.0/0.0) return neg ? "-Infinity" : "Infinity";

    // Find shortest round-tripping significant-digit string via "%.*e".
    char buf[40];
    int prec = 0;                         // digits after the decimal point in %e
    for (prec = 0; prec <= 16; prec++) {
        snprintf(buf, sizeof(buf), "%.*e", prec, a);
        if (strtod(buf, nullptr) == a) break;
    }
    // buf looks like "d.ddde±XX". Extract significant digits and exponent E
    // (the power of ten of the leading digit).
    std::string s(buf);
    size_t epos = s.find('e');
    std::string mant = s.substr(0, epos);
    int E = atoi(s.c_str() + epos + 1);
    std::string digits;
    for (char c : mant) { if (c >= '0' && c <= '9') digits.push_back(c); }
    // Strip trailing zeros (shortest form); keep at least one digit.
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    int k = (int)digits.size();           // number of significant digits
    int n = E + 1;                        // ECMA's n: value = digits * 10^(n-k)

    std::string out;
    if (k <= n && n <= 21) {
        // Integer with trailing zeros: digits followed by (n-k) zeros.
        out = digits;
        out.append(n - k, '0');
    } else if (0 < n && n <= 21) {
        // Decimal point inside the digit string.
        out = digits.substr(0, n) + "." + digits.substr(n);
    } else if (-6 < n && n <= 0) {
        // 0.00…digits
        out = "0.";
        out.append(-n, '0');
        out += digits;
    } else {
        // Exponential form: d[.ddd]e±(n-1)
        std::string m = digits.substr(0, 1);
        if (k > 1) m += "." + digits.substr(1);
        int exp = n - 1;
        out = m + "e" + (exp >= 0 ? "+" : "-") + std::to_string(exp >= 0 ? exp : -exp);
    }
    return neg ? ("-" + out) : out;
}

extern "C" void* ring_float_to_str(double val) {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(js_double_to_string(val));
    return data;
}

extern "C" void* ring_bool_to_str(int64_t val) {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(val ? "true" : "false");
    return data;
}

// ============================================================================
// List (~18)
// ============================================================================

extern "C" void* ring_list_new() {
    CHK("list_new");
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    new (data) std::vector<void*>();
    return data;
}

extern "C" void* ring_list_push(void* list, void* val) {
    CHK("list_push");
    ((std::vector<void*>*)list)->push_back(val);
    return list;
}

extern "C" void* ring_list_get(void* list, int64_t idx) {
    CHK("list_get");
    auto* vec = (std::vector<void*>*)list;
    if (idx < 0 || idx >= (int64_t)vec->size()) {
        fprintf(stderr, "ring panic: list index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)vec->size());
        exit(1);
    }
    // #134: a read borrows the element; the L0 callee-owns convention means the
    // caller will eventually drop it, so hand back an OWNED reference (the
    // container keeps its own).  Mirrors the field-access dup in gen_field_access.
    void* elem = (*vec)[(size_t)idx];
    ring_dup(elem);
    return elem;
}

extern "C" void* ring_list_set(void* list, int64_t idx, void* val) {
    auto* vec = (std::vector<void*>*)list;
    if (idx < 0 || idx >= (int64_t)vec->size()) {
        fprintf(stderr, "ring panic: list index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)vec->size());
        exit(1);
    }
    (*vec)[(size_t)idx] = val;
    return list;
}

extern "C" int64_t ring_list_len(void* list) {
    CHK("list_len");
    if (!list) { return 0; }
    return (int64_t)((std::vector<void*>*)list)->size();
}

extern "C" void* ring_list_concat(void* a, void* b) {
    auto* va = (std::vector<void*>*)a;
    auto* vb = (std::vector<void*>*)b;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>(*va);
    result->insert(result->end(), vb->begin(), vb->end());
    return data;
}

extern "C" void* ring_list_slice(void* list, int64_t start, int64_t end) {
    auto* vec = (std::vector<void*>*)list;
    int64_t len = (int64_t)vec->size();
    if (start < 0) start = 0;
    if (end > len) end = len;
    if (start >= end) {
        void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
        new (data) std::vector<void*>();
        return data;
    }
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    new (data) std::vector<void*>(vec->begin() + start, vec->begin() + end);
    return data;
}

extern "C" void* ring_list_pop(void* list) {
    auto* vec = (std::vector<void*>*)list;
    if (vec->empty()) {
        void* data = ring_alloc(sizeof(int64_t) * 2, RING_TYPEID_OPTION);
        ((int64_t*)data)[0] = 1; // None tag
        ((int64_t*)data)[1] = 0;
        return data;
    }
    void* val = vec->back();
    vec->pop_back();
    void* data = ring_alloc(sizeof(int64_t) + sizeof(void*), RING_TYPEID_OPTION);
    ((int64_t*)data)[0] = 0; // Some tag
    *((void**)((int64_t*)data + 1)) = val;
    return data;
}

extern "C" int64_t ring_list_contains(void* list, void* val) {
    auto* vec = (std::vector<void*>*)list;
    for (size_t i = 0; i < vec->size(); i++) {
        if ((*vec)[i] == val) return 1;  // pointer comparison (bootstrap)
    }
    return 0;
}

extern "C" int64_t ring_list_index_of(void* list, void* val) {
    auto* vec = (std::vector<void*>*)list;
    for (size_t i = 0; i < vec->size(); i++) {
        if ((*vec)[i] == val) return (int64_t)i;  // pointer comparison
    }
    return -1;
}

extern "C" void* ring_list_get_opt(void* list, int64_t idx) {
    auto* vec = (std::vector<void*>*)list;
    if (idx < 0 || idx >= (int64_t)vec->size()) {
        return ring_enum_none();
    }
    void* elem = (*vec)[(size_t)idx];  // #134: own the element (see ring_list_get)
    ring_dup(elem);
    return ring_enum_some(elem);
}

extern "C" void* ring_list_reverse(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    new (data) std::vector<void*>(vec->rbegin(), vec->rend());
    return data;
}

extern "C" void* ring_list_sort(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>(*vec);
    RingClosure* cmp = (RingClosure*)closure;
    ring_fn_2 fn = (ring_fn_2)(cmp->fn_ptr);
    std::sort(result->begin(), result->end(), [fn, cmp](void* a, void* b) -> bool {
        void* r = fn(cmp->env_ptr, a, b);
        return ring_unbox_int(r) < 0;
    });
    return data;
}

static void* ring_enum_some(void* val) {
    void* data = ring_alloc(sizeof(int64_t) + sizeof(void*), RING_TYPEID_OPTION);
    ((int64_t*)data)[0] = 0;
    *((void**)((int64_t*)data + 1)) = val;
    return data;
}

static void* ring_enum_none() {
    void* data = ring_alloc(sizeof(int64_t) * 2, RING_TYPEID_OPTION);
    ((int64_t*)data)[0] = 1;
    ((int64_t*)data)[1] = 0;
    return data;
}

// ============================================================================
// Option methods
// Option layout: {tag: i64, payload: void*}  tag=0 → Some, tag=1 → None
// ============================================================================

extern "C" void* ring_Option_unwrap_or(void* opt, void* default_val) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) return *((void**)((int64_t*)opt + 1));
    return default_val;
}

extern "C" void* ring_Option_unwrap(void* opt) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) return *((void**)((int64_t*)opt + 1));
    fprintf(stderr, "ring panic: unwrap() called on None\n");
    exit(1);
    return nullptr;
}

extern "C" int64_t ring_Option_is_some(void* opt) {
    return *(int64_t*)opt == 0 ? 1 : 0;
}

extern "C" int64_t ring_Option_is_none(void* opt) {
    return *(int64_t*)opt == 1 ? 1 : 0;
}

extern "C" void* ring_Option_map(void* opt, void* closure) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) {
        void* val = *((void**)((int64_t*)opt + 1));
        RingClosure* cl = (RingClosure*)closure;
        ring_fn_1 fn = (ring_fn_1)cl->fn_ptr;
        void* result = fn(cl->env_ptr, val);
        return ring_enum_some(result);
    }
    return ring_enum_none();
}

// to_fail: Some(v) -> v; None -> raise the fail effect with `err` as the error
// value. The LLVM backend lowers `fail.raise` to a direct ring_raise (longjmp
// into the enclosing ring_try set up by `catch`), so to_fail can raise here
// without threading the fail evidence. Returns nullptr on the None branch only
// for type-correctness; ring_raise never returns.
extern "C" void* ring_Option_to_fail(void* opt, void* err) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) return *((void**)((int64_t*)opt + 1));
    ring_raise(err);
    return nullptr;
}

extern "C" void* ring_Option_unwrap_or_else(void* opt, void* closure) {
    int64_t tag = *(int64_t*)opt;
    if (tag == 0) return *((void**)((int64_t*)opt + 1));
    RingClosure* cl = (RingClosure*)closure;
    typedef void* (*ring_fn_0)(void* env);
    ring_fn_0 fn = (ring_fn_0)cl->fn_ptr;
    return fn(cl->env_ptr);
}

extern "C" void* ring_list_sort_default(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>(*vec);
    std::sort(result->begin(), result->end(), [](void* a, void* b) -> bool {
        return ring_unbox_int(a) < ring_unbox_int(b);
    });
    return data;
}

extern "C" int64_t ring_list_any(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* r = fn(cls->env_ptr, (*vec)[i]);
        if (ring_unbox_int(r) != 0) return 1;
    }
    return 0;
}

extern "C" int64_t ring_list_all(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* r = fn(cls->env_ptr, (*vec)[i]);
        if (ring_unbox_int(r) == 0) return 0;
    }
    return 1;
}

extern "C" void* ring_list_find(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* r = fn(cls->env_ptr, (*vec)[i]);
        if (ring_unbox_int(r) != 0) {
            return ring_enum_some((*vec)[i]);
        }
    }
    return ring_enum_none();
}

// find_index: return Some(boxed index) of the first element satisfying the
// predicate, else None. Mirrors ring_list_find but boxes the index instead of
// returning the element (matches the JS backend's List.find_index semantics).
extern "C" void* ring_list_find_index(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* r = fn(cls->env_ptr, (*vec)[i]);
        if (ring_unbox_int(r) != 0) {
            return ring_enum_some(ring_box_int((int64_t)i));
        }
    }
    return ring_enum_none();
}

// fold: left fold with an explicit accumulator initial value. The closure is
// binary: fn(env, acc, elem) -> acc. Matches the JS backend's
// `list.reduce(cb, init)` lowering (acc is the first closure argument).
extern "C" void* ring_list_fold(void* list, void* init, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_2 fn = (ring_fn_2)(cls->fn_ptr);
    void* acc = init;
    for (size_t i = 0; i < vec->size(); i++) {
        acc = fn(cls->env_ptr, acc, (*vec)[i]);
    }
    return acc;
}

extern "C" void* ring_list_map(void* list, void* closure) {
    if (!list) {
        void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
        new (data) std::vector<void*>();
        return data;
    }
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>();
    result->reserve(vec->size());
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        result->push_back(fn(cls->env_ptr, (*vec)[i]));
    }
    return data;
}

extern "C" void* ring_list_filter(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>();
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* r = fn(cls->env_ptr, (*vec)[i]);
        if (ring_unbox_int(r) != 0) {
            result->push_back((*vec)[i]);
        }
    }
    return data;
}

extern "C" void* ring_list_for_each(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        fn(cls->env_ptr, (*vec)[i]);
    }
    return nullptr;
}

extern "C" int64_t ring_list_is_empty(void* list) {
    return ((std::vector<void*>*)list)->empty() ? 1 : 0;
}

extern "C" void* ring_list_last(void* list) {
    auto* vec = (std::vector<void*>*)list;
    if (vec->empty()) {
        return ring_enum_none();
    }
    return ring_enum_some(vec->back());
}

extern "C" void* ring_list_first(void* list) {
    auto* vec = (std::vector<void*>*)list;
    if (vec->empty()) {
        return ring_enum_none();
    }
    return ring_enum_some(vec->front());
}

// flat_map: apply closure (returns List) to each element, concatenate results.
// Mirrors ring_list_map's closure-call pattern but flattens each returned List.
extern "C" void* ring_list_flat_map(void* list, void* closure) {
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>();
    if (!list) return data;
    auto* vec = (std::vector<void*>*)list;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (size_t i = 0; i < vec->size(); i++) {
        void* sub = fn(cls->env_ptr, (*vec)[i]);
        if (sub) {
            auto* svec = (std::vector<void*>*)sub;
            result->insert(result->end(), svec->begin(), svec->end());
        }
    }
    return data;
}

// ============================================================================
// Map (~10)
// ============================================================================

typedef std::unordered_map<std::string, void*> RingMap;
typedef std::unordered_map<int64_t, void*> RingMapInt;

extern "C" void* ring_map_new() {
    void* data = ring_alloc(sizeof(RingMap), RING_TYPEID_MAP);
    new (data) RingMap();
    return data;
}

extern "C" void* ring_map_get(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    std::string* k = (std::string*)key;
    auto it = m->find(*k);
    if (it == m->end()) {
        fprintf(stderr, "ring panic: map key not found: %s\n", k->c_str());
        exit(1);
    }
    ring_dup(it->second);  // #134: own the read value (see ring_list_get)
    return it->second;
}

extern "C" void* ring_map_get_opt(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    std::string* k = (std::string*)key;
    auto it = m->find(*k);
    if (it == m->end()) return ring_enum_none();
    ring_dup(it->second);  // #134: own the read value
    return ring_enum_some(it->second);
}

extern "C" void* ring_map_set(void* map, void* key, void* val) {
    CHK("map_set");
    RingMap* m = (RingMap*)map;
    (*m)[*(std::string*)key] = val;
    return map;
}

extern "C" int64_t ring_map_has(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    return m->count(*(std::string*)key) > 0 ? 1 : 0;
}

extern "C" void* ring_map_delete(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    m->erase(*(std::string*)key);
    return map;
}

extern "C" void* ring_map_keys(void* map) {
    RingMap* m = (RingMap*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(kv.first);
        result->push_back(sd);
    }
    return ldata;
}

extern "C" void* ring_map_values(void* map) {
    RingMap* m = (RingMap*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        ring_dup(kv.second);  // #134: the returned list owns its elements
        result->push_back(kv.second);
    }
    return ldata;
}

extern "C" void* ring_map_entries(void* map) {
    // Returns List of {key, value} pairs, each pair as a 2-element List
    RingMap* m = (RingMap*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        void* pdata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
        auto* pair = new (pdata) std::vector<void*>();
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(kv.first);
        pair->push_back(sd);
        ring_dup(kv.second);  // #134: the entry pair owns the value
        pair->push_back(kv.second);
        result->push_back(pdata);
    }
    return ldata;
}

extern "C" int64_t ring_map_len(void* map) {
    return (int64_t)((RingMap*)map)->size();
}

extern "C" void* ring_map_for_each(void* map, void* closure) {
    RingMap* m = (RingMap*)map;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_2 fn = (ring_fn_2)(cls->fn_ptr);
    for (auto& kv : *m) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(kv.first);
        fn(cls->env_ptr, sd, kv.second);
    }
    return nullptr;
}

// ============================================================================
// Map<Int> — int64_t-keyed map
// ============================================================================

extern "C" void* ring_map_int_new() {
    void* data = ring_alloc(sizeof(RingMapInt), RING_TYPEID_MAP_INT);
    new (data) RingMapInt();
    return data;
}

extern "C" void* ring_map_int_get(void* map, void* key) {
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    auto it = m->find(k);
    if (it == m->end()) {
        fprintf(stderr, "ring panic: map key not found: %lld\n", (long long)k);
        exit(1);
    }
    ring_dup(it->second);  // #134: own the read value (see ring_list_get)
    return it->second;
}

extern "C" void* ring_map_int_get_opt(void* map, void* key) {
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    auto it = m->find(k);
    if (it == m->end()) return ring_enum_none();
    ring_dup(it->second);  // #134: own the read value
    return ring_enum_some(it->second);
}

extern "C" void* ring_map_int_set(void* map, void* key, void* val) {
    CHK("map_int_set");
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    (*m)[k] = val;
    return map;
}

extern "C" int64_t ring_map_int_has(void* map, void* key) {
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    return m->count(k) > 0 ? 1 : 0;
}

extern "C" void* ring_map_int_delete(void* map, void* key) {
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    m->erase(k);
    return map;
}

extern "C" void* ring_map_int_keys(void* map) {
    RingMapInt* m = (RingMapInt*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        result->push_back(ring_box_int(kv.first));
    }
    return ldata;
}

extern "C" void* ring_map_int_values(void* map) {
    RingMapInt* m = (RingMapInt*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        result->push_back(kv.second);
    }
    return ldata;
}

extern "C" void* ring_map_int_entries(void* map) {
    RingMapInt* m = (RingMapInt*)map;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(m->size());
    for (auto& kv : *m) {
        void* pdata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
        auto* pair = new (pdata) std::vector<void*>();
        pair->push_back(ring_box_int(kv.first));
        pair->push_back(kv.second);
        result->push_back(pdata);
    }
    return ldata;
}

extern "C" int64_t ring_map_int_len(void* map) {
    return (int64_t)((RingMapInt*)map)->size();
}

extern "C" void* ring_map_int_for_each(void* map, void* closure) {
    RingMapInt* m = (RingMapInt*)map;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_2 fn = (ring_fn_2)(cls->fn_ptr);
    for (auto& kv : *m) {
        fn(cls->env_ptr, ring_box_int(kv.first), kv.second);
    }
    return nullptr;
}

extern "C" void* ring_map_int_clone(void* map) {
    RingMapInt* m = (RingMapInt*)map;
    void* data = ring_alloc(sizeof(RingMapInt), RING_TYPEID_MAP_INT);
    new (data) RingMapInt(*m);
    return data;
}

extern "C" void* ring_map_int_from(void* entries) {
    auto* vec = (std::vector<void*>*)entries;
    void* data = ring_alloc(sizeof(RingMapInt), RING_TYPEID_MAP_INT);
    auto* result = new (data) RingMapInt();
    for (size_t i = 0; i < vec->size(); i++) {
        auto* pair = (std::vector<void*>*)((*vec)[i]);
        if (pair->size() >= 2) {
            int64_t key = *(int64_t*)((*pair)[0]);
            (*result)[key] = (*pair)[1];
        }
    }
    return data;
}

extern "C" void* ring_map_int_clear(void* map) {
    ((RingMapInt*)map)->clear();
    return map;
}

// ============================================================================
// Set (~8)
// ============================================================================

typedef std::unordered_set<std::string> RingSet;
typedef std::unordered_set<int64_t> RingSetInt;

extern "C" void* ring_set_new() {
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    new (data) RingSet();
    return data;
}

extern "C" void* ring_set_add(void* set, void* elem) {
    ((RingSet*)set)->insert(*(std::string*)elem);
    return set;
}

extern "C" int64_t ring_set_has(void* set, void* elem) {
    return ((RingSet*)set)->count(*(std::string*)elem) > 0 ? 1 : 0;
}

extern "C" void* ring_set_delete(void* set, void* elem) {
    ((RingSet*)set)->erase(*(std::string*)elem);
    return set;
}

extern "C" void* ring_set_to_list(void* set) {
    RingSet* s = (RingSet*)set;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(s->size());
    for (auto& elem : *s) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(elem);
        result->push_back(sd);
    }
    return ldata;
}

extern "C" int64_t ring_set_len(void* set) {
    return (int64_t)((RingSet*)set)->size();
}

extern "C" void* ring_set_from_list(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    auto* result = new (data) RingSet();
    for (size_t i = 0; i < vec->size(); i++) {
        result->insert(*(std::string*)((*vec)[i]));
    }
    return data;
}

extern "C" void* ring_set_for_each(void* set, void* closure) {
    RingSet* s = (RingSet*)set;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (auto& elem : *s) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(elem);
        fn(cls->env_ptr, sd);
    }
    return nullptr;
}

// ============================================================================
// Set<Int> — int64_t-element set
// ============================================================================

extern "C" void* ring_set_int_new() {
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    new (data) RingSetInt();
    return data;
}

extern "C" void* ring_set_int_add(void* set, void* elem) {
    int64_t k = *(int64_t*)elem;
    ((RingSetInt*)set)->insert(k);
    return set;
}

extern "C" int64_t ring_set_int_has(void* set, void* elem) {
    int64_t k = *(int64_t*)elem;
    return ((RingSetInt*)set)->count(k) > 0 ? 1 : 0;
}

extern "C" void* ring_set_int_delete(void* set, void* elem) {
    int64_t k = *(int64_t*)elem;
    ((RingSetInt*)set)->erase(k);
    return set;
}

extern "C" void* ring_set_int_to_list(void* set) {
    RingSetInt* s = (RingSetInt*)set;
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    result->reserve(s->size());
    for (auto& elem : *s) {
        result->push_back(ring_box_int(elem));
    }
    return ldata;
}

extern "C" int64_t ring_set_int_len(void* set) {
    return (int64_t)((RingSetInt*)set)->size();
}

extern "C" void* ring_set_int_from_list(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    auto* result = new (data) RingSetInt();
    for (size_t i = 0; i < vec->size(); i++) {
        int64_t k = *(int64_t*)((*vec)[i]);
        result->insert(k);
    }
    return data;
}

extern "C" void* ring_set_int_for_each(void* set, void* closure) {
    RingSetInt* s = (RingSetInt*)set;
    RingClosure* cls = (RingClosure*)closure;
    ring_fn_1 fn = (ring_fn_1)(cls->fn_ptr);
    for (auto& elem : *s) {
        fn(cls->env_ptr, ring_box_int(elem));
    }
    return nullptr;
}

extern "C" void* ring_set_int_clone(void* set) {
    RingSetInt* s = (RingSetInt*)set;
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    new (data) RingSetInt(*s);
    return data;
}

extern "C" void* ring_set_int_union(void* a, void* b) {
    RingSetInt* sa = (RingSetInt*)a;
    RingSetInt* sb = (RingSetInt*)b;
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    auto* result = new (data) RingSetInt(*sa);
    for (auto& elem : *sb) {
        result->insert(elem);
    }
    return data;
}

extern "C" void* ring_set_int_intersect(void* a, void* b) {
    RingSetInt* sa = (RingSetInt*)a;
    RingSetInt* sb = (RingSetInt*)b;
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    auto* result = new (data) RingSetInt();
    for (auto& elem : *sa) {
        if (sb->count(elem) > 0) {
            result->insert(elem);
        }
    }
    return data;
}

extern "C" void* ring_set_int_difference(void* a, void* b) {
    RingSetInt* sa = (RingSetInt*)a;
    RingSetInt* sb = (RingSetInt*)b;
    void* data = ring_alloc(sizeof(RingSetInt), RING_TYPEID_SET_INT);
    auto* result = new (data) RingSetInt();
    for (auto& elem : *sa) {
        if (sb->count(elem) == 0) {
            result->insert(elem);
        }
    }
    return data;
}

extern "C" void* ring_set_int_clear(void* set) {
    ((RingSetInt*)set)->clear();
    return set;
}

// ============================================================================
// IO / FS / Process (~8)
// ============================================================================

extern "C" void* ring_print(void* s) {
    CHK("PRINT");
    printf("%s\n", ((std::string*)s)->c_str());
    fflush(stdout);
    fflush(stderr);
    return nullptr;
}

extern "C" void* ring_eprintln(void* s) {
    CHK("EPRINTLN");
    fprintf(stderr, "%s\n", ((std::string*)s)->c_str());
    fflush(stderr);
    return nullptr;
}

extern "C" void* ring_panic(void* s) {
    CHK("PANIC");
    if (s) {
        fprintf(stderr, "ring panic: %s\n", ((std::string*)s)->c_str());
    } else {
        fprintf(stderr, "ring panic: (null message)\n");
    }
    fflush(stderr);
    exit(1);
    return nullptr;  // unreachable
}

// Diagnostic for non-exhaustive enum match: a value reached a match whose tag
// matched no arm. Reports the enum name + enclosing fn (baked in at codegen) and
// the runtime tag. A tag outside the variant range means a miscompiled value.
extern "C" void* ring_match_fail(void* enum_name, int64_t tag, int64_t site, void* scrut) {
    (void)scrut;
    fprintf(stderr, "ring panic: non-exhaustive match on enum '%s' (runtime tag=%lld, site #%lld)\n",
            enum_name ? ((std::string*)enum_name)->c_str() : "?",
            (long long)tag, (long long)site);
    fflush(stderr);
    exit(1);
    return nullptr;  // unreachable
}

extern "C" void* ring_read_file(void* path) {
    std::string* p = (std::string*)path;
    FILE* f = fopen(p->c_str(), "rb");
    if (!f) {
        fprintf(stderr, "ring panic: cannot open file: %s\n", p->c_str());
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    auto* result = new (data) std::string((size_t)size, '\0');
    fread(&(*result)[0], 1, (size_t)size, f);
    fclose(f);
    return data;
}

extern "C" void* ring_write_file(void* path, void* content) {
    std::string* p = (std::string*)path;
    std::string* c = (std::string*)content;
    FILE* f = fopen(p->c_str(), "wb");
    if (!f) {
        fprintf(stderr, "ring panic: cannot write file: %s\n", p->c_str());
        exit(1);
    }
    fwrite(c->data(), 1, c->size(), f);
    fclose(f);
    return nullptr;
}

extern "C" void* ring_exit(void* boxed_code) {
    int64_t code = *(int64_t*)boxed_code;
    fprintf(stderr, "[RING_EXIT] code=%lld\n", (long long)code);
    fflush(stderr);
    exit((int)code);
    return nullptr;  // unreachable
}

extern "C" void* ring_args() {
    void* ldata = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (ldata) std::vector<void*>();
    // Skip argv[0] (program name) to match JS backend behavior
    // where process.argv.slice(2) skips [node, script]
    for (int i = 1; i < g_argc; i++) {
        void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (sd) std::string(g_argv[i]);
        result->push_back(sd);
    }
    return ldata;
}

extern "C" void* ring_cwd() {
    char buf[4096];
#ifdef _WIN32
    if (_getcwd(buf, sizeof(buf)) == nullptr) {
#else
    if (getcwd(buf, sizeof(buf)) == nullptr) {
#endif
        fprintf(stderr, "ring panic: getcwd failed\n");
        exit(1);
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(buf);
    return data;
}

// ============================================================================
// StringBuilder (~4)
// ============================================================================

extern "C" void* ring_sb_new() {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_SB);
    new (data) std::string();
    return data;
}

extern "C" void* ring_sb_add(void* sb, void* s) {
    *(std::string*)sb += *(std::string*)s;
    return sb;
}

extern "C" void* ring_sb_to_str(void* sb) {
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(*(std::string*)sb);
    return data;
}

extern "C" int64_t ring_sb_len(void* sb) {
    return (int64_t)((std::string*)sb)->size();
}

// ============================================================================
// setjmp/longjmp — fail effect handler stack (~5)
// ============================================================================

struct RingCatchFrame {
    jmp_buf buf;
    void* error_value;
    RingCatchFrame* prev;
};

#ifdef _WIN32
__declspec(thread) static RingCatchFrame* ring_catch_stack = nullptr;
#else
thread_local RingCatchFrame* ring_catch_stack = nullptr;
#endif

extern "C" void* ring_catch_push() {
    RingCatchFrame* frame = new RingCatchFrame();
    frame->error_value = nullptr;
    frame->prev = ring_catch_stack;
    ring_catch_stack = frame;
    return (void*)frame;
}

extern "C" int64_t ring_catch_setjmp(void* frame_ptr) {
    RingCatchFrame* frame = (RingCatchFrame*)frame_ptr;
    return (int64_t)setjmp(frame->buf);
}

extern "C" void ring_raise(void* error) {
    if (!ring_catch_stack) {
        fprintf(stderr, "ring panic: unhandled effect raise (no catch frame)\n");
        exit(1);
    }
    RingCatchFrame* frame = ring_catch_stack;
    frame->error_value = error;
    longjmp(frame->buf, 1);
}

extern "C" void* __ring_raise_fail(void* msg) {
    ring_raise(msg);
    return nullptr;
}

extern "C" void* ring_catch_get_error(void* frame_ptr) {
    return ((RingCatchFrame*)frame_ptr)->error_value;
}

extern "C" void ring_catch_pop() {
    RingCatchFrame* frame = ring_catch_stack;
    ring_catch_stack = frame->prev;
    delete frame;
}

// ring_try: correct setjmp/longjmp scoping for `body catch { arms }`.
// The catch frame and setjmp live in THIS function's stack frame, and the body
// closure is invoked nested from here — so a longjmp (from a deeply-nested
// fail.raise) returns into a frame that is still live, unlike a setjmp performed
// inside a wrapper that has already returned.
//   body_cl  : closure {fn(env)->ptr, env}
//   catch_cl : closure {fn(env, error)->ptr, env}
extern "C" void* ring_try(void* body_cl, void* catch_cl) {
    RingCatchFrame frame;
    frame.error_value = nullptr;
    frame.prev = ring_catch_stack;
    ring_catch_stack = &frame;
    void** bc = (void**)body_cl;
    void** cc = (void**)catch_cl;
    if (setjmp(frame.buf) == 0) {
        void* (*bfn)(void*) = (void* (*)(void*))bc[0];
        void* result = bfn(bc[1]);
        ring_catch_stack = frame.prev;   // normal completion: pop
        return result;
    } else {
        ring_catch_stack = frame.prev;   // caught: pop, then run catch arm
        void* err = frame.error_value;
        void* (*cfn)(void*, void*) = (void* (*)(void*, void*))cc[0];
        return cfn(cc[1], err);
    }
}

// ============================================================================
// Path operations (~5)
// ============================================================================

extern "C" void* ring_path_join(void* a, void* b) {
    std::string* sa = (std::string*)a;
    std::string* sb = (std::string*)b;
    void* data;
    if (sa->empty()) {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(*sb);
        return data;
    }
    if (sb->empty()) {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(*sa);
        return data;
    }
    char last = sa->back();
    if (last == '/' || last == '\\') {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(*sa + *sb);
        return data;
    }
    data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(*sa + PATH_SEP + *sb);
    return data;
}

extern "C" void* ring_path_resolve(void* p) {
    std::string* sp = (std::string*)p;
    void* data;
#ifdef _WIN32
    char buf[4096];
    DWORD len = GetFullPathNameA(sp->c_str(), sizeof(buf), buf, nullptr);
    if (len == 0 || len >= sizeof(buf)) {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(*sp);
        return data;
    }
    data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(buf);
    return data;
#else
    char* resolved = realpath(sp->c_str(), nullptr);
    if (!resolved) {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string(*sp);
        return data;
    }
    data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(resolved);
    free(resolved);
    return data;
#endif
}

extern "C" void* ring_path_dirname(void* p) {
    std::string* sp = (std::string*)p;
    size_t pos = sp->find_last_of("/\\");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (pos == std::string::npos) {
        new (data) std::string(".");
    } else {
        new (data) std::string(sp->substr(0, pos));
    }
    return data;
}

extern "C" void* ring_path_basename(void* p) {
    std::string* sp = (std::string*)p;
    size_t pos = sp->find_last_of("/\\");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (pos == std::string::npos) {
        new (data) std::string(*sp);
    } else {
        new (data) std::string(sp->substr(pos + 1));
    }
    return data;
}

extern "C" void* ring_path_extname(void* p) {
    std::string* sp = (std::string*)p;
    size_t slash = sp->find_last_of("/\\");
    size_t dot = sp->rfind('.');
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) {
        new (data) std::string("");
    } else {
        new (data) std::string(sp->substr(dot));
    }
    return data;
}

// ============================================================================
// File operations (additional)
// ============================================================================

extern "C" void* ring_file_exists(void* path) {
    std::string* p = (std::string*)path;
#ifdef _WIN32
    int64_t exists = _access(p->c_str(), 0) == 0 ? 1 : 0;
#else
    int64_t exists = access(p->c_str(), F_OK) == 0 ? 1 : 0;
#endif
    return ring_box_bool(exists);
}

extern "C" void* ring_delete_file(void* path) {
    std::string* p = (std::string*)path;
    remove(p->c_str());
    return nullptr;
}

// ============================================================================
// Collection clone / from
// ============================================================================

extern "C" void* ring_list_clone(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    new (data) std::vector<void*>(*vec);
    return data;
}

extern "C" void* ring_map_clone(void* map) {
    RingMap* m = (RingMap*)map;
    void* data = ring_alloc(sizeof(RingMap), RING_TYPEID_MAP);
    new (data) RingMap(*m);
    return data;
}

extern "C" void* ring_set_clone(void* set) {
    RingSet* s = (RingSet*)set;
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    new (data) RingSet(*s);
    return data;
}

extern "C" void* ring_map_from(void* entries) {
    // entries is List<(K, V)> = List<List<void*>> where each inner list is [key, value]
    auto* vec = (std::vector<void*>*)entries;
    void* data = ring_alloc(sizeof(RingMap), RING_TYPEID_MAP);
    auto* result = new (data) RingMap();
    for (size_t i = 0; i < vec->size(); i++) {
        auto* pair = (std::vector<void*>*)((*vec)[i]);
        if (pair->size() >= 2) {
            std::string* key = (std::string*)((*pair)[0]);
            (*result)[*key] = (*pair)[1];
        }
    }
    return data;
}

// ring_set_from_list already defined above

// ============================================================================
// String operations (additional)
// ============================================================================

extern "C" void* ring_str_trim(void* s) {
    std::string* str = (std::string*)s;
    size_t start = str->find_first_not_of(" \t\n\r\f\v");
    size_t end = str->find_last_not_of(" \t\n\r\f\v");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (start == std::string::npos) {
        new (data) std::string("");
    } else {
        new (data) std::string(str->substr(start, end - start + 1));
    }
    return data;
}

extern "C" void* ring_str_trim_start(void* s) {
    std::string* str = (std::string*)s;
    size_t start = str->find_first_not_of(" \t\n\r\f\v");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (start == std::string::npos) {
        new (data) std::string("");
    } else {
        new (data) std::string(str->substr(start));
    }
    return data;
}

extern "C" void* ring_str_trim_end(void* s) {
    std::string* str = (std::string*)s;
    size_t end = str->find_last_not_of(" \t\n\r\f\v");
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if (end == std::string::npos) {
        new (data) std::string("");
    } else {
        new (data) std::string(str->substr(0, end + 1));
    }
    return data;
}

extern "C" void* ring_str_to_upper(void* s) {
    std::string result = *(std::string*)s;
    for (size_t i = 0; i < result.size(); i++) {
        result[i] = (char)toupper((unsigned char)result[i]);
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(result);
    return data;
}

extern "C" void* ring_str_to_lower(void* s) {
    std::string result = *(std::string*)s;
    for (size_t i = 0; i < result.size(); i++) {
        result[i] = (char)tolower((unsigned char)result[i]);
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(result);
    return data;
}

extern "C" void* ring_str_char_at(void* s, int64_t idx) {
    std::string* str = (std::string*)s;
    if (idx < 0 || idx >= (int64_t)str->size()) {
        return ring_enum_none();
    }
    void* sd = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (sd) std::string(1, (*str)[(size_t)idx]);
    return ring_enum_some(sd);
}

extern "C" void* ring_str_index_of(void* s, void* sub) {
    std::string* str = (std::string*)s;
    std::string* needle = (std::string*)sub;
    size_t pos = str->find(*needle);
    if (pos == std::string::npos) {
        return ring_enum_none();
    }
    return ring_enum_some(ring_box_int((int64_t)pos));
}

extern "C" void* ring_str_last_index_of(void* s, void* sub) {
    std::string* str = (std::string*)s;
    std::string* needle = (std::string*)sub;
    size_t pos = str->rfind(*needle);
    if (pos == std::string::npos) {
        return ring_enum_none();
    }
    return ring_enum_some(ring_box_int((int64_t)pos));
}

extern "C" int64_t ring_str_is_empty(void* s) {
    return ((std::string*)s)->empty() ? 1 : 0;
}

extern "C" void* ring_str_pad_start(void* s, int64_t length, void* fill) {
    std::string* str = (std::string*)s;
    std::string* filler = (std::string*)fill;
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if ((int64_t)str->size() >= length || filler->empty()) {
        new (data) std::string(*str);
        return data;
    }
    std::string result;
    while ((int64_t)(result.size() + str->size()) < length) {
        result += *filler;
    }
    result = result.substr(0, (size_t)(length - (int64_t)str->size()));
    result += *str;
    new (data) std::string(result);
    return data;
}

extern "C" void* ring_str_pad_end(void* s, int64_t length, void* fill) {
    std::string* str = (std::string*)s;
    std::string* filler = (std::string*)fill;
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    if ((int64_t)str->size() >= length || filler->empty()) {
        new (data) std::string(*str);
        return data;
    }
    std::string result = *str;
    while ((int64_t)result.size() < length) {
        result += *filler;
    }
    new (data) std::string(result.substr(0, (size_t)length));
    return data;
}

extern "C" void* ring_str_repeat(void* s, int64_t count) {
    std::string* str = (std::string*)s;
    std::string result;
    for (int64_t i = 0; i < count; i++) {
        result += *str;
    }
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(result);
    return data;
}

extern "C" void* ring_str_char_code_at(void* s, int64_t idx) {
    CHK("str_char_code_at");
    std::string* str = (std::string*)s;
    if (idx < 0 || idx >= (int64_t)str->size()) {
        return ring_enum_none();
    }
    return ring_enum_some(ring_box_int((int64_t)(unsigned char)(*str)[(size_t)idx]));
}

// ============================================================================
// StringBuilder (additional)
// ============================================================================

extern "C" void* ring_sb_line(void* sb, void* s) {
    *(std::string*)sb += *(std::string*)s;
    *(std::string*)sb += "\n";
    return sb;
}

extern "C" void* ring_sb_add_int(void* sb, int64_t n) {
    *(std::string*)sb += std::to_string(n);
    return sb;
}

// ============================================================================
// Parse functions
// ============================================================================

extern "C" void* ring_parse_int(void* s) {
    std::string* str = (std::string*)s;
    try {
        size_t pos;
        int64_t val = std::stoll(*str, &pos);
        if (pos == str->size()) {
            return ring_enum_some(ring_box_int(val));
        }
    } catch (...) {}
    return ring_enum_none();
}

extern "C" void* ring_parse_float(void* s) {
    std::string* str = (std::string*)s;
    try {
        size_t pos;
        double val = std::stod(*str, &pos);
        if (pos == str->size()) {
            return ring_enum_some(ring_box_float(val));
        }
    } catch (...) {}
    return ring_enum_none();
}

// ============================================================================
// Set operations (additional)
// ============================================================================

extern "C" void* ring_set_union(void* a, void* b) {
    RingSet* sa = (RingSet*)a;
    RingSet* sb = (RingSet*)b;
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    auto* result = new (data) RingSet(*sa);
    for (auto& elem : *sb) {
        result->insert(elem);
    }
    return data;
}

extern "C" void* ring_set_intersect(void* a, void* b) {
    RingSet* sa = (RingSet*)a;
    RingSet* sb = (RingSet*)b;
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    auto* result = new (data) RingSet();
    for (auto& elem : *sa) {
        if (sb->count(elem) > 0) {
            result->insert(elem);
        }
    }
    return data;
}

extern "C" void* ring_set_difference(void* a, void* b) {
    RingSet* sa = (RingSet*)a;
    RingSet* sb = (RingSet*)b;
    void* data = ring_alloc(sizeof(RingSet), RING_TYPEID_SET);
    auto* result = new (data) RingSet();
    for (auto& elem : *sa) {
        if (sb->count(elem) == 0) {
            result->insert(elem);
        }
    }
    return data;
}

// ============================================================================
// List operations (additional)
// ============================================================================

extern "C" void* ring_list_shift(void* list) {
    auto* vec = (std::vector<void*>*)list;
    if (vec->empty()) {
        return ring_enum_none();
    }
    void* val = vec->front();
    vec->erase(vec->begin());
    return ring_enum_some(val);
}

extern "C" void* ring_list_clear(void* list) {
    ((std::vector<void*>*)list)->clear();
    return list;
}

extern "C" void* ring_list_extend(void* list, void* other) {
    auto* va = (std::vector<void*>*)list;
    auto* vb = (std::vector<void*>*)other;
    va->insert(va->end(), vb->begin(), vb->end());
    return list;
}

// ============================================================================
// Map operations (additional)
// ============================================================================

extern "C" void* ring_map_clear(void* map) {
    ((RingMap*)map)->clear();
    return map;
}

// ============================================================================
// Set operations (additional clear/remove)
// ============================================================================

extern "C" void* ring_set_clear(void* set) {
    ((RingSet*)set)->clear();
    return set;
}

// ============================================================================
// Miscellaneous
// ============================================================================

extern "C" void* ring_assert(int64_t cond, void* msg) {
    if (!cond) {
        fprintf(stderr, "ring assertion failed: %s\n", ((std::string*)msg)->c_str());
        fflush(stderr);
        exit(1);
    }
    return nullptr;
}

// JSON-stringify a value. The bootstrap compiler only ever calls this on Str
// (to emit JS string literals), so the value is treated as a std::string and
// rendered as a quoted, escaped JSON string. (General <T> serialization would
// require runtime type tags, which the uniform-boxing runtime does not carry.)
extern "C" void* ring_json_stringify(void* val) {
    void* data;
    if (!val) {
        data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
        new (data) std::string("null");
        return data;
    }
    std::string* s = (std::string*)val;
    std::string out = "\"";
    for (unsigned char c : *s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    out += "\"";
    data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    new (data) std::string(out);
    return data;
}

// ============================================================================
// Builtin primitive trait dictionaries (Eq for Str/Int/Float/Bool).
// The bootstrap LLVM backend does not emit Ring impls for primitive Eq, so a
// generic `x == item` (which dispatches through an Eq dict) needs a real dict.
// Each dict is { eq_closure, ne_closure, null, null }; each closure is
// { fn_ptr, null_env }; the closure ABI is fn(env, a, b) -> boxed value.
// ============================================================================

extern "C" void* ring_cl_eq_str(void* env, void* a, void* b) { return ring_box_bool(ring_str_eq(a, b)); }
extern "C" void* ring_cl_ne_str(void* env, void* a, void* b) { return ring_box_bool(ring_str_eq(a, b) ? 0 : 1); }
extern "C" void* ring_cl_eq_int(void* env, void* a, void* b) { return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 1 : 0); }
extern "C" void* ring_cl_ne_int(void* env, void* a, void* b) { return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 0 : 1); }
extern "C" void* ring_cl_eq_float(void* env, void* a, void* b) { return ring_box_bool((*(double*)a == *(double*)b) ? 1 : 0); }
extern "C" void* ring_cl_ne_float(void* env, void* a, void* b) { return ring_box_bool((*(double*)a == *(double*)b) ? 0 : 1); }
extern "C" void* ring_cl_eq_bool(void* env, void* a, void* b) { return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 1 : 0); }
extern "C" void* ring_cl_ne_bool(void* env, void* a, void* b) { return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 0 : 1); }
// Tag comparison for enum Eq dicts (correct for field-less enum variants, which
// is what the bootstrap compiler compares with `==`). Reads the leading i64 tag.
extern "C" void* ring_cl_eq_tag(void* env, void* a, void* b) {
    if (!a || !b) return ring_box_bool((a == b) ? 1 : 0);
    return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 1 : 0);
}
extern "C" void* ring_cl_ne_tag(void* env, void* a, void* b) {
    if (!a || !b) return ring_box_bool((a == b) ? 0 : 1);
    return ring_box_bool((*(int64_t*)a == *(int64_t*)b) ? 0 : 1);
}

// Ord cmp closures: return a boxed Int in {-1, 0, 1}. The Ord trait has a single
// method `cmp` at dict slot 0; the LLVM backend lowers a generic `a < b` / `a > b`
// to load_dict_method(dict, 0) + compare the unboxed result against 0. The same
// closure ABI as Eq: fn(env, a, b) -> boxed value.
extern "C" void* ring_cl_cmp_int(void* env, void* a, void* b) {
    int64_t x = *(int64_t*)a, y = *(int64_t*)b;
    return ring_box_int(x < y ? -1 : (x > y ? 1 : 0));
}
extern "C" void* ring_cl_cmp_float(void* env, void* a, void* b) {
    double x = *(double*)a, y = *(double*)b;
    return ring_box_int(x < y ? -1 : (x > y ? 1 : 0));
}
extern "C" void* ring_cl_cmp_str(void* env, void* a, void* b) {
    const std::string& x = *(std::string*)a;
    const std::string& y = *(std::string*)b;
    return ring_box_int(x < y ? -1 : (x > y ? 1 : 0));
}
extern "C" void* ring_cl_cmp_bool(void* env, void* a, void* b) {
    int64_t x = *(int64_t*)a, y = *(int64_t*)b;
    return ring_box_int(x < y ? -1 : (x > y ? 1 : 0));
}

static void* ring_make_closure(void* fn) {
    void* data = ring_alloc(2 * sizeof(void*), RING_TYPEID_CLOSURE);
    void** c = (void**)data;
    c[0] = fn; c[1] = nullptr;
    return data;
}
static void* ring_make_eq_dict(void* eqfn, void* nefn) {
    // Dict struct is 4 void* slots: [eq_closure, ne_closure, null, null]
    // Treated as TUPLE for RC purposes (fields are ring_alloc'd closures).
    void* data = ring_alloc(4 * sizeof(void*), RING_TYPEID_TUPLE);
    void** d = (void**)data;
    d[0] = ring_make_closure(eqfn);
    d[1] = ring_make_closure(nefn);
    d[2] = nullptr; d[3] = nullptr;
    return data;
}
static void* ring_make_ord_dict(void* cmpfn) {
    // Ord dict: 4 void* slots with the single `cmp` closure at slot 0 (matching
    // the trait's method order). Same TUPLE layout/RC handling as the Eq dict.
    void* data = ring_alloc(4 * sizeof(void*), RING_TYPEID_TUPLE);
    void** d = (void**)data;
    d[0] = ring_make_closure(cmpfn);
    d[1] = nullptr; d[2] = nullptr; d[3] = nullptr;
    return data;
}

// ============================================================================
// Perceus RC L0 — container drop functions
// ============================================================================

static void drop_list(void* data) {
    auto* v = (std::vector<void*>*)data;
    for (void* elem : *v) {
        ring_drop(elem);
    }
    v->~vector();
}

static void drop_map(void* data) {
    auto* m = (RingMap*)data;
    // Str keys are std::string (value type, not pointer), destructor handles them.
    // Values are void* pointing to Ring heap objects, need ring_drop.
    for (auto& kv : *m) {
        ring_drop(kv.second);
    }
    m->~unordered_map();
}

static void drop_map_int(void* data) {
    auto* m = (RingMapInt*)data;
    for (auto& kv : *m) {
        ring_drop(kv.second);
    }
    m->~unordered_map();
}

static void drop_set(void* data) {
    // Set<Str> — std::unordered_set<std::string>, elements are value types.
    // Destructor auto-releases, no recursive ring_drop needed.
    ((RingSet*)data)->~unordered_set();
}

static void drop_set_int(void* data) {
    ((RingSetInt*)data)->~unordered_set();
}

static void drop_closure(void* data) {
    // RingClosure = { fn_ptr: void*, env_ptr: void* }
    // fn_ptr is a function pointer, don't drop.
    // env_ptr if non-null is a ring_alloc'd env struct, needs ring_drop.
    // The env carries its own typeid (RING_TYPEID_CLOSURE_ENV for gen_lambda
    // closures → drop_closure_env; RING_TYPEID_CLOSURE for catch/handle envs,
    // which ring_try leaks and never drops), so ring_drop dispatches correctly.
    void** cls = (void**)data;
    if (cls[1]) {  // env_ptr
        ring_drop(cls[1]);
    }
}

static void drop_closure_env(void* data) {
    // Closure env struct (B-084): { int64 count, void* cap0, void* cap1, ... }.
    // gen_lambda gives every general-purpose closure env this dedicated typeid
    // (NOT RING_TYPEID_CLOSURE, which drop_closure mis-reads as a {fn,env} pair).
    // Each captured slot holds an OWNED RC reference — Perceus emits a ring_dup at
    // capture (non-last-use) or moves the sole owned ref in (last-use), so the
    // enclosing scope does not also drop it.  Releasing the env therefore drops
    // every slot exactly once: ring_drop dispatches on each slot's own typeid, so
    // mut-cells (RING_TYPEID_CELL, B-091) and plain owned heap values are handled
    // uniformly and stay RC-balanced (no double-free, no leak).
    int64_t count = *(int64_t*)data;
    void** slots = (void**)((char*)data + 8);
    for (int64_t i = 0; i < count; i++) {
        if (slots[i]) ring_drop(slots[i]);
    }
}

static void drop_option(void* data) {
    // Option = { tag: i64, payload: void* }
    // tag==0 => Some(payload), tag==1 => None
    int64_t tag = *(int64_t*)data;
    if (tag == 0) {
        void* payload = *(void**)((int64_t*)data + 1);
        if (payload) ring_drop(payload);
    }
}

static void drop_tuple(void* data) {
    // Tuple/struct fields are contiguous void* pointers.
    // L0 simplification: tuple drop handled by codegen-generated per-type drop_T.
    // Runtime fallback is a no-op.
    (void)data;
}

static void drop_sb(void* data) {
    // StringBuilder is just a std::string underneath.
    ((std::string*)data)->~basic_string();
}

extern "C" void* ring_get_builtin_dict(void* name_ptr) {
    if (!name_ptr) return nullptr;
    std::string& n = *(std::string*)name_ptr;
    // Ord dicts (single `cmp` method). Check before Eq: an Ord dict name never
    // contains "Eq", but keeping it first keeps the intent explicit.
    if (n.find("Ord") != std::string::npos) {
        if (n.find("Str") != std::string::npos)   return ring_make_ord_dict((void*)ring_cl_cmp_str);
        if (n.find("Float") != std::string::npos) return ring_make_ord_dict((void*)ring_cl_cmp_float);
        if (n.find("Int") != std::string::npos)   return ring_make_ord_dict((void*)ring_cl_cmp_int);
        if (n.find("Bool") != std::string::npos)  return ring_make_ord_dict((void*)ring_cl_cmp_bool);
        fprintf(stderr, "ring: no builtin Ord dict for '%s'\n", n.c_str());
        fflush(stderr);
        return nullptr;
    }
    // Eq dicts (eq/ne).
    if (n.find("Eq") != std::string::npos) {
        if (n.find("Str") != std::string::npos)   return ring_make_eq_dict((void*)ring_cl_eq_str,   (void*)ring_cl_ne_str);
        if (n.find("Float") != std::string::npos) return ring_make_eq_dict((void*)ring_cl_eq_float, (void*)ring_cl_ne_float);
        if (n.find("Int") != std::string::npos)   return ring_make_eq_dict((void*)ring_cl_eq_int,   (void*)ring_cl_ne_int);
        if (n.find("Bool") != std::string::npos)  return ring_make_eq_dict((void*)ring_cl_eq_bool,  (void*)ring_cl_ne_bool);
        // Any other Eq dict (user enums) → tag comparison.
        return ring_make_eq_dict((void*)ring_cl_eq_tag, (void*)ring_cl_ne_tag);
    }
    fprintf(stderr, "ring: no builtin dict for '%s'\n", n.c_str());
    fflush(stderr);
    return nullptr;
}

// ============================================================================
// List operations (join already defined as ring_list_join)
// ============================================================================

extern "C" void* ring_list_join(void* list, void* sep) {
    auto* vec = (std::vector<void*>*)list;
    std::string* separator = (std::string*)sep;
    void* data = ring_alloc(sizeof(std::string), RING_TYPEID_STR);
    auto* result = new (data) std::string();
    for (size_t i = 0; i < vec->size(); i++) {
        if (i > 0) *result += *separator;
        *result += *(std::string*)((*vec)[i]);
    }
    return data;
}
