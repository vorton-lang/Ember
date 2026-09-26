// ============================================================
// LLVM-C API FFI Declarations for Ring LLVM Backend
// ============================================================
//
// Opaque pub extern types + pub extern fn declarations for LLVM-C 22.
// These are consumed by the LLVM codegen pass; the actual
// implementations live in the N-API addon (compiler/llvm-addon/).
//
// Type mapping:
//   C const char*          -> Str
//   C int / unsigned       -> Int
//   C LLVMBool (int)       -> Int
//   C void return           -> Unit
//   C T* array + count     -> List<T> (count param omitted)
//   C output params         -> folded into return value

// ============================================================
// Opaque Types
// ============================================================

pub extern type LLVMContextRef
pub extern type LLVMModuleRef
pub extern type LLVMBuilderRef
pub extern type LLVMTypeRef
pub extern type LLVMValueRef
pub extern type LLVMBasicBlockRef
pub extern type LLVMTargetRef
pub extern type LLVMTargetMachineRef
pub extern type LLVMTargetDataRef
pub extern type LLVMPassManagerRef
pub extern type LLVMMemoryBufferRef
pub extern type LLVMAttributeRef
pub extern type LLVMMetadataRef

// ============================================================
// Context / Module
// ============================================================

pub extern fn LLVMContextCreate() -> LLVMContextRef
pub extern fn LLVMContextDispose(ctx: LLVMContextRef) -> Unit

pub extern fn LLVMModuleCreateWithNameInContext(name: Str, ctx: LLVMContextRef) -> LLVMModuleRef
pub extern fn LLVMDisposeModule(m: LLVMModuleRef) -> Unit
pub extern fn LLVMSetTarget(m: LLVMModuleRef, triple: Str) -> Unit
pub extern fn LLVMSetDataLayout(m: LLVMModuleRef, layout: Str) -> Unit
pub extern fn LLVMPrintModuleToString(m: LLVMModuleRef) -> Str
pub extern fn LLVMDisposeMessage(msg: Str) -> Unit

// LLVMVerifyModule: action is LLVMVerifierFailureAction enum (Int).
// Returns 0 on success, 1 on failure. Error message handled by addon.
pub extern fn LLVMVerifyModule(m: LLVMModuleRef, action: Int) -> Int

pub extern fn LLVMWriteBitcodeToFile(m: LLVMModuleRef, path: Str) -> Int

// ============================================================
// Types
// ============================================================

pub extern fn LLVMVoidTypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef
pub extern fn LLVMInt1TypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef
pub extern fn LLVMInt8TypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef
pub extern fn LLVMInt32TypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef
pub extern fn LLVMInt64TypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef
pub extern fn LLVMDoubleTypeInContext(ctx: LLVMContextRef) -> LLVMTypeRef

// Opaque pointer type. address_space is typically 0.
pub extern fn LLVMPointerTypeInContext(ctx: LLVMContextRef, address_space: Int) -> LLVMTypeRef

// params: List<LLVMTypeRef> replaces (LLVMTypeRef*, unsigned) pair.
// is_var_arg: 0 = false, 1 = true.
pub extern fn LLVMFunctionType(ret: LLVMTypeRef, params: List<LLVMTypeRef>, is_var_arg: Int) -> LLVMTypeRef

// elems: List<LLVMTypeRef> replaces (LLVMTypeRef*, unsigned) pair.
// packed: 0 = false, 1 = true.
pub extern fn LLVMStructTypeInContext(ctx: LLVMContextRef, elems: List<LLVMTypeRef>, packed: Int) -> LLVMTypeRef

pub extern fn LLVMArrayType2(elem: LLVMTypeRef, count: Int) -> LLVMTypeRef

// ============================================================
// Values / Constants
// ============================================================

// sign_extend: 0 = false, 1 = true.
pub extern fn LLVMConstInt(ty: LLVMTypeRef, val: Int, sign_extend: Int) -> LLVMValueRef

pub extern fn LLVMConstReal(ty: LLVMTypeRef, val: Float) -> LLVMValueRef

pub extern fn LLVMConstNull(ty: LLVMTypeRef) -> LLVMValueRef
pub extern fn LLVMConstPointerNull(ty: LLVMTypeRef) -> LLVMValueRef

// dont_null_terminate: 0 = add null terminator, 1 = don't.
pub extern fn LLVMConstStringInContext(ctx: LLVMContextRef, str: Str, dont_null_terminate: Int) -> LLVMValueRef

// elems: List<LLVMValueRef> replaces (LLVMValueRef*, uint64_t) pair.
pub extern fn LLVMConstArray2(elem_ty: LLVMTypeRef, elems: List<LLVMValueRef>) -> LLVMValueRef

pub extern fn LLVMGetUndef(ty: LLVMTypeRef) -> LLVMValueRef
pub extern fn LLVMSizeOf(ty: LLVMTypeRef) -> LLVMValueRef
pub extern fn LLVMConstBitCast(val: LLVMValueRef, to_type: LLVMTypeRef) -> LLVMValueRef
pub extern fn LLVMConstIntToPtr(val: LLVMValueRef, to_type: LLVMTypeRef) -> LLVMValueRef

// ============================================================
// Functions
// ============================================================

pub extern fn LLVMAddFunction(m: LLVMModuleRef, name: Str, fn_ty: LLVMTypeRef) -> LLVMValueRef
pub extern fn LLVMGetNamedFunction(m: LLVMModuleRef, name: Str) -> LLVMValueRef

pub extern fn LLVMGetParam(fn_val: LLVMValueRef, index: Int) -> LLVMValueRef
pub extern fn LLVMCountParams(fn_val: LLVMValueRef) -> Int

// linkage: Int encoding of LLVMLinkage enum
// (0 = External, 8 = Internal)
pub extern fn LLVMSetLinkage(global: LLVMValueRef, linkage: Int) -> Unit

// call_conv: Int encoding of LLVMCallConv enum
// (0 = C, 8 = Fast)
pub extern fn LLVMSetFunctionCallConv(fn_val: LLVMValueRef, call_conv: Int) -> Unit

pub extern fn LLVMGetEntryBasicBlock(fn_val: LLVMValueRef) -> LLVMBasicBlockRef
pub extern fn LLVMGetBasicBlockParent(bb: LLVMBasicBlockRef) -> LLVMValueRef
pub extern fn LLVMGetFirstInstruction(bb: LLVMBasicBlockRef) -> LLVMValueRef
pub extern fn LLVMPositionBuilderBefore(builder: LLVMBuilderRef, instr: LLVMValueRef) -> Unit
pub extern fn LLVMIsNullPtr(val: LLVMValueRef) -> Int

// attr_index: Int (0 = return, 1.. = params, -1 = function)
pub extern fn LLVMAddAttributeAtIndex(fn_val: LLVMValueRef, attr_index: Int, attr: LLVMAttributeRef) -> Unit

// ============================================================
// Basic Blocks
// ============================================================

pub extern fn LLVMAppendBasicBlockInContext(ctx: LLVMContextRef, fn_val: LLVMValueRef, name: Str) -> LLVMBasicBlockRef
pub extern fn LLVMGetInsertBlock(builder: LLVMBuilderRef) -> LLVMBasicBlockRef

pub extern fn LLVMCreateBuilderInContext(ctx: LLVMContextRef) -> LLVMBuilderRef
pub extern fn LLVMDisposeBuilder(builder: LLVMBuilderRef) -> Unit
pub extern fn LLVMPositionBuilderAtEnd(builder: LLVMBuilderRef, bb: LLVMBasicBlockRef) -> Unit

// ============================================================
// IR Builder — Arithmetic
// ============================================================

pub extern fn LLVMBuildAdd(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildSub(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildMul(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildSDiv(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildSRem(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef

pub extern fn LLVMBuildFAdd(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildFSub(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildFMul(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildFDiv(builder: LLVMBuilderRef, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef

// ============================================================
// IR Builder — Comparison
// ============================================================

// predicate: Int encoding of LLVMIntPredicate enum
// (32 = eq, 33 = ne, 34 = ugt, 35 = uge, 36 = ult, 37 = ule,
//  38 = sgt, 39 = sge, 40 = slt, 41 = sle)
pub extern fn LLVMBuildICmp(builder: LLVMBuilderRef, predicate: Int, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef

// predicate: Int encoding of LLVMRealPredicate enum
// (1 = oeq, 2 = ogt, 3 = oge, 4 = olt, 5 = ole, 6 = one, 14 = une)
pub extern fn LLVMBuildFCmp(builder: LLVMBuilderRef, predicate: Int, lhs: LLVMValueRef, rhs: LLVMValueRef, name: Str) -> LLVMValueRef

// ============================================================
// IR Builder — Memory
// ============================================================

pub extern fn LLVMBuildAlloca(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef

// Typed load (opaque pointer era): ty is the pointee type.
pub extern fn LLVMBuildLoad2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, name: Str) -> LLVMValueRef

pub extern fn LLVMBuildStore(builder: LLVMBuilderRef, val: LLVMValueRef, ptr: LLVMValueRef) -> LLVMValueRef

// Typed GEP (opaque pointer era): ty is the pointee type.
// indices: List<LLVMValueRef> replaces (LLVMValueRef*, unsigned) pair.
pub extern fn LLVMBuildGEP2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, indices: List<LLVMValueRef>, name: Str) -> LLVMValueRef

// Typed struct GEP: ty is the struct type, index is the field index.
pub extern fn LLVMBuildStructGEP2(builder: LLVMBuilderRef, ty: LLVMTypeRef, ptr: LLVMValueRef, index: Int, name: Str) -> LLVMValueRef

// ============================================================
// IR Builder — Control Flow
// ============================================================

pub extern fn LLVMBuildBr(builder: LLVMBuilderRef, dest: LLVMBasicBlockRef) -> LLVMValueRef
pub extern fn LLVMBuildCondBr(builder: LLVMBuilderRef, cond: LLVMValueRef, then_bb: LLVMBasicBlockRef, else_bb: LLVMBasicBlockRef) -> LLVMValueRef

pub extern fn LLVMBuildRet(builder: LLVMBuilderRef, val: LLVMValueRef) -> LLVMValueRef
pub extern fn LLVMBuildRetVoid(builder: LLVMBuilderRef) -> LLVMValueRef
pub extern fn LLVMBuildUnreachable(builder: LLVMBuilderRef) -> LLVMValueRef

// num_cases is a hint for the number of cases (actual cases added via LLVMAddCase).
pub extern fn LLVMBuildSwitch(builder: LLVMBuilderRef, val: LLVMValueRef, else_bb: LLVMBasicBlockRef, num_cases: Int) -> LLVMValueRef
pub extern fn LLVMAddCase(switch_val: LLVMValueRef, on_val: LLVMValueRef, dest: LLVMBasicBlockRef) -> Unit

// ============================================================
// IR Builder — Call
// ============================================================

// fn_ty: the function type (required for opaque pointers).
// args: List<LLVMValueRef> replaces (LLVMValueRef*, unsigned) pair.
pub extern fn LLVMBuildCall2(builder: LLVMBuilderRef, fn_ty: LLVMTypeRef, fn_val: LLVMValueRef, args: List<LLVMValueRef>, name: Str) -> LLVMValueRef

// ============================================================
// IR Builder — Type Conversion
// ============================================================

pub extern fn LLVMBuildBitCast(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildIntToPtr(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildPtrToInt(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildTrunc(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef
pub extern fn LLVMBuildZExt(builder: LLVMBuilderRef, val: LLVMValueRef, dest_ty: LLVMTypeRef, name: Str) -> LLVMValueRef

// ============================================================
// IR Builder — Phi
// ============================================================

pub extern fn LLVMBuildPhi(builder: LLVMBuilderRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef

// vals: List<LLVMValueRef> and blocks: List<LLVMBasicBlockRef>
// replace (LLVMValueRef*, LLVMBasicBlockRef*, unsigned) triple.
pub extern fn LLVMAddIncoming(phi: LLVMValueRef, vals: List<LLVMValueRef>, blocks: List<LLVMBasicBlockRef>) -> Unit

// ============================================================
// IR Builder — Globals
// ============================================================

pub extern fn LLVMAddGlobal(m: LLVMModuleRef, ty: LLVMTypeRef, name: Str) -> LLVMValueRef
pub extern fn LLVMSetInitializer(global: LLVMValueRef, val: LLVMValueRef) -> Unit
pub extern fn LLVMSetGlobalConstant(global: LLVMValueRef, is_constant: Int) -> Unit
pub extern fn LLVMBuildGlobalStringPtr(builder: LLVMBuilderRef, str: Str, name: Str) -> LLVMValueRef

// ============================================================
// Target Machine
// ============================================================

// X86 target initialization (each returns Unit, called for side effects)
pub extern fn LLVMInitializeX86TargetInfo() -> Unit
pub extern fn LLVMInitializeX86Target() -> Unit
pub extern fn LLVMInitializeX86TargetMC() -> Unit
pub extern fn LLVMInitializeX86AsmPrinter() -> Unit

pub extern fn LLVMGetDefaultTargetTriple() -> Str

// LLVMGetTargetFromTriple: C signature has output params (LLVMTargetRef*, char**).
// N-API addon folds output into return value; panics on error.
pub extern fn LLVMGetTargetFromTriple(triple: Str) -> LLVMTargetRef

// codegen: Int encoding of LLVMCodeGenOptLevel (0=None, 1=Less, 2=Default, 3=Aggressive)
// reloc: Int encoding of LLVMRelocMode (0=Default, 1=Static, 2=PIC, 3=DynamicNoPic)
// code_model: Int encoding of LLVMCodeModel (0=Default, 1=JITDefault, 2=Tiny, 3=Small, 4=Kernel, 5=Medium, 6=Large)
pub extern fn LLVMCreateTargetMachine(target: LLVMTargetRef, triple: Str, cpu: Str, features: Str, codegen: Int, reloc: Int, code_model: Int) -> LLVMTargetMachineRef
pub extern fn LLVMDisposeTargetMachine(tm: LLVMTargetMachineRef) -> Unit

// file_type: Int encoding of LLVMCodeGenFileType (0=Assembly, 1=Object)
// N-API addon folds error output param; panics on error.
pub extern fn LLVMTargetMachineEmitToFile(tm: LLVMTargetMachineRef, m: LLVMModuleRef, filename: Str, file_type: Int) -> Int
