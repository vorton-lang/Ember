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

// B-101 never-drop (interned / arena) typeids — RETIRED by B-102 R-clean
// (2026-06-07).  The compiler's `Type` DAG now participates in ordinary Perceus
// RC: the codegen no longer registers any typeid as never-drop, so this table
// stays all-false and the dup/drop guards below are inert.  The mechanism
// (ring_register_never_drop + this table + the two guard checks) is kept as a
// cheap, currently-unused hook should an arena/interned value class be wanted
// later; with no registrations it has zero effect.  The original A1 over-free
// (shallow ring_dup vs deep recursive drop_Type on aliased substructure) is now
// fixed at the source: perceus Clone-wraps every escaping shared Type
// substructure, balancing the recursive drop (design §7.11 "pure Perceus RC").
static bool never_drop_table[4096];

// Forward declarations for RC infrastructure
static void ring_drop_by_typeid(uint32_t tid, void* data);

// ============================================================================
// Perceus RC L0 — ring_alloc / ring_dup / ring_drop
// ============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// B-080 P0 — boxed-INT call-site attribution (opt-in, -DRING_BOX_PROFILE).
// g_live_tid (below) says HOW MANY INT boxes are live; this says WHERE they were
// born.  Samples 1/RING_BOX_PROFILE_SAMPLE box_int allocations into a side table
// keyed by the IR return address, erases on free, and at report time aggregates
// the still-live samples by call site.  Decides whether residual INT is boundary
// boxing (List<Int>/Option<Int>/dict/tuple/variant slots — spread across many
// sites) vs a specific RC gap (one site dominates), and confirms no non-scalar
// typeid is masked.  Prints RVA (= RA - image base) so a linker .map symbolizes
// the sites.  Throwaway diagnostic; inert without the flag.  Build the diagnostic
// run with BOTH -DRING_ALLOC_STATS -DRING_BOX_PROFILE.
// ─────────────────────────────────────────────────────────────────────────────
#ifdef RING_BOX_PROFILE
#ifndef RING_BOX_PROFILE_SAMPLE
#define RING_BOX_PROFILE_SAMPLE 64   // must be a power of two
#endif
// B-109: extended to per-typeid attribution.  INT recorded at ring_box_int (RA = IR
// site), OPTION at ring_enum_some (RA = IR site), STR at ring_alloc (RA = the runtime
// string helper that allocated it — concat / interp / int_to_str / literal, a
// coarser but still useful "which string op leaks" signal).  Report splits by typeid.
struct RingBoxRec { void* ra; uint32_t tid; };
static std::unordered_map<void*, RingBoxRec>* g_box_live = nullptr; // live ptr -> (RA, typeid)
static std::unordered_map<void*, uint64_t>*   g_box_born = nullptr; // RA -> cumulative sampled births
static uint64_t g_box_seq = 0;
static uintptr_t ring_image_base() {
#ifdef _WIN32
    static uintptr_t base = (uintptr_t)GetModuleHandleW(NULL);
    return base;
#else
    return 0;
#endif
}
static const char* ring_tid_name(uint32_t tid) {
    switch (tid) {
        case 0:  return "INT";    case 2:  return "BOOL";   case 3:  return "STR";
        case 7:  return "CLOSURE"; case 8: return "OPTION"; case 10: return "TUPLE";
        default: return "?";
    }
}
static void ring_box_profile_record(void* ptr, void* ra, uint32_t tid) {
    if (!g_box_live) {
        g_box_live = new std::unordered_map<void*, RingBoxRec>();
        g_box_born = new std::unordered_map<void*, uint64_t>();
    }
    if ((g_box_seq++ & (RING_BOX_PROFILE_SAMPLE - 1)) != 0) return; // sample 1/N
    (*g_box_live)[ptr] = RingBoxRec{ ra, tid };
    (*g_box_born)[ra]++;
}
static void ring_box_profile_erase(void* ptr) {
    if (g_box_live) g_box_live->erase(ptr);
}
static void ring_box_profile_report() {
    if (!g_box_live) return;
    uintptr_t base = ring_image_base();
    // aggregate live samples by (typeid, RA)
    std::unordered_map<uint32_t, std::unordered_map<void*, uint64_t>> per; // tid -> ra -> live
    std::unordered_map<uint32_t, uint64_t> tid_total;
    for (auto& kv : *g_box_live) { per[kv.second.tid][kv.second.ra]++; tid_total[kv.second.tid]++; }
    for (auto& tp : per) {
        uint32_t tid = tp.first;
        std::vector<std::pair<void*, uint64_t>> v(tp.second.begin(), tp.second.end());
        std::sort(v.begin(), v.end(),
            [](const std::pair<void*,uint64_t>& a, const std::pair<void*,uint64_t>& b){ return a.second > b.second; });
        fprintf(stderr, "[box-profile] %s live sites: %zu distinct, %llu samples (x%d = ~%llu boxes), top:\n",
                ring_tid_name(tid), v.size(), (unsigned long long)tid_total[tid], RING_BOX_PROFILE_SAMPLE,
                (unsigned long long)tid_total[tid] * RING_BOX_PROFILE_SAMPLE);
        int n = (int)v.size(); if (n > 12) n = 12;
        for (int i = 0; i < n; i++) {
            void* ra = v[i].first;
            uint64_t born = (*g_box_born)[ra];
            fprintf(stderr, "  [%s] rva=0x%llx live=%llu born=%llu (RA=%p)\n",
                    ring_tid_name(tid), (unsigned long long)((uintptr_t)ra - base),
                    (unsigned long long)v[i].second, (unsigned long long)born, ra);
        }
    }
    fflush(stderr);
}
#if !defined(RING_ALLOC_STATS)
static bool g_box_atexit = (atexit(ring_box_profile_report), true);
#endif
#endif // RING_BOX_PROFILE

// ─────────────────────────────────────────────────────────────────────────────
// Alloc/free leak counter (opt-in diagnostic, -DRING_ALLOC_STATS).  Inert in
// normal builds.  Tracks `live = allocs - frees` overall and per-typeid; a leaking
// program has live ≈ allocs (1:1, never plateaus), a reclaiming one has live
// plateau (frees keep pace).  Periodic stderr reports (every ~32M allocs) + atexit
// give a leak% trajectory even when a self-compile is memory-capped before exit.
// typeid quick-ref: 0=INT 2=BOOL 3=STR 4=LIST 7=CLOSURE 8=OPTION 10=TUPLE 64+=user.
// Used to attribute the G-a memory wall (B-104): the precise-Perceus waves drive
// the leak% down by dropping owned temporaries that clone-all-escape leaves alive.
// ─────────────────────────────────────────────────────────────────────────────
#ifdef RING_ALLOC_STATS
static uint64_t g_allocs = 0;
static uint64_t g_frees  = 0;
static int64_t  g_live_tid[4096] = {0};
static uint64_t g_next_report = (1ULL << 25); // first report at 32M allocs
static void ring_alloc_stats_report() {
    uint64_t live = g_allocs - g_frees;
    double pct = g_allocs ? (100.0 * (double)live / (double)g_allocs) : 0.0;
    // top-6 live typeids
    int top[6]; for (int i = 0; i < 6; i++) top[i] = -1;
    for (int t = 0; t < 4096; t++) {
        if (g_live_tid[t] <= 0) continue;
        for (int s = 0; s < 6; s++) {
            if (top[s] < 0 || g_live_tid[t] > g_live_tid[top[s]]) {
                for (int k = 5; k > s; k--) top[k] = top[k-1];
                top[s] = t; break;
            }
        }
    }
    fprintf(stderr, "[alloc-stats] allocs=%llu frees=%llu live=%llu (%.1f%% leak) | top:",
            (unsigned long long)g_allocs, (unsigned long long)g_frees,
            (unsigned long long)live, pct);
    for (int s = 0; s < 6; s++) {
        if (top[s] >= 0) fprintf(stderr, " tid%d=%lld", top[s], (long long)g_live_tid[top[s]]);
    }
    fprintf(stderr, "\n"); fflush(stderr);
#ifdef RING_BOX_PROFILE
    ring_box_profile_report();
#endif
}
static bool g_stats_atexit = (atexit(ring_alloc_stats_report), true);
#endif

extern "C" void* ring_alloc(int64_t size, int64_t typeid_val) {
    char* raw = (char*)malloc(8 + (size_t)size);
    if (!raw) {
        fprintf(stderr, "ring panic: ring_alloc failed (size=%lld, typeid=%lld)\n",
                (long long)size, (long long)typeid_val);
        exit(1);
    }
    *(uint32_t*)(raw)     = 1;                    // rc = 1 (new allocation)
    *(uint32_t*)(raw + 4) = (uint32_t)typeid_val; // typeid
#ifdef RING_ALLOC_STATS
    g_allocs++;
    if (typeid_val >= 0 && typeid_val < 4096) g_live_tid[typeid_val]++;
    if (g_allocs >= g_next_report) { ring_alloc_stats_report(); g_next_report += (1ULL << 25); }
#endif
#ifdef RING_BOX_PROFILE
    // STR is allocated inside many runtime string helpers (concat / interp / int_to_str
    // / literal), not directly from IR — record here so RA attributes the leak to the
    // string op.  INT/OPTION are recorded at their own constructors (IR-site RA).
    if (typeid_val == RING_TYPEID_STR) ring_box_profile_record(raw + 8, _ReturnAddress(), RING_TYPEID_STR);
#endif
    return raw + 8;                               // return data pointer
}

extern "C" void ring_dup(void* ptr) {
    if (!ptr) return;
    uint32_t tid = *(uint32_t*)((char*)ptr - 4);
    if (tid < 4096 && never_drop_table[tid]) return; // B-101: interned, no RC
    uint32_t* rc = (uint32_t*)((char*)ptr - 8);
    *rc += 1;
}

extern "C" void ring_drop(void* ptr) {
    if (!ptr) return;
    uint32_t tid = *(uint32_t*)((char*)ptr - 4);
#ifdef RING_RC_DEBUG
    {
        uint32_t rcv = *(uint32_t*)((char*)ptr - 8);
        if (tid >= 4096u || rcv == 0u || rcv > 1000000u) {
            fprintf(stderr, "[rc-debug] suspicious ring_drop ptr=%p tid=%u rc=%u ra=%p\n",
                    ptr, tid, rcv, _ReturnAddress());
            fflush(stderr);
        }
    }
#endif
    if (tid < 4096 && never_drop_table[tid]) return; // B-101: interned, never freed
    uint32_t* rc = (uint32_t*)((char*)ptr - 8);
    if (*rc <= 1) {
        ring_drop_by_typeid(tid, ptr);
#ifdef RING_BOX_PROFILE
        if (tid == RING_TYPEID_INT || tid == RING_TYPEID_STR || tid == RING_TYPEID_OPTION) ring_box_profile_erase(ptr);
#endif
        free((char*)ptr - 8);
#ifdef RING_ALLOC_STATS
        g_frees++;
        if (tid < 4096) g_live_tid[tid]--;
#endif
    } else {
        *rc -= 1;
    }
}

extern "C" void ring_register_drop(int64_t typeid_val, void* drop_fn_ptr) {
    if (typeid_val >= 0 && typeid_val < 4096) {
        drop_table[(int)typeid_val] = (ring_drop_fn)drop_fn_ptr;
    }
}

// B-101 — mark a typeid as never-drop (interned / arena lifetime).  ring_dup and
// ring_drop become no-ops for such blocks; they live until process exit.  Used for
// the compiler's immutable shared `Type` DAG (see never_drop_table above).
extern "C" void ring_register_never_drop(int64_t typeid_val) {
    if (typeid_val >= 0 && typeid_val < 4096) {
        never_drop_table[(int)typeid_val] = true;
    }
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

// CHK / CHK_ARG were a lightweight per-call crash-context tracer used during the
// #134 native RC double-free hunt (B-098).  The hunt is closed; they are now
// no-ops (left at call sites so the diagnostic can be re-enabled in one place if
// ever needed).  Normal null / bounds / key-not-found panics remain (below).
#define CHK(name) do { } while(0)
#define CHK_ARG(name, arg) do { } while(0)

extern "C" void ring_runtime_init(int argc, char** argv) {
    g_argc = argc;
    g_argv = argv;

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
#ifdef RING_BOX_PROFILE
    ring_box_profile_record(data, _ReturnAddress(), RING_TYPEID_INT);
#endif
    return data;
}

extern "C" int64_t ring_unbox_int(void* p) {
    CHK("unbox_int");
    if (!p) { fprintf(stderr, "ring panic: unbox_int(null)\n"); exit(1); }
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
    if (!p) { fprintf(stderr, "ring panic: unbox_bool(null)\n"); exit(1); }
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
    // B-098: a list element read is a BORROW — return the element WITHOUT
    // bumping its refcount (it still belongs to the list).  The borrow-inference
    // pass clones (ring_dup) it only when it escapes into an owned sink.
    void* elem = (*vec)[(size_t)idx];
    return elem;
}

extern "C" void* ring_list_set(void* list, int64_t idx, void* val) {
    auto* vec = (std::vector<void*>*)list;
    if (idx < 0 || idx >= (int64_t)vec->size()) {
        fprintf(stderr, "ring panic: list index %lld out of bounds (len %lld)\n",
                (long long)idx, (long long)vec->size());
        exit(1);
    }
    // B-104 D1 rule ④ — overwrite must DROP the old element.  Insert side: the
    // value arg is a sink position (perceus sink_arg_indices ".set" → borrows are
    // escape-Cloned, fresh temps transfer ownership), so the list owns +1 per slot
    // — exactly the account drop_list settles at end-of-life.  Overwriting without
    // a drop leaked that +1 (unbounded for hot slots).  Store first, THEN drop:
    // a self-assign `xs.set(i, xs[i])` arrives with its own call-site dup (rc ≥ 2)
    // and external sharers (`let saved = xs[i]` escape-Clone) hold their own +1,
    // so the drop only decrements for them; an unshared old value (rc=1) is freed
    // — the reclaimed leak.
    void* old = (*vec)[(size_t)idx];
    (*vec)[(size_t)idx] = val;
    ring_drop(old);
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
    // B-103: the fresh list co-owns elements still owned by `a` and `b` — dup each
    // (owned-container-constructor rule, design §7.11; same class as ring_list_clone).
    // Without this, dropping both the concat result and a source deep-drops the
    // same elements → double-free (latent while the leak régime never dropped the
    // sources; detonates under is_droppable_init(Call)=true / the D1 total pass).
    for (void* el : *result) ring_dup(el);
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
    auto* result = new (data) std::vector<void*>(vec->begin() + start, vec->begin() + end);
    // B-103: dup the copied range — the fresh slice co-owns elements still owned
    // by the source list (owned-container-constructor rule; see ring_list_concat).
    for (void* el : *result) ring_dup(el);
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
    // B-098: `.get()` builds a FRESH owned Option (ring_enum_some) that co-owns
    // the element — same owned-container-constructor rule as map_values: dup the
    // element so drop_option (which drops the payload) is balanced.  (The DIRECT
    // element reads — ring_list_get / map_get / IndexExpr — return a borrow and
    // are the ones whose always-own dup is reverted.)
    void* elem = (*vec)[(size_t)idx];
    ring_dup(elem);
    return ring_enum_some(elem);
}

extern "C" void* ring_list_reverse(void* list) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>(vec->rbegin(), vec->rend());
    // B-103: dup — the fresh reversed list co-owns the source's elements
    // (owned-container-constructor rule; see ring_list_concat).
    for (void* el : *result) ring_dup(el);
    return data;
}

extern "C" void* ring_list_sort(void* list, void* closure) {
    auto* vec = (std::vector<void*>*)list;
    void* data = ring_alloc(sizeof(std::vector<void*>), RING_TYPEID_LIST);
    auto* result = new (data) std::vector<void*>(*vec);
    // B-103: dup — the fresh sorted list co-owns the source's elements
    // (owned-container-constructor rule; see ring_list_concat).
    for (void* el : *result) ring_dup(el);
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
#ifdef RING_BOX_PROFILE
    ring_box_profile_record(data, _ReturnAddress(), RING_TYPEID_OPTION);
#endif
    return data;
}

static void* ring_enum_none() {
    void* data = ring_alloc(sizeof(int64_t) * 2, RING_TYPEID_OPTION);
    ((int64_t*)data)[0] = 1;
    ((int64_t*)data)[1] = 0;
#ifdef RING_BOX_PROFILE
    ring_box_profile_record(data, _ReturnAddress(), RING_TYPEID_OPTION);
#endif
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
    // B-103: dup — the fresh sorted list co-owns the source's elements
    // (owned-container-constructor rule; see ring_list_concat).
    for (void* el : *result) ring_dup(el);
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
            // B-103: .find builds a FRESH owned Option that co-owns the matched
            // element (same owned-container-constructor rule as ring_list_get_opt /
            // first / last — dup the element so drop_option is balanced).  Was a
            // latent un-dup'd borrow: `let f = xs.find(p)` is now droppable
            // (is_droppable_init(Call)=true), so without this dup, scope-end-dropping
            // the Option frees the list's element → UAF (native self-compile
            // over-free in infer_field_access: struct_def.fields.find(...) freeing a
            // registered StructField).
            void* elem = (*vec)[i];
            ring_dup(elem);
            return ring_enum_some(elem);
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
            // B-103: dup — the fresh filtered list co-owns the source's element
            // (owned-container-constructor rule; see ring_list_concat).
            ring_dup((*vec)[i]);
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
    // B-103: like ring_list_get_opt, .last() builds a FRESH owned Option that
    // co-owns the element (the Ring-source `self.get(self.len()-1)` goes through
    // ring_list_get_opt, which dups).  The LLVM backend shortcuts `.last` straight
    // to this runtime fn (codegen_llvm_expr.ring), so it must dup the element too —
    // otherwise the returned Option's payload aliases the container element and
    // scope-end-dropping the Option (now droppable: is_droppable_init(Call)=true)
    // double-frees it.  Owned-container-constructor rule (design §7.11): dup on
    // co-own, balanced by drop_option.
    void* elem = vec->back();
    ring_dup(elem);
    return ring_enum_some(elem);
}

extern "C" void* ring_list_first(void* list) {
    auto* vec = (std::vector<void*>*)list;
    if (vec->empty()) {
        return ring_enum_none();
    }
    // B-103: see ring_list_last — fresh owned Option co-owns the element (dup),
    // matching ring_list_get_opt and the Ring-source `self.get(0)`.
    void* elem = vec->front();
    ring_dup(elem);
    return ring_enum_some(elem);
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
            // B-103: dup each copied element, then drop the sub-list (the
            // closure's result, owned by Ring-fn convention).  Before this, the
            // result STOLE the sub-list's element ownership (no dup) and leaked
            // the sub-list header — and when the closure returned a Clone of an
            // EXISTING list (`.flat_map(fn(l) { l })` — tail escape Clones the
            // borrowed param), the result's deep-drop freed elements still owned
            // by the original → UAF.  dup + drop is balanced for both cases:
            // fresh sub (rc1: dup→2, deep-drop→1, owned by result; header freed)
            // and shared sub (rc≥2: dup, shallow drop; both owners intact).
            for (void* el : *svec) {
                ring_dup(el);
                result->push_back(el);
            }
            ring_drop(sub);
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
    return it->second;  // B-098: borrow (no dup); clone on escape
}

extern "C" void* ring_map_get_opt(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    std::string* k = (std::string*)key;
    auto it = m->find(*k);
    if (it == m->end()) return ring_enum_none();
    ring_dup(it->second);  // B-098: fresh Option co-owns the value (see ring_list_get_opt)
    return ring_enum_some(it->second);
}

extern "C" void* ring_map_set(void* map, void* key, void* val) {
    CHK("map_set");
    RingMap* m = (RingMap*)map;
    const std::string& k = *(std::string*)key;
    // B-104 D1 rule ④ — duplicate-key insert must DROP the old value.  Insert
    // side: the value arg is a sink position (perceus sink_arg_indices ".insert"),
    // so the map owns +1 per value — the account drop_map settles at end-of-life.
    // The KEY is value-inlined: the node copies the std::string CONTENT (no RC
    // pointer is stored; the caller's key box stays a pure borrow), so there is
    // no key account to settle on hit (the existing node key is reused, no new
    // copy) or on miss (a fresh content copy owned by the node) — symmetric with
    // the insert side never dup'ing the key.  Store the new value first, THEN
    // drop the old: rc>1 sharers (`let saved = m[k]` escape-Clone / a get()
    // Option's dup) only get decremented; an unshared old value is freed.
    auto it = m->find(k);
    if (it == m->end()) {
        m->emplace(k, val);
    } else {
        void* old = it->second;
        it->second = val;
        ring_drop(old);
    }
    return map;
}

extern "C" int64_t ring_map_has(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    return m->count(*(std::string*)key) > 0 ? 1 : 0;
}

extern "C" void* ring_map_delete(void* map, void* key) {
    RingMap* m = (RingMap*)map;
    // B-104 D1 rule ④ — removal must DROP the value the map owned (+1 from the
    // ".insert" sink dup / map_from's dup; the account drop_map settles at
    // end-of-life).  The key owes nothing: the node's std::string is value-
    // inlined and destroyed by erase itself; the caller's key box is a borrow.
    // rc>1 sharers of the value only get decremented.
    auto it = m->find(*(std::string*)key);
    if (it != m->end()) {
        void* old = it->second;
        m->erase(it);
        ring_drop(old);
    }
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
        ring_dup(kv.second);  // B-098: the FRESH list co-owns its elements (the
                              // map keeps its own copy) — this is the model's
                              // "escape into a container = clone" inlined into the
                              // owned-container constructor, NOT a read-borrow dup.
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
        ring_dup(kv.second);  // B-098: the fresh entry pair (a List) co-owns the
                              // value; owned-container constructor, not a borrow.
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
    return it->second;  // B-098: borrow (no dup); clone on escape
}

extern "C" void* ring_map_int_get_opt(void* map, void* key) {
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    auto it = m->find(k);
    if (it == m->end()) return ring_enum_none();
    ring_dup(it->second);  // B-098: fresh Option co-owns the value (see ring_list_get_opt)
    return ring_enum_some(it->second);
}

extern "C" void* ring_map_int_set(void* map, void* key, void* val) {
    CHK("map_int_set");
    RingMapInt* m = (RingMapInt*)map;
    int64_t k = *(int64_t*)key;
    // B-104 D1 rule ④ — duplicate-key insert must DROP the old value (the map
    // owns +1 per value via the ".insert" sink dup; see ring_map_set).  The key
    // is an unboxed int64 read out of the caller's box — value-inlined, no RC
    // account on either insert or overwrite.
    auto it = m->find(k);
    if (it == m->end()) {
        m->emplace(k, val);
    } else {
        void* old = it->second;
        it->second = val;
        ring_drop(old);
    }
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
    // B-104 D1 rule ④ — removal must DROP the owned value (see ring_map_delete);
    // the int64 key is value-inlined, no RC account.
    auto it = m->find(k);
    if (it != m->end()) {
        void* old = it->second;
        m->erase(it);
        ring_drop(old);
    }
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
        ring_dup(kv.second);  // B-103: fresh List co-owns the value (same
                              // owned-container-constructor rule as ring_map_values;
                              // was a latent un-dup'd borrow, now droppable via
                              // is_droppable_init(Call)=true).
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
        ring_dup(kv.second);  // B-103: fresh entry pair co-owns the value (same as
                              // ring_map_entries); was a latent un-dup'd borrow.
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
    RingMapInt* nm = new (data) RingMapInt(*m);
    // B-104 (#135): dup each value — clone must co-own values (keys inline int64,
    // values RC void*). Same class as ring_list_clone / ring_map_clone.
    for (auto& kv : *nm) ring_dup(kv.second);
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
            void* val = (*pair)[1];
            // B-103: dup — fresh map co-owns the value (see ring_map_from).
            ring_dup(val);
            // B-104 D1 rule ④ — repeated key: later entry wins; drop the
            // previously stored dup (this map's own +1; see ring_map_from).
            auto it = result->find(key);
            if (it == result->end()) {
                result->emplace(key, val);
            } else {
                void* old = it->second;
                it->second = val;
                ring_drop(old);
            }
        }
    }
    return data;
}

extern "C" void* ring_map_int_clear(void* map) {
    RingMapInt* m = (RingMapInt*)map;
    // B-104 D1 rule ④ — drop every owned value (see ring_map_clear); int64 keys
    // are value-inlined, no RC account.
    for (auto& kv : *m) ring_drop(kv.second);
    m->clear();
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
    // B-104 D1 rule ④ audit — nothing to drop: Set<Int> elements are value-
    // inlined int64 (see ring_set_clear), no RC account.
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
    auto* nv = new (data) std::vector<void*>(*vec);
    // B-103: a clone must co-own its elements (deep RC). The shallow copy above
    // shares element pointers with the source; under Perceus RC both lists would
    // deep-drop the same elements -> over-free. dup each so the clone is an
    // independent owner (latent double-free masked by never-drop / the
    // conservative is_droppable_init Call=false gate before B-102/B-103).
    for (void* el : *nv) ring_dup(el);
    return data;
}

extern "C" void* ring_map_clone(void* map) {
    RingMap* m = (RingMap*)map;
    void* data = ring_alloc(sizeof(RingMap), RING_TYPEID_MAP);
    RingMap* nm = new (data) RingMap(*m);
    // B-104 (#135): same as ring_list_clone — a clone must co-own its values
    // (keys are std::string, inline; values are RC void*). dup each value so the
    // clone is an independent owner; without it both maps deep-drop the same
    // values under Perceus RC -> over-free. Latent until temp-drop activates.
    for (auto& kv : *nm) ring_dup(kv.second);
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
            void* val = (*pair)[1];
            // B-103: dup — the fresh map co-owns the value still owned by the
            // entries pair-list (owned-container-constructor rule; see
            // ring_list_concat).
            ring_dup(val);
            // B-104 D1 rule ④ — repeated key: the later entry wins (JS
            // `new Map(entries)` oracle), and the previously stored dup is THIS
            // map's own +1 — release it, else it leaks.  The entries list's own
            // reference is untouched either way (rc only steps back to the
            // pre-dup count, never below — the overwritten value stays alive
            // for the entries list).
            auto it = result->find(*key);
            if (it == result->end()) {
                result->emplace(*key, val);
            } else {
                void* old = it->second;
                it->second = val;
                ring_drop(old);
            }
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
    auto* vec = (std::vector<void*>*)list;
    // B-104 D1 rule ④ — clear is early end-of-life for the CONTENTS: drop every
    // element the list owned (+1 per slot from the push/set sink dups — the same
    // account drop_list settles when the list itself dies).  rc>1 sharers are
    // only decremented; the list stays alive and reusable.
    for (void* elem : *vec) ring_drop(elem);
    vec->clear();
    return list;
}

extern "C" void* ring_list_extend(void* list, void* other) {
    auto* va = (std::vector<void*>*)list;
    auto* vb = (std::vector<void*>*)other;
    // B-102: each element of `other` ESCAPES into `list` (the destination co-owns
    // it), so dup it — exactly like push (the clone-all-escape "escape into a
    // container = clone" rule, inlined at runtime, same as map.values()/entries()).
    // Without this, `list` and `other` would share the same element pointers; when
    // both lists are scope-end-dropped (e.g. emit_fn_decl's `all.extend(param_names)`
    // then both `all` and `param_names` drop), drop_list would free each shared
    // element TWICE → native self-compile over-free (B-102 layer 5).
    for (void* e : *vb) {
        ring_dup(e);
        va->push_back(e);
    }
    return list;
}

// ============================================================================
// Map operations (additional)
// ============================================================================

extern "C" void* ring_map_clear(void* map) {
    RingMap* m = (RingMap*)map;
    // B-104 D1 rule ④ — drop every owned value (see ring_list_clear); keys are
    // value-inlined std::string, destroyed by clear() itself, no RC account.
    for (auto& kv : *m) ring_drop(kv.second);
    m->clear();
    return map;
}

// ============================================================================
// Set operations (additional clear/remove)
// ============================================================================

extern "C" void* ring_set_clear(void* set) {
    // B-104 D1 rule ④ audit — nothing to drop: Set<Str> elements are VALUE-
    // INLINED std::string copies (ring_set_add copies the CONTENT; no RC pointer
    // is ever stored — same conclusion as ring_set_clone, #135), so clear() owes
    // no RC account; ~unordered_set semantics handle the inline strings.
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
