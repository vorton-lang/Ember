# 语法

Ring 的完整 EBNF 文法。产生式按类别分组。可选元素用 `?`，重复用 `*`（零或多个）和 `+`（一或多个）。终结符用 `'单引号'` 括起。

## 程序

```ebnf
Program      ::= UseDecl* Decl*
```

程序是一系列 `use` 声明后跟其他声明。`use` 声明必须出现在所有其他声明之前。

## 声明

```ebnf
Decl         ::= 'pub'? DeclKind

DeclKind     ::= FnDecl
               | StructDecl
               | EnumDecl
               | ImplDecl
               | TraitDecl
               | EffectDecl
               | EffectAliasDecl
               | ExternDecl
               | TypeAliasDecl
               | TestDecl
               | ConstDecl
               | ModDecl
               | SigDecl
```

`pub` 修饰符控制多文件编译中的可见性。单文件模式下接受但不强制。

### 函数声明

```ebnf
FnDecl       ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr ('with' '{' EffectExpr (',' EffectExpr)* '}')?)? Block

Params       ::= (Param (',' Param)* ','?)?
Param        ::= 'mut'? Ident (':' TypeExpr)?
```

省略返回类型注解时由推断确定。省略参数类型注解时分配 fresh 类型变量。`mut` 前缀标记参数为可变（允许在函数体内重赋值），也适用于方法的 `mut self`。`with { ... }` 子句声明函数的 effect 签名。

### Struct 声明

```ebnf
StructDecl   ::= 'struct' Ident TypeParams? '{' StructField* '}'

StructField  ::= 'pub'? Ident ':' TypeExpr WhereClause? ','?

WhereClause  ::= 'where' ⟨消费 token 直到 ',' 或 '}'⟩
```

字段上的 `where` 子句会被解析但不强制执行（为 refinement types 预留）。

### Enum 声明

```ebnf
EnumDecl     ::= 'enum' Ident TypeParams? '{' EnumVariant* '}'

EnumVariant  ::= Ident VariantFields? ','?

VariantFields ::= '(' TypeExpr (',' TypeExpr)* ')'                     (* 位置字段 *)
                | '{' NamedField (',' NamedField)* ','? '}'            (* 命名字段 *)

NamedField   ::= Ident ':' TypeExpr
```

无字段的变体是 unit 变体。位置字段和命名字段变体可在同一 enum 中共存。

### Impl 块

```ebnf
ImplDecl     ::= 'impl' TypeParams? ImplTarget '{' ImplMember* '}'

ImplTarget   ::= Ident TypeArgs?
               | Ident 'for' Ident TypeArgs?

ImplMember   ::= 'pub'? FnDecl
               | 'pub'? 'extern' 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)?
               | 'delegate' Ident ':' Ident (',' Ident)*
               | 'pub'? AssocTypeDecl
```

`impl Type { ... }` 定义固有方法。`impl Trait for Type { ... }` 实现 trait。Impl 块内可包含 `extern fn` 声明用于 FFI 方法绑定。`delegate field: Trait1, Trait2` 自动生成 trait 转发方法（替代继承的复用机制）。关联类型 `type Name = TypeExpr` 用于满足 trait 的关联类型要求。

### Trait 声明

```ebnf
TraitDecl    ::= 'trait' Ident TypeParams? (':' TypeBound ('+' TypeBound)*)? '{' TraitMember* '}'

TraitMember  ::= TraitMethod | AssocTypeDecl

TraitMethod  ::= 'pub'? 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)? Block?

AssocTypeDecl ::= 'pub'? 'type' Ident (':' TypeBound ('+' TypeBound)*)? ('=' TypeExpr)?
```

无函数体的方法是抽象方法（必须实现）。有函数体的方法提供默认实现。Supertrait 继承通过 `:` 后的 `TypeBound` 列表声明（如 `trait Ord: Eq`），支持多级传递和循环检测。关联类型通过 `type Name` 声明，可带 bounds 约束和默认值。

### Effect 声明

```ebnf
EffectDecl   ::= 'effect' Ident TypeParams? '{' EffectOp* '}'

EffectOp     ::= 'fn' Ident '(' Params ')' '->' TypeExpr (Block | ';' | ',')?
```

当 `EffectOp` 带有 `Block` 时，该 block 作为默认 handler body。全部 op 都有默认 handler 的 effect 可省略 `handle...with`，编译器自动注入 evidence；显式 `handle` 可覆盖默认。

### Effect Alias 声明

```ebnf
EffectAliasDecl ::= 'pub'? 'effect' 'alias' Ident TypeParams? '=' '{' EffectExpr (',' EffectExpr)* '}'
```

Effect alias 是 effect 集合的语法糖，如 `effect alias IO = {io, fail<Str>}`。支持泛型参数、循环检测和 `pub` 模块导出。

### Extern 声明

```ebnf
ExternDecl   ::= 'extern' ExternKind

ExternKind   ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)?   (* extern 函数 *)
               | 'type' Ident TypeParams?                                  (* opaque 类型 *)
```

`extern fn` 声明一个 JavaScript 实现的函数。`extern type` 声明一个表示不透明的 opaque 类型。

### 类型别名

```ebnf
TypeAliasDecl ::= 'type' Ident TypeParams? '=' TypeExpr
```

### Const 声明

```ebnf
ConstDecl    ::= 'const' Ident (':' TypeExpr)? '=' Expr
```

顶级编译期常量绑定。

### 测试声明

```ebnf
TestDecl     ::= 'test' StringLit Block
```

### Mod 块声明

```ebnf
ModDecl      ::= 'pub'? 'mod' Ident ('requires' '{' EffectExpr (',' EffectExpr)* '}')? '{' UseDecl* Decl* '}'
```

内联模块块，支持嵌套（`mod a { mod b { ... } }`）。`requires` 子句限制模块内可用的 effect capability。模块内可包含 `use` 声明和任意声明。

### Sig 块声明

```ebnf
SigDecl      ::= 'sig' Ident '{' SigMember* '}'

SigMember    ::= 'fn' Ident TypeParams? '(' Params ')' ('->' TypeExpr)? ('with' '{' EffectExpr (',' EffectExpr)* '}')?
```

接口签名声明，定义模块的类型接口。

### Use 声明

```ebnf
UseDecl      ::= 'pub'? 'use' UsePath UseKind

UsePath      ::= Ident ('::' Ident)*

UseKind      ::= '{' UseItem (',' UseItem)* ','? '}'   (* 分组导入 *)
               | 'as' Ident                             (* 模块别名 *)
               |                                         (* 整模块导入 *)

UseItem      ::= Ident ('as' Ident)?
```

## 类型表达式

```ebnf
TypeExpr     ::= NamedType
               | FnType
               | TupleType
               | RecordType

NamedType    ::= Ident TypeArgs? '?'?

FnType       ::= 'fn' '(' TypeExprList? ')' '->' TypeExpr ('with' '{' EffectExpr (',' EffectExpr)* '}')?

TupleType    ::= '(' TypeExpr ',' TypeExprList ')'

RecordType   ::= '{' RecordField (',' RecordField)* (',' '..' Ident)? ','? '}'

RecordField  ::= Ident ':' TypeExpr

TypeExprList ::= TypeExpr (',' TypeExpr)* ','?
```

命名类型的 `?` 后缀是 `Option<T>` 的语法糖：`Int?` ≡ `Option<Int>`。`FnType` 的 `with` 子句标注函数类型的 effect（无标注时为 open row，支持 effect 多态）。

### 类型参数与约束

```ebnf
TypeParams   ::= '<' TypeParam (',' TypeParam)* '>'

TypeParam    ::= Ident (':' TypeBound ('+' TypeBound)*)?

TypeBound    ::= Ident TypeArgs?

TypeArgs     ::= '<' TypeExpr (',' TypeExpr)* '>'
```

类型参数解析使用推测性前瞻：解析器尝试解析 `<Type, ...>`，如果 `<` 实际是比较运算符则回溯。

### Effect 表达式

```ebnf
EffectExpr   ::= Ident ('::' Ident)* TypeArgs?
```

Effect 表达式用于 effect 标注、effect alias 和 `requires` 子句中。支持限定路径（如 `mod::effect`）和类型参数（如 `fail<Str>`、`mut<T>`）。

## 语句

```ebnf
Stmt         ::= LetStmt
               | LetMutStmt
               | VarStmt
               | LetDestructStmt
               | IfLetStmt
               | ReturnStmt
               | WhileStmt
               | LoopStmt
               | ForInStmt
               | BreakStmt
               | ContinueStmt
               | AssignStmt
               | ExprStmt
```

### 绑定语句

```ebnf
LetStmt          ::= 'let' Ident (':' TypeExpr)? '=' Expr ';'?
LetMutStmt       ::= 'let' 'mut' Ident (':' TypeExpr)? '=' Expr ';'?
VarStmt          ::= 'var' Ident (':' TypeExpr)? '=' Expr ';'?
LetDestructStmt  ::= 'let' TuplePattern '=' Expr ';'?
```

`let` 绑定不可变（重赋值报 E0205 错误）。`let mut` 和 `var` 绑定可变（两种形式等价，`let mut` 是推荐写法）。

### 控制流语句

```ebnf
IfLetStmt    ::= 'if' 'let' Pattern '=' Expr Block ('else' Block)?

WhileStmt    ::= 'while' Expr Block

LoopStmt     ::= 'loop' Block

ForInStmt    ::= 'for' ForBinding 'in' Expr Block
ForBinding   ::= Ident
               | '(' Ident (',' Ident)+ ')'

BreakStmt    ::= 'break' ';'?
ContinueStmt ::= 'continue' ';'?
ReturnStmt   ::= 'return' Expr? ';'?
```

`break` 和 `continue` 仅在 `while`、`for` 或 `loop` 循环内有效（否则报 E0206 错误）。`loop` 是 `while true` 的语法糖。`for` 接受任何实现了 `Iterable` trait 的类型作为可迭代对象。

### 赋值和表达式语句

```ebnf
AssignStmt   ::= Expr ('=' | '+=' | '-=') Expr ';'?
ExprStmt     ::= Expr ';'?
```

赋值目标必须是可变的（`var`/`let mut` 绑定、struct 字段等）。

## 表达式

### 块

```ebnf
Block        ::= '{' Stmt* Expr? '}'
```

块包含零个或多个语句，后跟可选的尾部表达式（无分号）。块的值是尾部表达式的值；无尾部表达式时为 `Unit`。

### 基本表达式

```ebnf
PrimaryExpr  ::= IntLit | FloatLit | StringLit | RawStringLit
               | 'true' | 'false'
               | InterpString
               | Ident
               | QualifiedVariant
               | StructLit
               | ListLit
               | TupleOrParen
               | Block
               | IfExpr
               | MatchExpr
               | HandleExpr
               | LambdaExpr
               | UnaryExpr

QualifiedVariant ::= UpperIdent '::' Ident ArgList?
                   | UpperIdent '::' UpperIdent '{' FieldInit (',' FieldInit)* ','? '}'
```

### Struct 字面量

```ebnf
StructLit    ::= UpperIdent '{' ('..' Expr ',')? FieldInit (',' FieldInit)* ','? '}'

FieldInit    ::= Ident (':' Expr)?
```

大写字母开头的标识符后跟 `{` 触发 struct/变体字面量解析。字段 punning：`{ x }` 是 `{ x: x }` 的语法糖。`..expr` 前缀是 struct update 语法：从基础值复制未指定的字段。

### List 字面量

```ebnf
ListLit      ::= '[' (Expr (',' Expr)* ','?)? ']'
```

空列表 `[]` 需要类型上下文推断元素类型（歧义时报 E0301 错误）。

### Tuple 或括号表达式

```ebnf
TupleOrParen ::= '(' Expr ')'                     (* 括号表达式 *)
               | '(' Expr ',' ExprList? ')'        (* tuple，2+ 个元素 *)

ExprList     ::= Expr (',' Expr)* ','?
```

通过第一个表达式后是否有逗号来消歧。不支持单元素 tuple。

### If 表达式

```ebnf
IfExpr       ::= 'if' Expr Block ('else' (IfExpr | Block))?
```

作为表达式使用时，带 `else` 的 `if` 类型为两个分支的统一类型。无 `else` 的 `if` 类型为 `Unit`。

### Match 表达式

```ebnf
MatchExpr    ::= 'match' Expr '{' MatchArm* '}'

MatchArm     ::= Pattern Guard? '=>' Expr ','?

Guard        ::= 'if' Expr
```

分支从上到下检查。Guard 不影响穷尽性检查。模式语法和穷尽性规则见[模式匹配](patterns.md)。

### Handle 表达式

```ebnf
HandleExpr   ::= 'handle' Block 'with' '{' Handler (',' Handler)* ','? '}'

Handler      ::= Ident '.' Ident '(' Params ')' '=>' Expr
```

每个 handler 绑定 `⟨effect⟩.⟨operation⟩(⟨params⟩)`。被处理的 effect 从 body 的 effect row 中移除。语义见 [Effect 系统](effects.md)。

### Lambda 表达式

```ebnf
LambdaExpr   ::= 'fn' '(' Params ')' ('->' TypeExpr)? Block
```

匿名函数。参数和返回类型注解可选。

### Catch 表达式

```ebnf
CatchExpr    ::= Expr 'catch' '{' MatchArm* '}'
```

捕获 `fail` effect 并用 match-arm 风格的模式匹配分派错误类型。catch arms 经穷尽性检查（非穷尽报 E0601）。结果类型必须与左操作数类型统一。内部用模式匹配分派错误类型；需要部分处理时在 catch 内部 match + re-raise（显式）。

### 后缀表达式

```ebnf
PostfixExpr  ::= Expr '?'              (* option 解包 / fail 传播 *)
               | Expr '.' Ident ArgList (* 方法调用 *)
               | Expr '.' Ident        (* 字段访问 *)
               | Expr '.' IntLit       (* tuple 位置字段访问：.0 .1 .2 *)
               | Expr ArgList          (* 函数调用，同行规则 *)
               | Expr '[' Expr ']'     (* 下标访问 *)

ArgList      ::= '(' (Expr (',' Expr)* ','?)? ')'
```

`?` 后缀对 `Option<T>` 解包 `some` 或传播 `fail`。对带 `fail` effect 的表达式传播错误。下标访问 `list[i]` / `map[key]` / `str[i]` 越界或 key 不存在时 panic，安全访问用 `.get()` 返回 `Option<T>`。

### 二元表达式

```ebnf
BinExpr      ::= Expr BinOp Expr

BinOp        ::= '+' | '-' | '*' | '/' | '%'
               | '==' | '!=' | '<' | '>' | '<=' | '>='
               | '&&' | '||'
```

优先级表见[词法结构](lexical.md)。

### Range 表达式

```ebnf
RangeExpr    ::= Expr '..' Expr        (* 不含右端 *)
               | Expr '..=' Expr       (* 包含右端 *)
```

产生 `Range<Int>`。Start 和 end 都必须是 `Int`。

### 一元表达式

```ebnf
UnaryExpr    ::= '-' Expr              (* 数值取反 *)
               | '!' Expr              (* 逻辑 NOT *)
```

## 模式

```ebnf
Pattern      ::= SinglePattern ('|' SinglePattern)*

SinglePattern ::= '_'                                      (* 通配符 *)
               | IntLit | FloatLit | StringLit | BoolLit  (* 字面量 *)
               | Ident                                     (* 绑定或 unit 变体 *)
               | UpperIdent '(' PatList ')'               (* 位置构造器 *)
               | UpperIdent '{' NamedPat* '..'? '}'       (* 命名构造器 *)
               | UpperIdent '::' Ident PatFields?         (* 限定构造器 *)
               | '(' Pattern ',' PatList ')'              (* tuple *)

PatFields    ::= '(' PatList ')'
               | '{' NamedPat* '..'? '}'

PatList      ::= Pattern (',' Pattern)* ','?

NamedPat     ::= Ident (':' Pattern)? ','?
```

当 `Pattern` 包含 `|` 分隔的多个 `SinglePattern` 时，形成 Or-Pattern（如 `A | B => expr`）。Or-Pattern 支持 enum 变体、字面量、构造器和绑定变量，穷尽性检查正确处理。

与零字段 enum 变体同名的绑定模式会被重分类为构造器模式。命名构造器模式支持字段 punning（`{ x }` ≡ `{ x: x }`）和部分匹配（`..` 忽略其余字段）。

详细绑定规则和穷尽性算法见[模式匹配](patterns.md)。
