---
name: No guessing — RE code is the only source of truth
description: All implementations must be based on reverse-engineered code, never on imagination or simplification. 100% behavioral consistency is the goal.
type: feedback
originSessionId: cf855507-5ee6-46fe-abb2-71641b21b33f
---
Never implement game behavior based on guessing, "reasonable assumptions", or simplification. Every value, formula, and behavior must come from reverse-engineered Arcaea code.

**Why:** Previous implementations had many bugs because Claude relied on imagination to fill gaps instead of waiting for RE results. The user's explicit goal is 100% behavioral consistency with Arcaea — rendering, judgment, and micro-timing alike.

**How to apply:**
- If RE data for a behavior is not yet available, mark it `TODO(RE)` and do not implement a placeholder.
- Never say "this should be approximately X" — find the exact value from RE.
- When implementing anything, cite the specific RE source (Ghidra offset, decompiled function, confirmed parameter).
- Each implementation must have a verification method proving consistency with the original game.
