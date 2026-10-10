<!-- 41212 ms -->
Current goal: 完成 M1 数据模型逐轮确认，并理解“先发指导消息再中断”能否实现及时纠偏。

Likely current state: 第 3 轮已获明确认可；用户正推演规则的实际用法，发现了一个有用的操作组合。

Evidence: 用户说“没有要改的”，随后提出“先发一个guide message然后打断turn”。此前规则允许新消息排队，但中断后的续跑触发条件尚不明确。

Alternative interpretation: 用户也可能在表达体验要求：这个组合应自动开始下一 turn，让指导立即生效。

What would be dangerous to assume: 把“马上看到”当成已验证的保证，默认中断会自动续跑，或混淆排队的新消息与禁止自动重投的旧输入。

Next interaction strategy: 按既定流程记录第 3 轮；简短回应快速纠偏的用途，核对进程退出后新消息如何触发下一 turn，再进入第 4 轮，不扩大成新工程。
