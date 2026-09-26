"""
FIRE 蒙特卡洛模拟 — 序列收益风险分析
用随机收益序列替代固定年化，测试组合在真实波动下的生存概率

收益参数基于永久投资组合中国版的历史表现:
  年化收益 ~7%, 年化波动 ~8-10%, 非正态(略有负偏)
"""
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False

np.random.seed(42)

# ============================
# 参数
# ============================
AGE_NOW = 25
SALARY_START = 18000
SALARY_GROWTH_FAST = 0.08
SALARY_GROWTH_SLOW = 0.04
SALARY_CAP = 40000
EXPENSE_MONTHLY = 8000
INFLATION = 0.03

FREELANCE_MONTHLY = 5000
PENSION_MONTHLY = 3000
PENSION_AGE = 60

# 永久组合历史特征（年度）
RETURN_MEAN = 0.07
RETURN_STD = 0.10
RETURN_SKEW = -0.3  # 略有负偏：坏年份比好年份更极端

N_SIMULATIONS = 10000
END_AGE = 85

# ============================
# 工具函数
# ============================

def generate_annual_returns(n_years, n_sims):
    """生成带负偏的年度收益序列（对数正态 + 偏度修正）"""
    raw = np.random.normal(0, 1, (n_sims, n_years))
    # 引入负偏：用 chi-squared 调整
    skew_adj = (raw**3 - raw) * RETURN_SKEW / 6
    z = raw + skew_adj
    returns = RETURN_MEAN + RETURN_STD * z
    return returns


def accumulate(retire_age):
    """积累阶段：工作到 retire_age，返回退休时资产（确定性）"""
    asset = 0
    sal = SALARY_START
    for y in range(retire_age - AGE_NOW):
        if y > 0:
            rate = SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW
            sal = min(sal * (1 + rate), SALARY_CAP)
        exp = EXPENSE_MONTHLY * (1 + INFLATION) ** y
        asset = asset * (1 + RETURN_MEAN) + (sal - exp) * 12
    return asset


def simulate_retirement(asset_at_retire, retire_age, n_sims, strategy='fixed'):
    """
    退休后蒙特卡洛模拟

    strategy:
      'fixed'   — 每年提取固定金额（通胀调整）
      'dynamic' — 护栏策略：资产低于阈值时削减支出，高于阈值时小幅放宽
      'buffer'  — 退休前3年逐步从股债转向现金，熊市不卖投资仓位
    """
    n_years = END_AGE - retire_age
    returns = generate_annual_returns(n_years, n_sims)

    assets = np.zeros((n_sims, n_years + 1))
    assets[:, 0] = asset_at_retire

    # 动态策略：追踪通胀调整后的初始资产（护栏基准线）
    floor_asset = asset_at_retire

    # 缓冲策略：不预提现金，而是追踪"缓冲额度"
    if strategy == 'buffer':
        buffer_years = 2
        yt0 = retire_age - AGE_NOW
        cash_buffer = np.zeros(n_sims)  # 从 0 开始积累

    for t in range(n_years):
        age = retire_age + t
        yt = age - AGE_NOW

        base_expense = EXPENSE_MONTHLY * 12 * (1 + INFLATION) ** yt
        freelance = FREELANCE_MONTHLY * 12
        pension = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0

        net_expense = base_expense - freelance - pension
        net_expense = max(net_expense, 0)

        if strategy == 'fixed':
            withdrawal = np.full(n_sims, net_expense)

        elif strategy == 'dynamic':
            # 护栏策略：根据当前资产 vs 通胀调整后的初始资产来调节
            floor_now = floor_asset * (1 + INFLATION) ** t
            ratio = assets[:, t] / floor_now

            scale = np.where(
                ratio < 0.8, 0.7,           # 资产跌破初始的80% → 砍30%支出
                np.where(ratio < 0.9, 0.85,  # 跌破90% → 砍15%
                np.where(ratio > 1.5, 1.10,  # 涨超50% → 放宽10%（保守放宽）
                         1.0)))
            withdrawal = net_expense * scale

        elif strategy == 'buffer':
            # 市场上涨年份：正常从投资组合提取 + 顺带补充缓冲
            # 市场下跌年份：优先从缓冲提取，减少卖出投资
            buffer_target = net_expense * buffer_years

            if t == 0:
                # 第一年正常提取
                withdrawal = np.full(n_sims, net_expense)
            else:
                market_down = returns[:, t] < 0

                # 下跌时：从缓冲出
                from_buffer = np.where(
                    market_down,
                    np.minimum(net_expense, cash_buffer),
                    0)
                from_portfolio = net_expense - from_buffer
                cash_buffer -= from_buffer

                # 上涨时：正常提取 + 补缓冲（上限为组合的2%）
                refill = np.where(
                    ~market_down & (cash_buffer < buffer_target),
                    np.minimum(assets[:, t] * 0.02, buffer_target - cash_buffer),
                    0)
                cash_buffer += refill

                withdrawal = from_portfolio + refill

        invest_return = assets[:, t] * returns[:, t]
        assets[:, t + 1] = assets[:, t] + invest_return - withdrawal
        assets[:, t + 1] = np.maximum(assets[:, t + 1], 0)

    return assets


# ============================
# 主模拟
# ============================
print("=" * 60)
print("  FIRE 蒙特卡洛模拟 — 序列收益风险分析")
print("=" * 60)
print(f"\n  模拟次数: {N_SIMULATIONS:,}")
print(f"  收益参数: 均值 {RETURN_MEAN:.0%}, 波动 {RETURN_STD:.0%}, 偏度 {RETURN_SKEW}")
print(f"  模拟终点: {END_AGE}岁")

retire_ages = [33, 35, 37, 40]
strategies = ['fixed', 'dynamic', 'buffer']
strategy_names = {'fixed': '固定提取', 'dynamic': '动态提取', 'buffer': '现金缓冲'}

results = {}

for ra in retire_ages:
    asset_at_retire = accumulate(ra)
    print(f"\n  {ra}岁退休，积累资产: ¥{asset_at_retire/10000:,.1f}万")

    for strat in strategies:
        assets = simulate_retirement(asset_at_retire, ra, N_SIMULATIONS, strat)
        n_years = END_AGE - ra

        # 破产 = 任意年份资产归零
        depleted = np.any(assets[:, 1:] <= 0, axis=1)
        survival_rate = 1 - depleted.mean()
        final_assets = assets[:, -1]

        # 逐年存活率
        annual_survival = np.array([
            1 - np.mean(np.any(assets[:, 1:t+1] <= 0, axis=1))
            for t in range(1, n_years + 1)
        ])

        results[(ra, strat)] = {
            'assets': assets,
            'survival_rate': survival_rate,
            'final_assets': final_assets,
            'annual_survival': annual_survival,
            'asset_at_retire': asset_at_retire,
        }

# ============================
# 输出：存活率总表
# ============================
print("\n\n" + "=" * 70)
print("  组合存活率（到85岁不归零的概率）")
print("=" * 70)
print(f"\n  {'退休年龄':>8s} | {'固定提取':>10s} {'动态提取':>10s} {'现金缓冲':>10s} | {'退休资产':>10s}")
print("  " + "-" * 65)

for ra in retire_ages:
    rates = [results[(ra, s)]['survival_rate'] for s in strategies]
    asset = results[(ra, 'fixed')]['asset_at_retire']
    marks = ['✓' if r >= 0.95 else '△' if r >= 0.85 else '✗' for r in rates]
    print(f"  {ra:5d}岁   | {marks[0]} {rates[0]:>7.1%}   {marks[1]} {rates[1]:>7.1%}   {marks[2]} {rates[2]:>7.1%}   | ¥{asset/10000:>8,.1f}万")

print("""
  ✓ ≥95% 安全    △ 85-95% 需关注    ✗ <85% 危险
""")

# ============================
# 输出：85岁终值分布
# ============================
print("=" * 70)
print("  85岁终值分布（固定提取策略）")
print("=" * 70)
print(f"\n  {'退休年龄':>8s} | {'P5(最差)':>10s} {'P25':>10s} {'中位数':>10s} {'P75':>10s} {'P95(最好)':>10s}")
print("  " + "-" * 65)

for ra in retire_ages:
    fa = results[(ra, 'fixed')]['final_assets']
    fa_alive = fa[fa > 0]
    if len(fa_alive) > 0:
        pcts = np.percentile(fa_alive, [5, 25, 50, 75, 95])
        print(f"  {ra:5d}岁   | ¥{pcts[0]/10000:>7,.0f}万 ¥{pcts[1]/10000:>7,.0f}万 ¥{pcts[2]/10000:>7,.0f}万 ¥{pcts[3]/10000:>7,.0f}万 ¥{pcts[4]/10000:>7,.0f}万")
    else:
        print(f"  {ra:5d}岁   | 全部破产")

# ============================
# 输出：序列收益风险演示
# ============================
print("\n\n" + "=" * 70)
print("  序列收益风险：同样的收益、不同的顺序")
print("=" * 70)

retire_age_demo = 35
asset_demo = accumulate(retire_age_demo)
n_years_demo = END_AGE - retire_age_demo

# 取一组30年收益
demo_returns = generate_annual_returns(n_years_demo, 1)[0]
sorted_good = np.sort(demo_returns)[::-1]  # 好年份在前
sorted_bad = np.sort(demo_returns)          # 坏年份在前

print(f"\n  使用同一组 {n_years_demo} 年收益率（算术平均 {demo_returns.mean():.1%}）")
print(f"  退休资产: ¥{asset_demo/10000:,.1f}万\n")

for label, rets in [("好年份在前", sorted_good), ("坏年份在前", sorted_bad), ("随机顺序", demo_returns)]:
    asset = asset_demo
    for t in range(n_years_demo):
        age = retire_age_demo + t
        yt = age - AGE_NOW
        expense = EXPENSE_MONTHLY * 12 * (1 + INFLATION) ** yt
        freelance = FREELANCE_MONTHLY * 12
        pension = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0
        net = expense - freelance - pension
        asset = asset * (1 + rets[t]) - net
        if asset < 0:
            print(f"  {label}: {age}岁破产 ✗")
            asset = -1
            break
    if asset >= 0:
        print(f"  {label}: 85岁剩余 ¥{asset/10000:,.0f}万 ✓")

# ============================
# 输出：安全提取率分析
# ============================
print("\n\n" + "=" * 70)
print("  安全提取率分析（35岁退休）")
print("=" * 70)

retire_age_swr = 35
asset_swr = accumulate(retire_age_swr)
n_years_swr = END_AGE - retire_age_swr

print(f"\n  退休资产: ¥{asset_swr/10000:,.1f}万")
print(f"  含自由职业 ¥{FREELANCE_MONTHLY:,}/月\n")
print(f"  {'提取率':>6s} {'月支出':>8s} {'存活率':>8s} {'建议':>6s}")
print("  " + "-" * 40)

for swr in [0.025, 0.030, 0.035, 0.040, 0.045, 0.050]:
    monthly_from_portfolio = asset_swr * swr / 12
    total_monthly = monthly_from_portfolio + FREELANCE_MONTHLY
    # 模拟
    returns = generate_annual_returns(n_years_swr, N_SIMULATIONS)
    assets_sim = np.zeros((N_SIMULATIONS, n_years_swr + 1))
    assets_sim[:, 0] = asset_swr

    for t in range(n_years_swr):
        age = retire_age_swr + t
        withdrawal = asset_swr * swr * (1 + INFLATION) ** t
        pension = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0
        net = withdrawal - pension
        assets_sim[:, t + 1] = assets_sim[:, t] * (1 + returns[:, t]) - net
        assets_sim[:, t + 1] = np.maximum(assets_sim[:, t + 1], 0)

    depleted = np.any(assets_sim[:, 1:] <= 0, axis=1)
    surv = 1 - depleted.mean()
    mark = "✓ 安全" if surv >= 0.95 else "△ 勉强" if surv >= 0.90 else "✗ 危险"
    print(f"  {swr:>5.1%}  ¥{total_monthly:>7,.0f}  {surv:>7.1%}  {mark}")

# ============================
# 输出：弹性支出对FIRE的影响
# ============================
print("\n\n" + "=" * 70)
print("  弹性支出对 FIRE 的影响")
print("=" * 70)
print("""
  弹性支出：电脑换新、AI订阅、兴趣爱好、大额消费等
  按月均摊计入支出，测试不同弹性支出水平的影响
""")

FLEX_LEVELS = [0, 1000, 2000, 3000]
flex_results = {}

def accumulate_with_flex(retire_age, flex_monthly):
    asset = 0
    sal = SALARY_START
    for y in range(retire_age - AGE_NOW):
        if y > 0:
            rate = SALARY_GROWTH_FAST if y <= 5 else SALARY_GROWTH_SLOW
            sal = min(sal * (1 + rate), SALARY_CAP)
        exp = (EXPENSE_MONTHLY + flex_monthly) * (1 + INFLATION) ** y
        asset = asset * (1 + RETURN_MEAN) + (sal - exp) * 12
    return asset

print(f"  {'弹性支出':>8s} {'覆盖内容':20s} | {'35岁资产':>8s} {'固定':>7s} {'动态':>7s} | {'37岁资产':>8s} {'固定':>7s} {'动态':>7s} | {'95%安全退休年龄':>14s}")
print("  " + "-" * 110)

flex_labels = {
    0: '无',
    1000: 'AI订阅+零碎',
    2000: '+音乐设备均摊',
    3000: '+娃娃/电脑均摊',
}

for flex in FLEX_LEVELS:
    row_data = {}
    safe_age = None

    for ra in [35, 37]:
        asset = accumulate_with_flex(ra, flex)
        n_years = END_AGE - ra

        for strat in ['fixed', 'dynamic']:
            assets_sim = simulate_retirement(asset, ra, N_SIMULATIONS, strat)
            depleted = np.any(assets_sim[:, 1:] <= 0, axis=1)
            surv = 1 - depleted.mean()
            row_data[(ra, strat)] = (asset, surv)

    # 找到动态提取达到95%存活率的最低退休年龄
    for test_age in range(33, 46):
        a = accumulate_with_flex(test_age, flex)
        if a <= 0:
            continue
        sim = simulate_retirement(a, test_age, N_SIMULATIONS, 'dynamic')
        dep = np.any(sim[:, 1:] <= 0, axis=1)
        s = 1 - dep.mean()
        if s >= 0.95:
            safe_age = test_age
            break

    a35, s35f = row_data[(35, 'fixed')]
    _, s35d = row_data[(35, 'dynamic')]
    a37, s37f = row_data[(37, 'fixed')]
    _, s37d = row_data[(37, 'dynamic')]
    safe_str = f"{safe_age}岁" if safe_age else ">45岁"

    flex_results[flex] = {
        'safe_age': safe_age,
        'a35': a35, 's35f': s35f, 's35d': s35d,
        'a37': a37, 's37f': s37f, 's37d': s37d,
    }

    print(f"  +¥{flex:<5,} {flex_labels[flex]:20s} | ¥{a35/10000:>5,.0f}万 {s35f:>6.0%} {s35d:>6.0%} | ¥{a37/10000:>5,.0f}万 {s37f:>6.0%} {s37d:>6.0%} | {safe_str:>10s}")

# 弹性支出的时间成本
print(f"""
  解读（动态提取策略）：
    +¥1,000/月 → 95%安全退休年龄从 {flex_results[0]['safe_age']}岁 推迟到 {flex_results[1000]['safe_age']}岁（+{flex_results[1000]['safe_age'] - flex_results[0]['safe_age']}年）
    +¥2,000/月 → 推迟到 {flex_results[2000]['safe_age']}岁（+{flex_results[2000]['safe_age'] - flex_results[0]['safe_age']}年）
    +¥3,000/月 → 推迟到 {flex_results[3000]['safe_age']}岁（+{flex_results[3000]['safe_age'] - flex_results[0]['safe_age']}年）

  每 ¥1,000/月弹性支出 ≈ 多工作 ~{(flex_results[3000]['safe_age'] - flex_results[0]['safe_age']) / 3:.0f} 年
  等价换算: 一个 ¥8,000 的大额消费 ≈ 多工作 {8000/SALARY_START:.1f} 个月
""")

# ============================
# 画图
# ============================
fig, axes = plt.subplots(2, 3, figsize=(20, 12))

# 图1: 存活率曲线（不同退休年龄，固定提取）
ax = axes[0][0]
colors = {'33': '#e74c3c', '35': '#f39c12', '37': '#2ecc71', '40': '#3498db'}
for ra in retire_ages:
    data = results[(ra, 'fixed')]
    ages_plot = list(range(ra + 1, END_AGE + 1))
    ax.plot(ages_plot, data['annual_survival'] * 100,
            lw=2, label=f'{ra}岁退休', color=colors[str(ra)])
ax.axhline(95, color='green', ls='--', lw=1, alpha=0.5, label='95%安全线')
ax.axhline(85, color='orange', ls='--', lw=1, alpha=0.5, label='85%警戒线')
ax.set_xlabel('年龄')
ax.set_ylabel('存活率 (%)')
ax.set_title('不同退休年龄 → 组合存活率\n(固定提取策略)', fontsize=13)
ax.legend(fontsize=9)
ax.grid(True, alpha=0.3)
ax.set_ylim(50, 101)

# 图2: 三种策略对比（35岁退休）
ax = axes[0][1]
strat_colors = {'fixed': '#e74c3c', 'dynamic': '#2ecc71', 'buffer': '#3498db'}
for strat in strategies:
    data = results[(35, strat)]
    ages_plot = list(range(36, END_AGE + 1))
    ax.plot(ages_plot, data['annual_survival'] * 100,
            lw=2, label=strategy_names[strat], color=strat_colors[strat])
ax.axhline(95, color='green', ls='--', lw=1, alpha=0.5)
ax.set_xlabel('年龄')
ax.set_ylabel('存活率 (%)')
ax.set_title('35岁退休 → 三种提取策略对比', fontsize=13)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.3)
ax.set_ylim(50, 101)

# 图3: 弹性支出 vs 存活率
ax = axes[0][2]
flex_x = [f'+{f:,}元' for f in FLEX_LEVELS]
x_pos = np.arange(len(FLEX_LEVELS))
w = 0.2
for i, (ra, color) in enumerate([(35, '#f39c12'), (37, '#2ecc71')]):
    fixed_bars = [flex_results[f][f's{ra}f'] * 100 for f in FLEX_LEVELS]
    dynamic_bars = [flex_results[f][f's{ra}d'] * 100 for f in FLEX_LEVELS]
    ax.bar(x_pos + (i*2 - 1.5) * w, fixed_bars, w, color=color, alpha=0.4,
           label=f'{ra}岁固定')
    ax.bar(x_pos + (i*2 - 0.5) * w, dynamic_bars, w, color=color, alpha=0.85,
           label=f'{ra}岁动态')
ax.axhline(95, color='green', ls='--', lw=1, alpha=0.5)
ax.set_xticks(x_pos)
ax.set_xticklabels(flex_x)
ax.set_xlabel('每月弹性支出')
ax.set_ylabel('存活率 (%)')
ax.set_title('弹性支出 → 存活率影响', fontsize=13)
ax.legend(fontsize=8)
ax.grid(True, alpha=0.3, axis='y')
ax.set_ylim(30, 105)

# 图4: 资产轨迹扇面图（35岁退休，固定提取）
ax = axes[1][0]
data = results[(35, 'fixed')]
assets_all = data['assets']
ages_plot = list(range(35, END_AGE + 1))

pct_bands = [(5, 95, 0.15), (10, 90, 0.2), (25, 75, 0.3)]
for lo, hi, alpha in pct_bands:
    lo_line = np.percentile(assets_all, lo, axis=0) / 10000
    hi_line = np.percentile(assets_all, hi, axis=0) / 10000
    ax.fill_between(ages_plot, lo_line, hi_line, alpha=alpha, color='steelblue',
                    label=f'P{lo}-P{hi}' if alpha == 0.15 else None)

median_line = np.median(assets_all, axis=0) / 10000
ax.plot(ages_plot, median_line, 'b-', lw=2, label='中位数')

rng = np.random.default_rng(123)
sample_idx = rng.choice(N_SIMULATIONS, 5, replace=False)
for idx in sample_idx:
    ax.plot(ages_plot, assets_all[idx] / 10000, lw=0.5, alpha=0.4, color='gray')

ax.axhline(0, color='red', ls='--', lw=1)
ax.set_xlabel('年龄')
ax.set_ylabel('资产（万元）')
ax.set_title('35岁退休 → 资产轨迹分布\n(固定提取, 灰线=随机样本)', fontsize=13)
ax.legend(fontsize=9, loc='upper right')
ax.grid(True, alpha=0.3)

# 图5: 序列风险演示
ax = axes[1][1]
for label, rets, color, ls in [
    ("好→坏", sorted_good, '#2ecc71', '-'),
    ("坏→好", sorted_bad, '#e74c3c', '-'),
    ("随机", demo_returns, '#3498db', '--'),
]:
    asset = asset_demo
    trajectory = [asset / 10000]
    for t in range(n_years_demo):
        age = retire_age_demo + t
        yt = age - AGE_NOW
        expense = EXPENSE_MONTHLY * 12 * (1 + INFLATION) ** yt
        freelance = FREELANCE_MONTHLY * 12
        pension = PENSION_MONTHLY * 12 if age >= PENSION_AGE else 0
        net = expense - freelance - pension
        asset = asset * (1 + rets[t]) - net
        trajectory.append(max(asset, 0) / 10000)
    ax.plot(range(retire_age_demo, END_AGE + 1), trajectory,
            color=color, ls=ls, lw=2, label=label)

ax.axhline(0, color='red', ls='--', lw=1)
ax.set_xlabel('年龄')
ax.set_ylabel('资产（万元）')
ax.set_title('序列收益风险演示\n(同一组收益率，不同到来顺序)', fontsize=13)
ax.legend(fontsize=10)
ax.grid(True, alpha=0.3)

# 图6: 弹性支出 vs 安全退休年龄
ax = axes[1][2]
safe_ages = [flex_results[f]['safe_age'] for f in FLEX_LEVELS]
bar_colors = ['#2ecc71' if a and a <= 37 else '#f39c12' if a and a <= 40 else '#e74c3c'
              for a in safe_ages]
ax.bar(x_pos, safe_ages, 0.5, color=bar_colors)
ax.set_xticks(x_pos)
ax.set_xticklabels(flex_x)
ax.set_xlabel('每月弹性支出')
ax.set_ylabel('退休年龄')
ax.set_title('弹性支出 → 95%安全退休年龄\n(动态提取策略)', fontsize=13)
for i, (age, f) in enumerate(zip(safe_ages, FLEX_LEVELS)):
    if age:
        delay = age - safe_ages[0] if safe_ages[0] else 0
        label = f'{age}岁' + (f' (+{delay})' if delay > 0 else '')
        ax.text(i, age + 0.2, label, ha='center', fontsize=11, fontweight='bold')
ax.set_ylim(30, max(safe_ages) + 3 if all(safe_ages) else 50)
ax.grid(True, alpha=0.3, axis='y')

plt.tight_layout(pad=2)
plt.savefig('output/fire_monte_carlo.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: output/fire_monte_carlo.png")

# ============================
# 结论
# ============================
surv_35_fixed = results[(35, 'fixed')]['survival_rate']
surv_35_dynamic = results[(35, 'dynamic')]['survival_rate']
surv_35_buffer = results[(35, 'buffer')]['survival_rate']
surv_37_fixed = results[(37, 'fixed')]['survival_rate']

print("\n\n" + "=" * 60)
print("  关键结论")
print("=" * 60)
surv_37_dynamic = results[(37, 'dynamic')]['survival_rate']
print(f"""
  1. 固定7%年化的FIRE测算过于乐观
     35岁退休 + 固定提取，真实存活率只有 {surv_35_fixed:.0%}
     （而非固定收益模型暗示的"100%安全"）

  2. 护栏式动态提取是最有效的风险对冲
     35岁退休: 固定 {surv_35_fixed:.0%} → 动态 {surv_35_dynamic:.0%}
     37岁退休: 固定 {surv_37_fixed:.0%} → 动态 {surv_37_dynamic:.0%}
     规则：资产跌破初始值80%时砍30%支出，跌破90%砍15%

  3. 现金缓冲在此模型中效果有限（{surv_35_buffer:.0%}）
     原因：补充缓冲的额外提取抵消了熊市保护效果
     实操中可结合动态提取一起使用

  4. 多工作2年的安全边际极大
     37岁退休 + 动态提取存活率 {surv_37_dynamic:.0%}
     多2年积累 + 少2年消耗 + 动态策略 = 三重保险

  5. 行动建议
     - 采用护栏式动态提取（资产低于阈值时主动削减支出）
     - 退休后前5年是最脆弱的窗口，前5年支出尽量保守
     - 每年检查一次资产 vs 通胀调整后的初始资产，据此调整
     - 35岁退休需要承受约1/4概率的破产风险，37岁显著更安全
""")
