"""
FIRE（提前退休）可行性测算
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False

print("=" * 60)
print("  FIRE 提前退休测算")
print("=" * 60)

# ============================
# 基本假设
# ============================
AGE_NOW = 25
RETIRE_GOAL = [35, 40, 45]  # 测算不同退休年龄

# 收入假设（税后月薪，逐年增长）
SALARY_START = 18000  # 25k税前，到手约18k
SALARY_GROWTH = 0.08  # 前5年较快增长
SALARY_GROWTH_LATE = 0.04  # 5年后增速放缓
SALARY_CAP = 40000  # 到手天花板（不含跳槽大幅涨薪的情况）

# 支出假设（杭州）
EXPENSE_MONTHLY = 8000  # 租房+吃饭+生活+每年1-2次东京
EXPENSE_GROWTH = 0.03   # 支出年增长（通胀+生活升级）

# 投资假设
INVEST_RETURN = 0.07  # 永久组合年化7%（保守估计）
INFLATION = 0.03

# 退休后假设
RETIRE_EXPENSE_MONTHLY = 10000   # 退休后月支出（今天的购买力）
FREELANCE_INCOME = 5000          # 自由职业月收入（不稳定，保守估）
FREELANCE_YEARS = 10             # 自由职业能做多久

# 家庭200w：不算入个人投资，只做背景安全垫
FAMILY_ASSETS = 2000000

# 社保：如果工作满15年可以领养老金（60岁起）
PENSION_AGE = 60
PENSION_MONTHLY = 3000  # 很粗略的估计，到时候购买力可能更低

print(f"""
基本参数：
  当前年龄: {AGE_NOW}岁
  起始月薪(到手): ¥{SALARY_START:,}
  月支出: ¥{EXPENSE_MONTHLY:,}
  投资年化收益: {INVEST_RETURN:.0%}
  通胀率: {INFLATION:.0%}
  退休后月支出(今日购买力): ¥{RETIRE_EXPENSE_MONTHLY:,}
  自由职业月收入: ¥{FREELANCE_INCOME:,}
""")

# ============================
# 核心公式：4%法则
# ============================
print("=" * 60)
print("  核心概念：4%法则")
print("=" * 60)
print("""
  FIRE的核心公式：

  退休所需资产 = 年支出 ÷ 安全提取率

  传统4%法则（美国）：退休资产的4%够一年开销 = 需要25倍年支出
  中国建议用3.5%（更保守）：需要约29倍年支出

  你的情况：
""")

for rate_name, safe_rate in [("4%法则", 0.04), ("3.5%保守", 0.035), ("3%极保守", 0.03)]:
    annual_expense = RETIRE_EXPENSE_MONTHLY * 12
    need = annual_expense / safe_rate
    need_with_freelance = (annual_expense - FREELANCE_INCOME * 12) / safe_rate
    print(f"  {rate_name}:")
    print(f"    纯靠投资: 需要 ¥{need/10000:,.0f}万 (月支出¥{RETIRE_EXPENSE_MONTHLY:,})")
    print(f"    有自由职业收入: 需要 ¥{need_with_freelance/10000:,.0f}万 (每月只需从投资取¥{RETIRE_EXPENSE_MONTHLY-FREELANCE_INCOME:,})")
    print()

# ============================
# 详细模拟：逐年推演
# ============================
print("=" * 60)
print("  逐年资产推演")
print("=" * 60)

def simulate(monthly_save_rate_override=None, return_rate=INVEST_RETURN, label=""):
    """模拟到55岁的资产轨迹"""
    ages = list(range(AGE_NOW, 56))
    assets = []
    salary_history = []
    save_history = []

    current_assets = 0
    current_salary = SALARY_START
    current_expense = EXPENSE_MONTHLY

    for i, age in enumerate(ages):
        # 工资增长
        if i > 0:
            if i <= 5:
                current_salary = min(current_salary * (1 + SALARY_GROWTH), SALARY_CAP)
            else:
                current_salary = min(current_salary * (1 + SALARY_GROWTH_LATE), SALARY_CAP)

        # 支出增长
        if i > 0:
            current_expense = current_expense * (1 + EXPENSE_GROWTH)

        # 月结余
        monthly_save = current_salary - current_expense
        if monthly_save_rate_override:
            monthly_save = current_salary * monthly_save_rate_override

        annual_save = monthly_save * 12

        # 投资增长 + 新增投入
        current_assets = current_assets * (1 + return_rate) + annual_save

        assets.append(current_assets)
        salary_history.append(current_salary)
        save_history.append(monthly_save)

    return ages, assets, salary_history, save_history

# 基准场景
ages, assets, salaries, saves = simulate()

print(f"\n  {'年龄':>4s} {'月薪(到手)':>10s} {'月支出':>8s} {'月结余':>8s} {'累计资产':>12s} {'状态':>10s}")
print("  " + "-" * 65)

# 计算FIRE目标线（考虑通胀的退休支出）
for i, age in enumerate(ages):
    # 退休时的实际月支出（通胀调整）
    years_from_now = age - AGE_NOW
    real_retire_expense = RETIRE_EXPENSE_MONTHLY * (1 + INFLATION) ** years_from_now
    fire_target_conservative = (real_retire_expense - FREELANCE_INCOME) * 12 / 0.035
    fire_target_relaxed = (real_retire_expense - FREELANCE_INCOME) * 12 / 0.04

    status = ""
    if assets[i] >= fire_target_conservative:
        status = "★ FIRE达成!"
    elif assets[i] >= fire_target_relaxed:
        status = "✓ 接近FIRE"

    if age <= 30 or age % 2 == 0 or status:
        expense = EXPENSE_MONTHLY * (1 + EXPENSE_GROWTH) ** years_from_now
        print(f"  {age:4d}  ¥{salaries[i]:>9,.0f} ¥{expense:>7,.0f} ¥{saves[i]:>7,.0f}  ¥{assets[i]/10000:>10,.1f}万  {status}")

# ============================
# 多场景对比
# ============================
print("\n\n" + "=" * 60)
print("  不同场景下的FIRE年龄")
print("=" * 60)

scenarios = [
    ("保守场景: 年化5%, 不涨薪", 0.05, False, 0),
    ("基准场景: 年化7%, 正常涨薪", 0.07, True, 0),
    ("乐观场景: 年化9%, 正常涨薪", 0.09, True, 0),
    ("跳槽加速: 年化7%, 中途涨薪到35k", 0.07, True, 35000),
    ("极致储蓄: 年化7%, 月支出压到5000", 0.07, True, -5000),
]

for desc, ret, grow, special in scenarios:
    current_assets_s = 0
    salary_s = SALARY_START
    expense_s = EXPENSE_MONTHLY if special >= 0 else 5000
    fire_age = None

    for age in range(AGE_NOW, 61):
        years = age - AGE_NOW
        if grow and years > 0:
            if years <= 5:
                salary_s = min(salary_s * (1 + SALARY_GROWTH), SALARY_CAP)
            else:
                salary_s = min(salary_s * (1 + SALARY_GROWTH_LATE), SALARY_CAP)

        if special > 0 and years >= 5:
            salary_s = max(salary_s, special)

        if years > 0:
            expense_s *= (1 + EXPENSE_GROWTH)

        save_s = salary_s - expense_s
        current_assets_s = current_assets_s * (1 + ret) + save_s * 12

        real_retire_expense = RETIRE_EXPENSE_MONTHLY * (1 + INFLATION) ** years
        target = (real_retire_expense - FREELANCE_INCOME) * 12 / 0.035

        if current_assets_s >= target and fire_age is None:
            fire_age = age

    fire_str = f"{fire_age}岁" if fire_age else "60岁前无法达成"
    target_at_fire = 0
    if fire_age:
        yrs = fire_age - AGE_NOW
        target_at_fire = (RETIRE_EXPENSE_MONTHLY * (1+INFLATION)**yrs - FREELANCE_INCOME) * 12 / 0.035
    print(f"  {desc:40s} → {fire_str:8s}", end="")
    if fire_age:
        print(f"  (需攒¥{target_at_fire/10000:,.0f}万)")
    else:
        print()

# ============================
# 退休后现金流模拟
# ============================
print("\n\n" + "=" * 60)
print("  退休后30年现金流模拟（假设40岁退休）")
print("=" * 60)

# 假设40岁退休，届时资产
retire_age = 40
years_work = retire_age - AGE_NOW
asset_at_retire = 0
sal = SALARY_START
exp = EXPENSE_MONTHLY
for y in range(years_work):
    if y > 0:
        if y <= 5:
            sal = min(sal * (1 + SALARY_GROWTH), SALARY_CAP)
        else:
            sal = min(sal * (1 + SALARY_GROWTH_LATE), SALARY_CAP)
    if y > 0:
        exp *= (1 + EXPENSE_GROWTH)
    asset_at_retire = asset_at_retire * (1 + INVEST_RETURN) + (sal - exp) * 12

print(f"\n  40岁时预计资产: ¥{asset_at_retire/10000:,.1f}万")

# 退休后模拟
asset = asset_at_retire
print(f"\n  {'年龄':>4s} {'资产':>10s} {'投资收益':>10s} {'自由职业':>8s} {'支出':>8s} {'养老金':>6s} {'净变化':>8s}")
print("  " + "-" * 70)

for age in range(retire_age, 86):
    years_retired = age - retire_age
    years_total = age - AGE_NOW

    # 投资收益
    invest_income = asset * INVEST_RETURN

    # 自由职业收入（假设做10年，逐年减少）
    if years_retired < FREELANCE_YEARS:
        freelance = FREELANCE_INCOME * 12 * (1 - years_retired * 0.05)  # 逐年减5%
    else:
        freelance = 0

    # 养老金
    pension = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0

    # 支出（通胀调整）
    annual_expense = RETIRE_EXPENSE_MONTHLY * 12 * (1 + INFLATION) ** years_total

    # 净变化
    net = invest_income + freelance + pension - annual_expense
    asset += net

    if age <= 45 or age % 5 == 0 or age >= 58:
        print(f"  {age:4d}  ¥{asset/10000:>8,.1f}万  ¥{invest_income/10000:>8,.1f}万  ¥{freelance/10000:>6,.1f}万  ¥{annual_expense/10000:>6,.1f}万  ¥{pension/10000:>4,.1f}万  {'+' if net>0 else ''}{net/10000:>.1f}万")

if asset > 0:
    print(f"\n  85岁时剩余资产: ¥{asset/10000:,.1f}万 ✓ 没花完")
else:
    print(f"\n  ⚠ 资产在85岁前耗尽!")

# ============================
# 画图
# ============================
fig, axes = plt.subplots(2, 1, figsize=(14, 12))

# 图1: 资产积累路径
ax = axes[0]
for desc, ret, grow, special in [
    ("保守(5%)", 0.05, True, 0),
    ("基准(7%)", 0.07, True, 0),
    ("乐观(9%)", 0.09, True, 0),
]:
    _, a, _, _ = simulate(return_rate=ret)
    ages_plot = list(range(AGE_NOW, 56))
    ax.plot(ages_plot, [x/10000 for x in a], lw=2, label=desc)

# FIRE目标线
fire_targets = []
for age in range(AGE_NOW, 56):
    yrs = age - AGE_NOW
    real_expense = RETIRE_EXPENSE_MONTHLY * (1 + INFLATION) ** yrs
    target = (real_expense - FREELANCE_INCOME) * 12 / 0.035
    fire_targets.append(target / 10000)
ax.plot(range(AGE_NOW, 56), fire_targets, 'k--', lw=2, label='FIRE目标线(3.5%)')

ax.set_xlabel('年龄', fontsize=12)
ax.set_ylabel('资产（万元）', fontsize=12)
ax.set_title('资产积累 vs FIRE目标线', fontsize=16, fontweight='bold')
ax.legend(fontsize=11)
ax.grid(True, alpha=0.3)
ax.set_xlim(25, 55)

# 图2: 退休后资产变化
ax = axes[1]
retire_ages_test = [35, 38, 40, 43, 45]
for ra in retire_ages_test:
    # 积累阶段
    a = 0
    s = SALARY_START
    e = EXPENSE_MONTHLY
    for y in range(ra - AGE_NOW):
        if y > 0:
            s = min(s * (1 + (SALARY_GROWTH if y <= 5 else SALARY_GROWTH_LATE)), SALARY_CAP)
        if y > 0:
            e *= (1 + EXPENSE_GROWTH)
        a = a * (1 + INVEST_RETURN) + (s - e) * 12

    # 退休后
    post_ages = list(range(ra, 86))
    post_assets = []
    for age in post_ages:
        yr = age - ra
        yt = age - AGE_NOW
        inv = a * INVEST_RETURN
        fl = FREELANCE_INCOME * 12 * max(0, 1 - yr * 0.05) if yr < FREELANCE_YEARS else 0
        pen = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0
        exp_a = RETIRE_EXPENSE_MONTHLY * 12 * (1 + INFLATION) ** yt
        a += inv + fl + pen - exp_a
        post_assets.append(a / 10000)

    color = 'red' if min(post_assets) < 0 else 'green'
    ax.plot(post_ages, post_assets, lw=2 if ra == 40 else 1, label=f'{ra}岁退休', alpha=0.8)

ax.axhline(0, color='red', ls='--', lw=1)
ax.set_xlabel('年龄', fontsize=12)
ax.set_ylabel('资产（万元）', fontsize=12)
ax.set_title('不同退休年龄 → 退休后资产变化', fontsize=16, fontweight='bold')
ax.legend(fontsize=11)
ax.grid(True, alpha=0.3)

plt.tight_layout(pad=2)
plt.savefig('output/fire_plan.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: output/fire_plan.png")
