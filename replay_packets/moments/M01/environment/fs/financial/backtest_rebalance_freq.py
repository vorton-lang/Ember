"""
永久投资组合 - 不同再平衡频率对比
每年 vs 每半年 vs 每季度 vs 每月 vs 不再平衡
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

print("获取数据...")

# 1) 沪深300
hs300 = ak.stock_zh_index_daily(symbol="sh000300")
hs300['date'] = pd.to_datetime(hs300['date'])
hs300 = hs300.set_index('date').sort_index()['close']

# 2) 黄金
gold_raw = yf.download("GC=F", start="2005-01-01", end="2026-06-01", progress=False)
if isinstance(gold_raw.columns, pd.MultiIndex):
    gold_raw.columns = gold_raw.columns.get_level_values(0)
gold_usd = gold_raw['Close'].dropna()
gold_usd.index = gold_usd.index.tz_localize(None)

cny_raw = yf.download("CNY=X", start="2005-01-01", end="2026-06-01", progress=False)
if isinstance(cny_raw.columns, pd.MultiIndex):
    cny_raw.columns = cny_raw.columns.get_level_values(0)
usdcny = cny_raw['Close'].dropna()
usdcny.index = usdcny.index.tz_localize(None)

gm = pd.DataFrame({'g': gold_usd, 'f': usdcny}).ffill().dropna()
gold_cny = gm['g'] * gm['f']

# 3) 国债
bond_raw = ak.bond_zh_us_rate(start_date="2005-01-01")
bond_raw['日期'] = pd.to_datetime(bond_raw['日期'])
bond_raw = bond_raw.set_index('日期').sort_index()
cn10 = '中国国债收益率10年'
by = bond_raw[cn10].dropna().astype(float)
by = by[by > 0.5]
DURATION = 7.5
tr = (by.shift(1)/100/252 - DURATION * by.diff()/100).dropna().clip(-0.03, 0.03)
bond_idx = (1 + tr).cumprod()

# 4) 货币基金
money_rates = {
    2005:2.2,2006:2.5,2007:3.0,2008:3.5,2009:1.8,2010:2.2,
    2011:3.5,2012:4.0,2013:4.2,2014:4.5,2015:3.5,2016:2.8,
    2017:3.8,2018:3.5,2019:2.5,2020:2.0,2021:2.3,2022:1.8,
    2023:2.2,2024:1.8,2025:1.5,2026:1.5
}

# 合并
data = pd.DataFrame({'沪深300': hs300, '黄金': gold_cny, '长期国债': bond_idx})
data = data.dropna(how='all').ffill()
fv = data.apply(lambda s: s.first_valid_index()).max()
data = data.loc[fv:].dropna()

cash = pd.Series(index=data.index, dtype=float)
cash.iloc[0] = 1.0
for i in range(1, len(cash)):
    r = money_rates.get(cash.index[i].year, 2.0) / 100 / 365
    cash.iloc[i] = cash.iloc[i-1] * (1+r)
data['货币基金'] = cash

for c in data.columns:
    data[c] = data[c] / data[c].iloc[0]

start = data.index[0]
end = data.index[-1]
yrs = (end - start).days / 365.25
print(f"回测区间: {start.date()} ~ {end.date()} ({yrs:.1f}年)\n")

assets = ['沪深300', '黄金', '长期国债', '货币基金']
INIT = 10000

# ============================
# 回测引擎（支持不同频率）
# ============================
def backtest(data, freq, threshold=0.05):
    """
    freq: 'Y','6M','Q','M','never'
    """
    shares = {a: INIT * 0.25 / data[a].iloc[0] for a in assets}
    vals = []
    rebal_count = 0

    if freq == 'never':
        check_dates = set()
    elif freq == 'M':
        check_dates = set(data.resample('ME').last().index)
    elif freq == 'Q':
        check_dates = set(data.resample('QE').last().index)
    elif freq == '6M':
        check_dates = set(data.resample('6ME').last().index)
    else:
        check_dates = set(data.resample('YE').last().index)

    for date in data.index:
        total = sum(shares[a] * data.loc[date, a] for a in assets)
        vals.append(total)
        if date in check_dates:
            w = {a: shares[a] * data.loc[date, a] / total for a in assets}
            if any(abs(w[a] - 0.25) > threshold for a in assets):
                for a in assets:
                    shares[a] = total * 0.25 / data.loc[date, a]
                rebal_count += 1

    return pd.Series(vals, index=data.index), rebal_count


def metrics(s, name):
    ret = s.iloc[-1]/s.iloc[0] - 1
    ann = (1+ret)**(1/yrs) - 1
    vol = s.pct_change().dropna().std() * np.sqrt(252)
    dd = ((s - s.cummax()) / s.cummax()).min()
    sharpe = (ann - 0.025) / vol if vol > 0 else 0
    calmar = ann / abs(dd) if dd < 0 else 0
    yr = s.resample('YE').last().pct_change().dropna()
    pos = (yr > 0).sum()
    neg = (yr <= 0).sum()
    return {
        '策略': name,
        '总收益': f"{ret:+.1%}",
        '年化收益': f"{ann:.2%}",
        '年化波动': f"{vol:.2%}",
        '最大回撤': f"{dd:.2%}",
        '夏普': f"{sharpe:.3f}",
        'Calmar': f"{calmar:.3f}",
        '盈利/亏损年': f"{pos}/{neg}",
        '1万终值': f"¥{s.iloc[-1]/s.iloc[0]*10000:,.0f}",
    }

# ============================
# 运行所有频率
# ============================
configs = [
    ('不再平衡', 'never'),
    ('每年', 'Y'),
    ('每半年', '6M'),
    ('每季度', 'Q'),
    ('每月', 'M'),
]

results = {}
stats_list = []

for label, freq in configs:
    s, n = backtest(data, freq)
    results[label] = s
    m = metrics(s, f"{label}（再平衡{n}次）")
    stats_list.append(m)
    print(f"  {label:6s}: 年化{m['年化收益']}  回撤{m['最大回撤']}  夏普{m['夏普']}  再平衡{n}次  1万→{m['1万终值']}")

# 加一个不同阈值的测试
for thresh_pct in [3, 10]:
    s, n = backtest(data, 'Q', threshold=thresh_pct/100)
    m = metrics(s, f"每季度(偏{thresh_pct}%触发, {n}次)")
    stats_list.append(m)
    print(f"  季度/{thresh_pct}%: 年化{m['年化收益']}  回撤{m['最大回撤']}  夏普{m['夏普']}  再平衡{n}次  1万→{m['1万终值']}")

df = pd.DataFrame(stats_list).set_index('策略')
print("\n" + "=" * 100)
print("                              不同再平衡频率对比")
print("=" * 100)
print(df.to_string())

# 年度对比
print("\n\n" + "=" * 70)
print("  各频率年度收益对比")
print("=" * 70)
print(f"  {'年份':6s}", end="")
for label, _ in configs:
    print(f"  {label:>8s}", end="")
print()
print("  " + "-" * 60)

for label, freq in configs:
    results[label].name = label

yr_all = {}
for label in results:
    yr_all[label] = results[label].resample('YE').last().pct_change().dropna()

all_years = sorted(set().union(*[set(v.index) for v in yr_all.values()]))
for d in all_years:
    print(f"  {d.year:6d}", end="")
    for label, _ in configs:
        if d in yr_all[label].index:
            r = yr_all[label][d]
            print(f"  {r:>+7.1%}", end="")
        else:
            print(f"  {'N/A':>8s}", end="")
    print()

# 滚动收益对比
print("\n\n" + "=" * 70)
print("  持有N年年化收益分布对比")
print("=" * 70)
for n in [1, 3, 5]:
    w = int(n * 252)
    print(f"\n  持有 {n} 年:")
    for label, _ in configs:
        s = results[label]
        if len(s) > w:
            roll = (s / s.shift(w)).dropna() ** (1/n) - 1
            lose = (roll < 0).sum() / len(roll)
            print(f"    {label:6s}: 最差{roll.min():+.1%} | 中位{roll.median():+.1%} | 最好{roll.max():+.1%} | 亏损概率{lose:.0%}")

# ============================
# 画图
# ============================
fig, axes = plt.subplots(3, 1, figsize=(16, 18))

# 图1: 净值对比
ax = axes[0]
colors_map = {'不再平衡': 'gray', '每年': 'blue', '每半年': 'green', '每季度': 'red', '每月': 'orange'}
for label, _ in configs:
    s = results[label]
    lw = 2.5 if label == '每季度' else 1.2
    alpha = 1.0 if label in ['每季度', '每年', '不再平衡'] else 0.7
    ax.plot(s.index, s/INIT, color=colors_map[label], lw=lw, alpha=alpha, label=label)
ax.set_title('不同再平衡频率 - 净值对比', fontsize=16, fontweight='bold')
ax.set_ylabel('净值（初始=1）', fontsize=12)
ax.legend(fontsize=12)
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

# 图2: 回撤对比
ax = axes[1]
for label in ['不再平衡', '每年', '每季度']:
    s = results[label]
    dd = (s - s.cummax()) / s.cummax()
    ax.fill_between(dd.index, dd.values, 0, alpha=0.2, color=colors_map[label], label=label)
    ax.plot(dd.index, dd.values, color=colors_map[label], lw=0.8)
ax.set_title('回撤对比（不再平衡 vs 每年 vs 每季度）', fontsize=14)
ax.set_ylabel('回撤', fontsize=12)
ax.legend(fontsize=12)
ax.grid(True, alpha=0.3)

# 图3: 年度收益差异（每季度 - 每年）
ax = axes[2]
common_years = yr_all['每季度'].index.intersection(yr_all['每年'].index)
diff = yr_all['每季度'].loc[common_years] - yr_all['每年'].loc[common_years]
colors_bar = ['#2ecc71' if d >= 0 else '#e74c3c' for d in diff.values]
x = np.arange(len(common_years))
ax.bar(x, diff.values, color=colors_bar, alpha=0.8)
ax.set_xticks(x)
ax.set_xticklabels([d.year for d in common_years], rotation=45, fontsize=10)
ax.set_title('每季度 vs 每年 → 年度收益差值（绿=季度更好）', fontsize=14)
ax.set_ylabel('收益率差值', fontsize=12)
ax.axhline(0, color='black', lw=0.5)
ax.grid(True, alpha=0.3, axis='y')

plt.tight_layout(pad=2)
plt.savefig('output/rebalance_frequency_compare.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: output/rebalance_frequency_compare.png")
