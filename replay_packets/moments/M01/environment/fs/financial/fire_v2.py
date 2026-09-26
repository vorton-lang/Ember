"""
FIRE测算 v2 - 不买房不结婚不生育版
"跳出三贷之外，不在五险之中"
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False

AGE_NOW = 25
INVEST_RETURN = 0.07
INFLATION = 0.03

# ============================
# 支出明细（杭州单身不买房）
# ============================
print("=" * 60)
print("  月支出拆解（杭州·单身·租房）")
print("=" * 60)

expenses = {
    '租房(合租/单间)': 2500,
    '吃饭(自己做+外卖)': 2000,
    '交通': 300,
    '日用/衣服/理发': 500,
    '手机/网络/订阅': 200,
    '社交/娱乐': 500,
    '东京旅行(均摊)': 1500,  # 每次约9000,一年两次=18000,月均1500
    '其他杂项': 500,
}

total_expense = sum(expenses.values())
print()
for item, cost in expenses.items():
    bar = "█" * (cost // 100)
    print(f"  {item:20s}  ¥{cost:>5,}  {bar}")
print(f"  {'─'*20}  ─────")
print(f"  {'合计':20s}  ¥{total_expense:>5,}/月  (¥{total_expense*12:,}/年)")

# 东京旅行详细估算
print(f"""
  ┌─ 东京旅行费用估算（每次）─────────────┐
  │  机票(杭州-东京): ¥2,000-3,500 (提前买) │
  │  住宿(5晚):      ¥2,000-3,000 (青旅/民宿)│
  │  吃饭+交通+门票:  ¥2,000-3,000          │
  │  购物/手办/药妆:  ¥1,000-2,000          │
  │  合计:           ¥7,000-11,500          │
  │  取中间值:        ¥9,000/次             │
  │  一年两次 = ¥18,000 = 月均 ¥1,500       │
  └──────────────────────────────┘
""")

# ============================
# 收入假设
# ============================
SALARY_START = 18000  # 25k税前到手
SALARY_GROWTH_FAST = 0.08
SALARY_GROWTH_SLOW = 0.04
SALARY_CAP = 40000

# 自由职业：接开发外包，保守估计
FREELANCE_MONTHLY = 3000  # 保守：零星接单
FREELANCE_GOOD = 5000     # 正常：稳定几个客户
FREELANCE_GREAT = 8000    # 乐观：有固定合作方
FREELANCE_DECAY = 0       # 不衰减，开发技能不会过时

print("=" * 60)
print("  收入结构")
print("=" * 60)
print(f"""
  工作期间：
    起始月薪(到手): ¥{SALARY_START:,}
    月结余: ¥{SALARY_START - total_expense:,} (储蓄率 {(SALARY_START-total_expense)/SALARY_START:.0%})

  退休后自由职业（开发外包）：
    保守: ¥{FREELANCE_MONTHLY:,}/月 (每月接1-2个小活)
    正常: ¥{FREELANCE_GOOD:,}/月 (有几个稳定客户)
    乐观: ¥{FREELANCE_GREAT:,}/月 (有固定合作方)
""")

# ============================
# 不同生活方式对比
# ============================
print("=" * 60)
print("  生活方式对FIRE的影响")
print("=" * 60)

lifestyles = {
    '你(不婚不房不娃)': {
        'expense': total_expense,
        'extra_events': [],
    },
    '对照A(买房不婚)': {
        'expense': total_expense,
        'extra_events': [('30岁首付60万+月供8000', 30, 600000, 8000)],
    },
    '对照B(买房结婚生娃)': {
        'expense': total_expense,
        'extra_events': [
            ('30岁首付60万+月供8000', 30, 600000, 8000),
            ('31岁婚礼20万', 31, 200000, 0),
            ('32岁起养娃+5000/月', 32, 0, 5000),
        ],
    },
}

for style_name, style in lifestyles.items():
    asset = 0
    sal = SALARY_START
    exp = style['expense']
    fire_age = None

    monthly_extra = 0

    for age in range(AGE_NOW, 61):
        y = age - AGE_NOW
        # 涨薪
        if y > 0:
            sal = min(sal * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
        # 通胀
        if y > 0:
            exp = style['expense'] * (1 + INFLATION) ** y

        # 额外事件
        for event_name, event_age, lump_sum, monthly_add in style['extra_events']:
            if age == event_age:
                asset -= lump_sum
                monthly_extra += monthly_add

        monthly_save = sal - exp - monthly_extra
        asset = asset * (1 + INVEST_RETURN) + monthly_save * 12

        # FIRE检查（用正常自由职业收入）
        real_exp = (total_expense if '你' in style_name else exp + monthly_extra)
        real_exp_annual = real_exp * 12 * (1 + INFLATION) ** y / (1 + INFLATION) ** y  # 已含通胀
        fire_target = (real_exp * 12 - FREELANCE_GOOD * 12) / 0.035

        if asset >= fire_target and fire_age is None and asset > 0:
            fire_age = age

    result = f"{fire_age}岁" if fire_age else "无法达成"
    print(f"  {style_name:25s} → FIRE {result:6s} | 45岁时资产 ¥{asset/10000:,.0f}万")

# ============================
# 详细模拟：你的情况
# ============================
print("\n\n" + "=" * 60)
print("  详细推演：不同自由职业收入 × 不同退休年龄")
print("=" * 60)

def simulate_fire(retire_age, freelance_monthly, expense_monthly=total_expense):
    # 积累阶段
    asset = 0
    sal = SALARY_START
    for y in range(retire_age - AGE_NOW):
        if y > 0:
            sal = min(sal * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
        exp = expense_monthly * (1 + INFLATION) ** y
        asset = asset * (1 + INVEST_RETURN) + (sal - exp) * 12

    # 退休后模拟到85岁
    ages = list(range(retire_age, 86))
    assets = []
    for age in ages:
        yt = age - AGE_NOW
        invest = asset * INVEST_RETURN
        freelance = freelance_monthly * 12  # 开发不衰减
        pension = 3000 * 12 if age >= 60 else 0
        exp_annual = expense_monthly * 12 * (1 + INFLATION) ** yt
        asset += invest + freelance + pension - exp_annual
        assets.append(asset)

    # 找到资产归零的年龄
    broke_age = None
    for i, a in enumerate(assets):
        if a < 0:
            broke_age = ages[i]
            break

    return asset, assets, ages, broke_age, assets[0] if assets else 0

# 打表
print(f"\n  {'退休年龄':>8s} {'积累资产':>10s} | {'自由职业¥3k':>12s} {'自由职业¥5k':>12s} {'自由职业¥8k':>12s}")
print("  " + "-" * 70)

for ra in [32, 33, 34, 35, 36, 37, 38, 40, 42, 45]:
    results = []
    # 退休时资产
    asset_at_retire = 0
    sal = SALARY_START
    for y in range(ra - AGE_NOW):
        if y > 0:
            sal = min(sal * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
        exp = total_expense * (1 + INFLATION) ** y
        asset_at_retire = asset_at_retire * (1 + INVEST_RETURN) + (sal - exp) * 12

    for fl in [3000, 5000, 8000]:
        final, _, _, broke, _ = simulate_fire(ra, fl)
        if broke:
            results.append(f"  {broke}岁花光⚠")
        else:
            results.append(f"  85岁剩¥{final/10000:,.0f}万")

    print(f"  {ra:5d}岁    ¥{asset_at_retire/10000:>7,.0f}万 |{results[0]:>12s}{results[1]:>12s}{results[2]:>12s}")

# ============================
# 退休后详细现金流（35岁退，自由职业5k）
# ============================
print("\n\n" + "=" * 60)
print("  35岁退休 + 自由职业¥5,000/月 → 详细现金流")
print("=" * 60)

retire_age = 35
fl_income = 5000

asset = 0
sal = SALARY_START
for y in range(retire_age - AGE_NOW):
    if y > 0:
        sal = min(sal * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
    exp = total_expense * (1 + INFLATION) ** y
    asset = asset * (1 + INVEST_RETURN) + (sal - exp) * 12

print(f"\n  35岁退休时资产: ¥{asset/10000:,.1f}万")
print(f"  退休后月支出(起始): ¥{total_expense * (1+INFLATION)**10:,.0f} (含通胀)")
print(f"  自由职业: ¥{fl_income:,}/月")

print(f"\n  {'年龄':>4s} {'总资产':>10s} {'投资收益':>8s} {'自由职业':>8s} {'年支出':>8s} {'养老金':>6s} {'东京次数':>6s}")
print("  " + "-" * 65)

for age in range(retire_age, 86):
    yt = age - AGE_NOW
    invest = asset * INVEST_RETURN
    freelance = fl_income * 12
    pension = 3000 * 12 if age >= 60 else 0
    exp_annual = total_expense * 12 * (1 + INFLATION) ** yt

    # 东京旅行占支出比
    tokyo_cost = 18000 * (1 + INFLATION) ** yt
    tokyo_pct = tokyo_cost / exp_annual * 100

    asset += invest + freelance + pension - exp_annual

    if age <= 40 or age % 5 == 0 or age >= 58:
        print(f"  {age:4d}  ¥{asset/10000:>8,.1f}万  ¥{invest/10000:>6,.1f}万  ¥{freelance/10000:>6,.1f}万  ¥{exp_annual/10000:>6,.1f}万  ¥{pension/10000:>4,.1f}万  2次(占{tokyo_pct:.0f}%)")

# ============================
# 敏感性分析
# ============================
print("\n\n" + "=" * 60)
print("  敏感性分析：什么变量影响最大？")
print("=" * 60)

base_final, _, _, _, _ = simulate_fire(35, 5000)

tests = [
    ("基准(35岁退,7%收益,5k自由职业)", 35, 5000, total_expense, 0.07),
    ("投资收益降到5%", 35, 5000, total_expense, 0.05),
    ("投资收益升到9%", 35, 5000, total_expense, 0.09),
    ("自由职业收入=0", 35, 0, total_expense, 0.07),
    ("月支出+2000(租好房)", 35, 5000, total_expense + 2000, 0.07),
    ("月支出-2000(极致省)", 35, 5000, total_expense - 2000, 0.07),
    ("东京改一年一次", 35, 5000, total_expense - 750, 0.07),
    ("东京改一年三次", 35, 5000, total_expense + 750, 0.07),
    ("多工作2年(37岁退)", 37, 5000, total_expense, 0.07),
    ("少工作2年(33岁退)", 33, 5000, total_expense, 0.07),
]

print(f"\n  {'场景':40s} {'85岁资产':>12s} {'vs基准':>10s}")
print("  " + "-" * 65)
for desc, ra, fl, exp, ret in tests:
    # 积累
    a = 0
    s = SALARY_START
    for y in range(ra - AGE_NOW):
        if y > 0:
            s = min(s * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
        e = exp * (1 + INFLATION) ** y
        a = a * (1 + ret) + (s - e) * 12
    # 退休后
    for age in range(ra, 86):
        yt = age - AGE_NOW
        a += a * ret + fl * 12 + (3000*12 if age >= 60 else 0) - exp * 12 * (1+INFLATION)**yt

    diff = a - base_final
    sign = "+" if diff >= 0 else ""
    emoji = "⚠" if a < 0 else ""
    print(f"  {desc:40s}  ¥{a/10000:>9,.0f}万  {sign}{diff/10000:>8,.0f}万 {emoji}")

# ============================
# 画图
# ============================
fig, axes = plt.subplots(2, 2, figsize=(16, 12))

# 图1: 不同退休年龄的资产轨迹
ax = axes[0][0]
for ra, color in [(33, '#e74c3c'), (35, '#2ecc71'), (37, '#3498db'), (40, '#9b59b6')]:
    _, assets_list, ages_list, broke, _ = simulate_fire(ra, 5000)
    ax.plot(ages_list, [a/10000 for a in assets_list], color=color, lw=2, label=f'{ra}岁退休')
ax.axhline(0, color='red', ls='--', lw=1, alpha=0.5)
ax.set_xlabel('年龄')
ax.set_ylabel('资产（万元）')
ax.set_title('不同退休年龄 → 资产轨迹\n(自由职业¥5k/月)', fontsize=13)
ax.legend()
ax.grid(True, alpha=0.3)

# 图2: 不同自由职业收入
ax = axes[0][1]
for fl, label, color in [(0, '无收入', '#e74c3c'), (3000, '¥3k/月', '#f39c12'),
                          (5000, '¥5k/月', '#2ecc71'), (8000, '¥8k/月', '#3498db')]:
    _, assets_list, ages_list, _, _ = simulate_fire(35, fl)
    ax.plot(ages_list, [a/10000 for a in assets_list], color=color, lw=2, label=label)
ax.axhline(0, color='red', ls='--', lw=1, alpha=0.5)
ax.set_xlabel('年龄')
ax.set_ylabel('资产（万元）')
ax.set_title('35岁退休 → 不同自由职业收入的影响', fontsize=13)
ax.legend()
ax.grid(True, alpha=0.3)

# 图3: 三种生活方式对比（积累阶段）
ax = axes[1][0]
for style_name, extra_expense, lump_events, color in [
    ('不婚不房不娃(你)', 0, [], '#2ecc71'),
    ('买房不婚', 8000, [(30, 600000)], '#f39c12'),
    ('买房结婚生娃', 13000, [(30, 600000), (31, 200000)], '#e74c3c'),
]:
    asset_track = []
    a = 0
    s = SALARY_START
    extra = 0
    for age in range(AGE_NOW, 51):
        y = age - AGE_NOW
        if y > 0:
            s = min(s * (1 + (SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW)), SALARY_CAP)
        exp_y = total_expense * (1 + INFLATION) ** y
        for event_age, cost in lump_events:
            if age == event_age:
                a -= cost
            if age >= event_age and extra_expense > 0:
                extra = extra_expense
        a = a * (1 + INVEST_RETURN) + (s - exp_y - extra) * 12
        asset_track.append(a / 10000)
    ax.plot(range(AGE_NOW, 51), asset_track, color=color, lw=2, label=style_name)

ax.set_xlabel('年龄')
ax.set_ylabel('资产（万元）')
ax.set_title('三种生活方式 → 资产积累速度', fontsize=13)
ax.legend()
ax.grid(True, alpha=0.3)

# 图4: 月支出结构饼图
ax = axes[1][1]
labels = list(expenses.keys())
sizes = list(expenses.values())
colors_pie = ['#e74c3c', '#f39c12', '#3498db', '#2ecc71', '#9b59b6', '#1abc9c', '#e67e22', '#95a5a6']
explode = [0.05 if '东京' in l else 0 for l in labels]
wedges, texts, autotexts = ax.pie(sizes, labels=labels, autopct='%1.0f%%',
                                   colors=colors_pie[:len(sizes)], explode=explode,
                                   textprops={'fontsize': 9})
ax.set_title(f'月支出结构 (合计¥{total_expense:,})', fontsize=13)

plt.tight_layout(pad=2)
plt.savefig('output/fire_v2.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: fire_v2.png")
