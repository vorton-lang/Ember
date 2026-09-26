"""
永久投资组合 vs 市面常见基金/理财 - 10年回测对比
"""

import akshare as ak
import yfinance as yf
import pandas as pd
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import warnings
warnings.filterwarnings('ignore')

plt.rcParams['font.sans-serif'] = ['SimHei', 'Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False

START = "2015-01-05"
END = "2025-12-31"

print("=" * 60)
print("  永久投资组合 vs 市面常见基金  (10年回测)")
print("=" * 60)

# ============================
# 1. 构建永久投资组合
# ============================
print("\n--- 构建永久投资组合 ---")

hs300 = ak.stock_zh_index_daily(symbol="sh000300")
hs300['date'] = pd.to_datetime(hs300['date'])
hs300 = hs300.set_index('date').sort_index()['close']

gold_raw = yf.download("GC=F", start="2014-01-01", end="2026-06-01", progress=False)
if isinstance(gold_raw.columns, pd.MultiIndex):
    gold_raw.columns = gold_raw.columns.get_level_values(0)
gold_usd = gold_raw['Close'].dropna()
gold_usd.index = gold_usd.index.tz_localize(None)

cny_raw = yf.download("CNY=X", start="2014-01-01", end="2026-06-01", progress=False)
if isinstance(cny_raw.columns, pd.MultiIndex):
    cny_raw.columns = cny_raw.columns.get_level_values(0)
usdcny = cny_raw['Close'].dropna()
usdcny.index = usdcny.index.tz_localize(None)

gm = pd.DataFrame({'g': gold_usd, 'f': usdcny}).ffill().dropna()
gold_cny = gm['g'] * gm['f']

bond_raw = ak.bond_zh_us_rate(start_date="2014-01-01")
bond_raw['日期'] = pd.to_datetime(bond_raw['日期'])
bond_raw = bond_raw.set_index('日期').sort_index()
by = bond_raw['中国国债收益率10年'].dropna().astype(float)
by = by[by > 0.5]
DURATION = 7.5
tr = (by.shift(1)/100/252 - DURATION * by.diff()/100).dropna().clip(-0.03, 0.03)
bond_idx = (1 + tr).cumprod()

money_rates = {
    2014:4.5,2015:3.5,2016:2.8,2017:3.8,2018:3.5,2019:2.5,
    2020:2.0,2021:2.3,2022:1.8,2023:2.2,2024:1.8,2025:1.5,2026:1.5
}

pp_data = pd.DataFrame({'沪深300': hs300, '黄金': gold_cny, '长期国债': bond_idx})
pp_data = pp_data.loc[START:END].ffill().dropna()

cash = pd.Series(index=pp_data.index, dtype=float)
cash.iloc[0] = 1.0
for i in range(1, len(cash)):
    r = money_rates.get(cash.index[i].year, 2.0) / 100 / 365
    cash.iloc[i] = cash.iloc[i-1] * (1+r)
pp_data['货币基金'] = cash

for c in pp_data.columns:
    pp_data[c] = pp_data[c] / pp_data[c].iloc[0]

# 运行永久组合
assets = list(pp_data.columns)
INIT = 10000
shares = {a: INIT * 0.25 / pp_data[a].iloc[0] for a in assets}
pp_vals = []
check_dates = set(pp_data.resample('YE').last().index)
for date in pp_data.index:
    total = sum(shares[a] * pp_data.loc[date, a] for a in assets)
    pp_vals.append(total)
    if date in check_dates:
        w = {a: shares[a] * pp_data.loc[date, a] / total for a in assets}
        if any(abs(w[a] - 0.25) > 0.05 for a in assets):
            for a in assets:
                shares[a] = total * 0.25 / pp_data.loc[date, a]

pp_series = pd.Series(pp_vals, index=pp_data.index)
print(f"永久组合: {pp_data.index[0].date()} ~ {pp_data.index[-1].date()}")

# ============================
# 2. 获取对比基金
# ============================
print("\n--- 获取对比基金数据 ---")

fund_list = {
    # 经典长跑冠军
    '163402': '兴全趋势(混合)',
    '110001': '易方达平稳增长(混合)',
    '002001': '华夏回报A(混合)',
    '519697': '交银优势行业(混合)',
    # 偏债稳健
    '110027': '易方达安心回报(偏债)',
    '202101': '南方宝元(偏债)',
    # 纯债
    '000171': '易方达裕丰回报(纯债)',
    # 指数增强
    '110003': '易方达上证50(指数)',
}

fund_nav = {}

for code, name in fund_list.items():
    try:
        print(f"  获取 {name} ({code})...", end="")
        df = ak.fund_open_fund_info_em(symbol=code, indicator="累计净值走势")
        df.columns = ['date', 'nav']
        df['date'] = pd.to_datetime(df['date'])
        df = df.set_index('date').sort_index()
        df = df.loc[START:END, 'nav'].dropna()
        if len(df) > 200:
            fund_nav[name] = df
            print(f" OK ({df.index[0].date()} ~ {df.index[-1].date()}, {len(df)}天)")
        else:
            print(f" 数据不足({len(df)}天), 跳过")
    except Exception as e:
        print(f" 失败: {e}")

# 加入银行理财模拟（年化3.5% → 近年下降到2.5%）
print("  生成银行理财模拟...", end="")
bank_rates = {2015:4.5,2016:4.0,2017:4.5,2018:4.5,2019:4.0,
              2020:3.5,2021:3.2,2022:2.8,2023:2.5,2024:2.2,2025:2.0}
bank = pd.Series(index=pp_data.index, dtype=float)
bank.iloc[0] = 1.0
for i in range(1, len(bank)):
    r = bank_rates.get(bank.index[i].year, 3.0) / 100 / 365
    bank.iloc[i] = bank.iloc[i-1] * (1+r)
fund_nav['银行理财(模拟)'] = bank * INIT
print(" OK")

# 加入纯沪深300
fund_nav['沪深300指数'] = pp_data['沪深300'] * INIT

# ============================
# 3. 对齐 & 归一化
# ============================
print("\n--- 对齐数据 ---")

# 找公共时间窗口
common_start = max(s.index[0] for s in fund_nav.values())
common_start = max(common_start, pp_series.index[0])
common_end = min(s.index[-1] for s in fund_nav.values())
common_end = min(common_end, pp_series.index[-1])

all_nav = pd.DataFrame()
for name, s in fund_nav.items():
    s2 = s.loc[common_start:common_end]
    all_nav[name] = s2

pp_cut = pp_series.loc[common_start:common_end]
all_nav['永久投资组合'] = pp_cut

all_nav = all_nav.ffill().dropna()

# 归一化到1
for c in all_nav.columns:
    all_nav[c] = all_nav[c] / all_nav[c].iloc[0]

yrs = (all_nav.index[-1] - all_nav.index[0]).days / 365.25
print(f"公共区间: {all_nav.index[0].date()} ~ {all_nav.index[-1].date()} ({yrs:.1f}年)")
print(f"对比标的: {len(all_nav.columns)}个\n")

# ============================
# 4. 统计指标
# ============================
def calc(s, name, years):
    ret = s.iloc[-1]/s.iloc[0] - 1
    ann = (1+ret)**(1/years) - 1
    dr = s.pct_change().dropna()
    vol = dr.std() * np.sqrt(252)
    dd_s = (s - s.cummax()) / s.cummax()
    dd = dd_s.min()
    sharpe = (ann - 0.025) / vol if vol > 0 else 0
    calmar = ann / abs(dd) if dd < 0 else 0

    yr = s.resample('YE').last().pct_change().dropna()
    pos = (yr > 0).sum()
    neg = (yr <= 0).sum()
    worst_yr = yr.min()
    best_yr = yr.max()

    # 最大回撤持续时间
    cummax = s.cummax()
    in_dd = s < cummax
    if in_dd.any():
        dd_groups = (in_dd != in_dd.shift()).cumsum()
        dd_durations = in_dd.groupby(dd_groups).sum()
        max_dd_days = int(dd_durations.max())
    else:
        max_dd_days = 0

    return {
        '名称': name,
        '总收益': ret,
        '年化收益': ann,
        '年化波动': vol,
        '最大回撤': dd,
        '回撤恢复(天)': max_dd_days,
        '夏普': sharpe,
        'Calmar': calmar,
        '盈利/亏损年': f"{pos}/{neg}",
        '最差年份': worst_yr,
        '最好年份': best_yr,
        '1万终值': s.iloc[-1]/s.iloc[0]*10000,
    }

all_stats = []
for col in all_nav.columns:
    all_stats.append(calc(all_nav[col], col, yrs))

df_stats = pd.DataFrame(all_stats)
df_stats = df_stats.sort_values('夏普', ascending=False)

# 格式化输出
print("=" * 110)
print("                              10年回测 - 综合排行（按夏普比率排序）")
print("=" * 110)
print(f"{'排名':>3s}  {'名称':20s} {'年化收益':>8s} {'年化波动':>8s} {'最大回撤':>8s} {'夏普':>6s} {'Calmar':>7s} {'胜率':>7s} {'最差年':>7s} {'1万终值':>10s}")
print("-" * 110)
for i, (_, row) in enumerate(df_stats.iterrows()):
    is_pp = '永久' in row['名称']
    marker = " ★" if is_pp else "  "
    print(f"{i+1:3d}{marker} {row['名称']:20s} {row['年化收益']:>+7.1%} {row['年化波动']:>7.1%} {row['最大回撤']:>7.1%} {row['夏普']:>6.2f} {row['Calmar']:>7.2f} {row['盈利/亏损年']:>7s} {row['最差年份']:>+6.1%} ¥{row['1万终值']:>9,.0f}")

# 分类比较
print("\n\n" + "=" * 80)
print("  分类对比分析")
print("=" * 80)

pp_stat = [s for s in all_stats if '永久' in s['名称']][0]

categories = {
    '主动混合基金': ['兴全趋势', '易方达平稳', '华夏回报', '交银优势'],
    '偏债基金': ['易方达安心', '南方宝元'],
    '纯债基金': ['裕丰回报'],
    '指数基金': ['上证50', '沪深300'],
    '固收理财': ['银行理财'],
}

for cat, keywords in categories.items():
    cat_stats = [s for s in all_stats if any(k in s['名称'] for k in keywords)]
    if not cat_stats:
        continue
    print(f"\n  永久投资组合 vs {cat}:")
    print(f"    {'':20s} {'年化':>7s} {'波动':>7s} {'回撤':>7s} {'夏普':>6s}")
    print(f"    {'永久投资组合':20s} {pp_stat['年化收益']:>+6.1%} {pp_stat['年化波动']:>6.1%} {pp_stat['最大回撤']:>6.1%} {pp_stat['夏普']:>6.2f}")
    for s in cat_stats:
        beat_return = "✓" if pp_stat['年化收益'] > s['年化收益'] else "✗"
        beat_sharpe = "✓" if pp_stat['夏普'] > s['夏普'] else "✗"
        beat_dd = "✓" if pp_stat['最大回撤'] > s['最大回撤'] else "✗"
        print(f"    {s['名称']:20s} {s['年化收益']:>+6.1%} {s['年化波动']:>6.1%} {s['最大回撤']:>6.1%} {s['夏普']:>6.2f}  收益{beat_return} 回撤{beat_dd} 夏普{beat_sharpe}")

# 年度对比表
print("\n\n" + "=" * 80)
print("  年度收益对比（永久组合 vs 代表性基金）")
print("=" * 80)

compare_cols = ['永久投资组合']
for name in all_nav.columns:
    if any(k in name for k in ['兴全', '易方达安心', '银行', '沪深300']):
        compare_cols.append(name)

yr_all = {}
for col in compare_cols:
    yr_all[col] = all_nav[col].resample('YE').last().pct_change().dropna()

short_names = {c: c[:8] for c in compare_cols}
print(f"  {'年份':>6s}", end="")
for c in compare_cols:
    print(f"  {short_names[c]:>10s}", end="")
print()
print("  " + "-" * (8 + 12 * len(compare_cols)))

all_years = sorted(set().union(*[set(v.index) for v in yr_all.values()]))
for d in all_years:
    print(f"  {d.year:>6d}", end="")
    for c in compare_cols:
        if d in yr_all[c].index:
            r = yr_all[c][d]
            print(f"  {r:>+9.1%}", end="")
        else:
            print(f"  {'N/A':>10s}", end="")
    print()

# ============================
# 5. 画图
# ============================
fig, axes = plt.subplots(3, 1, figsize=(16, 20))

# 图1: 净值对比
ax = axes[0]
# 永久组合加粗
ax.plot(all_nav.index, all_nav['永久投资组合'], 'r-', lw=3, label='永久投资组合', zorder=10)
# 其他基金
other_colors = plt.cm.tab10(np.linspace(0, 1, len(all_nav.columns)-1))
ci = 0
for col in all_nav.columns:
    if col == '永久投资组合':
        continue
    ax.plot(all_nav.index, all_nav[col], lw=1, alpha=0.6, color=other_colors[ci], label=col)
    ci += 1
ax.set_title('10年净值对比（对数坐标）', fontsize=16, fontweight='bold')
ax.set_ylabel('净值', fontsize=12)
ax.legend(fontsize=9, loc='upper left', ncol=2)
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

# 图2: 风险收益散点图
ax = axes[1]
for s in all_stats:
    is_pp = '永久' in s['名称']
    color = 'red' if is_pp else ('goldenrod' if '债' in s['名称'] or '银行' in s['名称'] else 'steelblue')
    size = 200 if is_pp else 100
    marker = '*' if is_pp else 'o'
    ax.scatter(s['年化波动']*100, s['年化收益']*100, s=size, c=color, marker=marker, zorder=5 if is_pp else 3, edgecolors='black', linewidth=0.5)
    offset = (0.3, 0.3) if not is_pp else (0.5, 0.5)
    ax.annotate(s['名称'][:6], (s['年化波动']*100 + offset[0], s['年化收益']*100 + offset[1]), fontsize=9)

ax.set_xlabel('年化波动率 (%)', fontsize=12)
ax.set_ylabel('年化收益率 (%)', fontsize=12)
ax.set_title('风险-收益散点图（右上角最佳，红星=永久组合）', fontsize=14)
ax.grid(True, alpha=0.3)

# 图3: 最大回撤横向柱状图
ax = axes[2]
sorted_stats = sorted(all_stats, key=lambda x: x['最大回撤'], reverse=True)
names = [s['名称'][:10] for s in sorted_stats]
dd_vals = [s['最大回撤']*100 for s in sorted_stats]
colors_bar = ['red' if '永久' in s['名称'] else ('goldenrod' if '债' in s['名称'] or '银行' in s['名称'] else 'steelblue') for s in sorted_stats]
y_pos = range(len(names))
ax.barh(y_pos, dd_vals, color=colors_bar, alpha=0.8, edgecolor='gray')
ax.set_yticks(y_pos)
ax.set_yticklabels(names, fontsize=10)
ax.set_xlabel('最大回撤 (%)', fontsize=12)
ax.set_title('最大回撤对比（越短越好）', fontsize=14)
ax.grid(True, alpha=0.3, axis='x')
for i, v in enumerate(dd_vals):
    ax.text(v - 1, i, f"{v:.1f}%", va='center', ha='right', fontsize=9, color='white', fontweight='bold')

plt.tight_layout(pad=2)
plt.savefig('output/compare_with_funds.png', dpi=150, bbox_inches='tight')
print(f"\n\n图表已保存: output/compare_with_funds.png")

# 最终结论
print("\n\n" + "=" * 60)
print("  结论")
print("=" * 60)
pp_rank_sharpe = list(df_stats['名称']).index('永久投资组合') + 1
total_count = len(df_stats)
print(f"""
  永久投资组合在 {total_count} 个对比标的中:
  - 夏普比率排名: 第 {pp_rank_sharpe}/{total_count}
  - 年化收益: {pp_stat['年化收益']:+.1%}
  - 最大回撤: {pp_stat['最大回撤']:.1%}
  - 年化波动: {pp_stat['年化波动']:.1%}
""")
