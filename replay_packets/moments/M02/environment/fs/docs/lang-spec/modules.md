# 模块系统

Ring 使用基于文件的模块系统。每个 `.ring` 文件是一个模块。模块通过 `use` 声明导入其他模块的公开符号。

## 模块标识

模块名由文件路径派生，`::` 分隔符映射到文件系统目录分隔符：

```
use parser::lexer    →  parser/lexer.ring
use utils            →  utils.ring
```

项目根目录是入口文件所在目录。

## 导入语法

### 单符号导入

```ring
use parser::Token
```

从 `parser.ring` 导入 `Token`。

### 多符号导入

```ring
use parser::{Token, parse, Lexer}
```

从同一模块导入多个符号。

### 整模块导入

```ring
use parser
```

导入模块作为命名空间。通过 `parser::Token` 访问。

> **注意**：当前实现中，`use module_name` 将所有 pub 符号直接导入当前作用域，不支持命名空间访问（`module::symbol`）或 `as` 别名。命名空间导入为未来特性。

### 重命名导入

```ring
use parser as p
use parser::{Token as T}
```

模块别名或符号别名。

### 嵌套路径

```ring
use checker::env::TypeEnv
```

映射到 `checker/env.ring` 中的 `TypeEnv`。

### 相对路径（`super::`/`self::`）

在 inline `mod` 块内部，可以使用相对路径引用外层模块的符号。

#### `super::` 引用父模块

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value       // 导入父模块 outer 的 value
        pub fn get() -> Int { value() }
    }
}
```

`super::` 可以在 `use` 声明中使用，也可以在表达式中直接使用：

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        pub fn get() -> Int { super::value() }   // 表达式中直接访问
    }
}
```

支持多级 `super` 链式引用和多符号导入：

```ring
use super::super::some_fn         // 向上两层
use super::{value, helper}        // 从父模块导入多个符号
```

在文件顶层使用 `super::` 会报 E0705 错误（超出模块嵌套深度）。

#### `self::` 引用当前模块

```ring
mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }

    pub fn double(x: Int) -> Int {
        self::add(x, x)    // 显式引用当前模块的 add
    }
}
```

`self::` 用于消除歧义，显式指定当前模块的符号。

## 导出和可见性

### `pub` 修饰符

```ring
pub fn greet() -> Str { "hello" }
pub struct Point { pub x: Int, pub y: Int }
```

在多文件模式下，未标记 `pub` 的声明不可被其他模块导入。导入非 pub 符号报 E0701 错误。

单文件模式下 `pub` 被接受但不强制执行（向后兼容）。

### `pub use` 再导出

```ring
pub use inner::greet
```

将依赖模块的导出提升为当前模块的公开接口。支持模块门面模式。

## Inline `mod` 块

除了基于文件的模块外，Ring 支持在同一文件内定义 inline 模块块。

### 基本语法

```ring
mod math {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
}

fn main() {
    let sum = math::add(1, 2)
}
```

`mod` 块内的声明通过 `mod_name::symbol` 限定路径访问。未标记 `pub` 的声明在模块外不可见。

### 嵌套模块

`mod` 块可以嵌套，形成多级命名空间：

```ring
mod outer {
    pub mod inner {
        pub fn greet(name: Str) -> Str {
            "hello ${name}"
        }
    }
}

fn main() {
    let msg = outer::inner::greet("world")    // 多级限定路径
}
```

嵌套模块中的 `pub` 控制对外层的可见性——内层模块需要 `pub` 才能被外层模块之外访问，内层的声明也需要 `pub`。

### `mod` 块内的 `use` 声明

`mod` 块内部可以使用 `use` 导入外部模块的符号，也可以使用 `super::`/`self::` 相对路径（见上文）：

```ring
mod outer {
    pub fn value() -> Int { 42 }

    mod inner {
        use super::value
        pub fn get_outer() -> Int { value() }
    }
}
```

### `mod` 块内的声明

`mod` 块内可以包含所有声明类型：函数、struct、enum、trait、impl、effect、const、嵌套 mod 等。

```ring
mod shapes {
    pub struct Circle { pub radius: Float }

    pub impl Circle {
        pub fn area(self) -> Float { 3.14159 * self.radius * self.radius }
    }
}
```

### Capability 限制（`mod requires`）

`mod requires {effects}` 语法限制模块内所有函数可以使用的 effect 集合。编译器在类型检查阶段验证：模块内的函数如果使用了不在 `requires` 集合中的 effect，报 E0405 错误。

#### 纯模块（无 effect）

```ring
mod pure_logic requires {} {
    pub fn add(a: Int, b: Int) -> Int { a + b }
    pub fn double(x: Int) -> Int { x + x }
    // 此模块内不能使用 io、fail 等任何 effect
}
```

`requires {}` 表示空 effect 集合——模块内只允许纯函数。任何尝试使用 `io`、`fail` 等 effect 的函数都会报错。

#### 受限模块（指定 effect 子集）

```ring
mod io_layer requires {io} {
    pub fn greet(name: Str) -> Unit with {io} {
        print("Hello, ${name}!")
    }
    // 此模块内只允许 io effect，使用 fail 等其他 effect 会报错
}
```

#### Capability 检查规则

- 检查覆盖模块内所有顶层函数和 impl 方法（包括 delegate 生成的实现）
- 纯函数（无 effect）在任何 `requires` 集合中都合法——开放的 effect row 尾部不会被误判
- `mut<T>` marker effect 也受 capability 限制——`mod requires {}` 中不允许 `mut self` 方法

### 命名空间化

Inline `mod` 块的声明在编译时添加模块前缀。例如 `mod shapes { fn area() }` 中的 `area` 在 JS 中生成为 `shapes$area`。嵌套模块使用 `::` 分隔：`outer::inner::greet` 生成为 `outer$inner$greet`。

## `sig` 接口声明

`sig` 块定义模块接口签名，声明一组函数的类型签名但不提供实现。

### 语法

```ring
sig Serializable {
    fn serialize<T>(value: T) -> Str
    fn deserialize<T>(data: Str) -> T with {fail<Str>}
}
```

`sig` 块包含一组 `fn` 签名声明，每个签名可以有：
- 类型参数（泛型）
- 参数列表（含类型标注）
- 返回类型
- Effect 标注（`with {effects}`）

`sig` 块可以标记 `pub` 以控制可见性。

> **注意**：当前 `sig` 仅进行类型注册（`register_sig` 生成 `SigDef`），不支持 `mod : SigName` 一致性检查。一致性验证是未来特性。

## 编译模型

### 自动检测

编译器通过检查源文件中是否有 `use` 声明来决定编译模式。有 `use` → 多文件模式，无 `use` → 单文件模式。

### 编译流程

```
1. 从入口文件开始，BFS 发现所有依赖模块
2. 拓扑排序（Kahn 算法）确定编译顺序
3. 按序处理每个模块：
   a. Parse → AST
   b. Check → HIR（注入依赖模块的 ModuleExports）
   c. Codegen → JS（命名空间化）
4. 拼接为单文件 JS bundle 输出
```

### 循环依赖

循环依赖在拓扑排序阶段检测，报 E0704 错误。

### 命名空间化

多文件模式下，每个模块的顶层声明添加 `module$` 前缀：

```
parser.ring 中的 fn parse()  →  JS 中的 function parser$parse()
parser.ring 中的 struct Token  →  JS 中的 class parser$Token
```

跨模块引用通过 `imports_map` 解析为正确的前缀名。

内置类型（Option、List 等）和运行时函数不加前缀。`extern fn` 声明保留原始 JS 函数名。

## ModuleExports

每个编译完成的模块产生一个 `ModuleExports` 记录：

```
ModuleExports {
  types: Map<string, TypeDef>           // struct/enum/extern type
  values: Map<string, TypeScheme>       // 函数、常量
  trait_impls: TraitImpl[]              // trait 实现
  re_exports: Map<string, ...>          // pub use 再导出
  extern_values: Set<string>            // extern fn（不加模块前缀）
}
```

下游模块的 checker 通过 `inject_module_exports` 将这些信息注入类型环境。

## 错误码

| 错误码 | 描述 |
|--------|------|
| E0405 | Capability 限制违反（`mod requires` 中使用了不允许的 effect） |
| E0701 | 导入非 pub 符号 |
| E0702 | 模块未找到 |
| E0703 | 模块中无此符号 |
| E0704 | 循环依赖 |
| E0705 | 重复导入 / 相对路径超出模块嵌套深度 |
| E0706 | `use` 不在文件顶部 |

## 限制

- 不支持 first-class modules
- 不支持 `mod : SigName` 一致性检查（`sig` 仅做类型注册，不验证模块是否满足签名）
- 不支持跨文件相对路径（`super::`/`self::` 仅在 inline `mod` 块内可用）
- 跨文件跳转定义和查找引用在 LSP 中尚未实现（hover 和类型检查已支持跨模块）
