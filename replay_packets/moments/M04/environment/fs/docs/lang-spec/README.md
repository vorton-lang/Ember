# Ring 语言规范

版本：0.2（Phase C）

本规范是 Ring 编程语言的权威参考，独立于任何具体编译器实现。

## 文档结构

| 文档 | 内容 |
|------|------|
| [词法结构](lexical.md) | Token、关键字、字面量、注释、空白规则 |
| [语法](syntax.md) | 所有语言构造的 EBNF 形式文法 |
| [类型系统](type-system.md) | 原始/复合类型、HM 推断、unification、泛化 |
| [Effect 系统](effects.md) | Effect 声明、row types、传播、handling |
| [Trait 系统](traits.md) | Trait 声明、impl 块、约束、dictionary passing |
| [模式匹配](patterns.md) | 模式形式、绑定规则、穷尽性检查 |
| [模块系统](modules.md) | 基于文件的模块、导入、可见性、编译模型 |
| [JS 翻译](codegen.md) | Ring → JavaScript 翻译契约和运行时 |
| [标准库](stdlib.md) | 内置类型、函数和方法 |

## 记号约定

- `monospace` 表示关键字、标识符或代码片段
- EBNF 使用 `::=` 定义产生式，`|` 表示选择，`?` 表示可选，`*` 表示零或多个，`+` 表示一或多个
- `⟨name⟩` 表示元变量（实际构造的占位符）
- 类型规则使用标准推导记法：前提在横线上方，结论在下方
- `Γ` 表示类型环境，`⊢` 表示类型判断，`/` 分隔类型和 effect row
- `τ`、`σ`、`ρ` 表示类型；`ε` 表示 effect row；`α`、`β` 表示类型变量

## 版本说明

本规范仅涵盖 Ring 已实现的子集。设计文档 (`docs/design.md`) 中描述但尚未实现的特性不包含在内。每节会标注相关限制。
