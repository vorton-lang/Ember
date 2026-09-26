"""
哈利·布朗永久投资组合 - 中国本土化回测
全部场外基金，不需要股票账户

模拟标的：
1. 股票 25% → 沪深300指数
2. 黄金 25% → 国际金价(美元) × 汇率 → 人民币金价
3. 长债 25% → 10年期国债收益率 + 久期模型 → 模拟长期债券全价指数
4. 现金 25% → 货币基金历史收益率
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

print("=" * 60)
print("  永久投资组合中国版 - 回测")
print("=" * 60)

# ============================
# 获取数据
# ============================

# 1) 沪深300
print("\n[1/4] 沪深300...")
hs300 = ak.stock_zh_index_daily(symbol="sh000300")
hs300['date'] = pd.to_datetime(hs300['date'])
hs300 = hs300.set_index('date').sort_index()['close']
print(f"  范围: {hs300.index[0].date()} ~ {hs300.index[-1].date()}")

# 2) 黄金 (yfinance: GC=F 国际金价)
print("\n[2/4] 黄金(国际金价+汇率)...")
gold_raw = yf.download("GC=F", start="2005-01-01", end="2026-06-01", progress=False)
if isinstance(gold_raw.columns, pd.MultiIndex):
    gold_raw.columns = gold_raw.columns.get_level_values(0)
gold_usd = gold_raw['Close'].dropna()
gold_usd.index = gold_usd.index.tz_localize(None)
print(f"  金价(USD): {gold_usd.index[0].date()} ~ {gold_usd.index[-1].date()}")

# 汇率
cny_raw = yf.download("CNY=X", start="2005-01-01", end="2026-06-01", progress=False)
if isinstance(cny_raw.columns, pd.MultiIndex):
    cny_raw.columns = cny_raw.columns.get_level_values(0)
usdcny = cny_raw['Close'].dropna()
usdcny.index = usdcny.index.tz_localize(None)
print(f"  汇率: {usdcny.index[0].date()} ~ {usdcny.index[-1].date()}")

gold_merged = pd.DataFrame({'gold': gold_usd, 'fx': usdcny}).ffill().dropna()
gold_cny = gold_merged['gold'] * gold_merged['fx']
print(f"  人民币金价: {gold_cny.index[0].date()} ~ {gold_cny.index[-1].date()}")

# 3) 10年期国债收益率
print("\n[3/4] 10年期国债收益率...")
bond_raw = ak.bond_zh_us_rate(start_date="2005-01-01")
bond_raw['日期'] = pd.to_datetime(bond_raw['日期'])
bond_raw = bond_raw.set_index('日期').sort_index()
print(f"  可用列: {bond_raw.columns.tolist()}")

# 找10年国债列
cn10 = None
for c in bond_raw.columns:
    if '中国国债收益率10年' in c:
        cn10 = c
        break
if cn10 is None:
    for c in bond_raw.columns:
        if '中国' in c and '10' in c:
            cn10 = c
            break
if cn10 is None:
    cn10 = [c for c in bond_raw.columns if '中国' in c][0]

print(f"  选用: {cn10}")
bond_yield = bond_raw[cn10].dropna().astype(float)
bond_yield = bond_yield[bond_yield > 0.5]  # 过滤异常值
print(f"  范围: {bond_yield.index[0].date()} ~ {bond_yield.index[-1].date()}")

# 久期模型 → 长期债券指数
DURATION = 7.5
dy = bond_yield.diff()
carry = bond_yield.shift(1) / 100 / 252
price_ret = -DURATION * dy / 100
total_ret = (carry + price_ret).dropna().clip(-0.03, 0.03)
bond_idx = (1 + total_ret).cumprod()

# 4) 货币基金
print("\n[4/4] 货币基金(历史年化收益)...")
money_rates = {
    2005: 2.2, 2006: 2.5, 2007: 3.0, 2008: 3.5, 2009: 1.8,
    2010: 2.2, 2011: 3.5, 2012: 4.0, 2013: 4.2, 2014: 4.5,
    2015: 3.5, 2016: 2.8, 2017: 3.8, 2018: 3.5, 2019: 2.5,
    2020: 2.0, 2021: 2.3, 2022: 1.8, 2023: 2.2, 2024: 1.8,
    2025: 1.5, 2026: 1.5
}

# ============================
# 合并对齐
# ============================
print("\n" + "-" * 40)
all_series = pd.DataFrame({
    '沪深300': hs300,
    '黄金': gold_cny,
    '长期国债': bond_idx,
}).dropna(how='all').ffill()

# 找所有数据都有值的最早日期
first_valid = all_series.apply(lambda s: s.first_valid_index()).max()
all_series = all_series.loc[first_valid:].dropna()

# 货币基金
cash_series = pd.Series(index=all_series.index, dtype=float)
cash_series.iloc[0] = 1.0
for i in range(1, len(cash_series)):
    y = cash_series.index[i].year
    r = money_rates.get(y, 2.0) / 100 / 365
    cash_series.iloc[i] = cash_series.iloc[i-1] * (1 + r)
all_series['货币基金'] = cash_series

# 归一化
for c in all_series.columns:
    all_series[c] = all_series[c] / all_series[c].iloc[0]

start = all_series.index[0]
end = all_series.index[-1]
yrs = (end - start).days / 365.25
print(f"回测区间: {start.date()} ~ {end.date()} ({yrs:.1f}年)")
print(f"交易日数: {len(all_series)}")

# ============================
# 回测引擎
# ============================
def run_portfolio(data, weights, rebal_freq='Y', rebal_threshold=0.05, initial=10000):
    """
    data: DataFrame, 归一化价格
    weights: dict, 目标权重
    """
    assets = list(weights.keys())
    shares = {a: initial * weights[a] / data[a].iloc[0] for a in assets}
    vals = []
    rebal_log = []
    check_dates = set(data.resample('YE').last().index)

    for date in data.index:
        total = sum(shares[a] * data.loc[date, a] for a in assets)
        vals.append(total)
        if date in check_dates:
            w = {a: shares[a] * data.loc[date, a] / total for a in assets}
            if any(abs(w[a] - weights[a]) > rebal_threshold for a in assets):
                for a in assets:
                    shares[a] = total * weights[a] / data.loc[date, a]
                rebal_log.append((date, w))

    return pd.Series(vals, index=data.index), rebal_log


def calc_metrics(s, name, years):
    ret = s.iloc[-1] / s.iloc[0] - 1
    ann = (1 + ret) ** (1/years) - 1
    dr = s.pct_change().dropna()
    vol = dr.std() * np.sqrt(252)
    dd = ((s - s.cummax()) / s.cummax()).min()
    sharpe = (ann - 0.025) / vol if vol > 0 else 0
    calmar = ann / abs(dd) if dd < 0 else 0
    yr = s.resample('YE').last().pct_change().dropna()
    pos = (yr > 0).sum()
    neg = (yr <= 0).sum()
    return {
        '策略': name,
        '总收益': f"{ret:+.1%}",
        '年化收益': f"{ann:.1%}",
        '年化波动': f"{vol:.1%}",
        '最大回撤': f"{dd:.1%}",
        '夏普': f"{sharpe:.2f}",
        'Calmar': f"{calmar:.2f}",
        '盈利/亏损年': f"{pos}/{neg}",
        '1万终值': f"¥{s.iloc[-1]/s.iloc[0]*10000:,.0f}",
    }

# 永久投资组合
port_w = {'沪深300': 0.25, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25}
portfolio, rebal_log = run_portfolio(all_series, port_w)
portfolio.name = '永久投资组合'

# 对比组合
stock_only, _ = run_portfolio(all_series, {'沪深300': 1.0}, rebal_threshold=99)
gold_only, _ = run_portfolio(all_series, {'黄金': 1.0}, rebal_threshold=99)
balanced, _ = run_portfolio(all_series, {'沪深300': 0.5, '长期国债': 0.3, '货币基金': 0.2})

# ============================
# 输出结果
# ============================
table = [
    calc_metrics(portfolio, '★ 永久投资组合', yrs),
    calc_metrics(stock_only, '  纯沪深300', yrs),
    calc_metrics(gold_only, '  纯黄金', yrs),
    calc_metrics(balanced, '  50/30/20保守', yrs),
]
df = pd.DataFrame(table).set_index('策略')

print("\n" + "=" * 90)
print("                            策略对比汇总")
print("=" * 90)
print(df.to_string())

# 单资产
print("\n\n四类资产单独表现:")
for a in ['沪深300', '黄金', '长期国债', '货币基金']:
    s = all_series[a] * 10000
    m = calc_metrics(s, a, yrs)
    print(f"  {a:6s}: 年化{m['年化收益']:>6s}  波动{m['年化波动']:>6s}  最大回撤{m['最大回撤']:>7s}  1万→{m['1万终值']}")

# 年度收益
print("\n" + "=" * 60)
print("永久投资组合 - 年度收益")
print("=" * 60)
yr_p = portfolio.resample('YE').last().pct_change().dropna()
yr_s = stock_only.resample('YE').last().pct_change().dropna()
for d in yr_p.index:
    rp = yr_p[d]
    rs = yr_s.get(d, 0)
    mark = "▲" if rp >= 0 else "▼"
    bar = "█" * min(int(abs(rp)*100), 50)
    print(f"  {d.year}  {mark} {rp:+6.1%}  {bar:50s}  (沪深300: {rs:+.1%})")

# 滚动收益
print("\n" + "=" * 60)
print("任意持有N年 → 年化收益分布")
print("=" * 60)
for n in [1, 3, 5]:
    w = int(n * 252)
    if len(portfolio) > w:
        roll = (portfolio / portfolio.shift(w)).dropna() ** (1/n) - 1
        lose = (roll < 0).sum() / len(roll)
        print(f"  {n}年: 最差{roll.min():+.1%} | 中位{roll.median():+.1%} | 最好{roll.max():+.1%} | 亏损概率{lose:.0%}")

# 再平衡记录
print(f"\n再平衡 {len(rebal_log)} 次:")
for d, w in rebal_log:
    ws = ", ".join(f"{k}={v:.0%}" for k,v in w.items())
    print(f"  {d.date()} | 平衡前: {ws}")

# ============================
# 画图
# ============================
fig, axes = plt.subplots(4, 1, figsize=(16, 24), gridspec_kw={'height_ratios': [3, 2, 2, 2]})
INIT = 10000

# 图1: 净值对比
ax = axes[0]
ax.plot(portfolio.index, portfolio/INIT, 'r-', lw=2.5, label='永久投资组合', zorder=5)
ax.plot(stock_only.index, stock_only/INIT, 'b-', lw=1, alpha=0.5, label='纯沪深300')
ax.plot(gold_only.index, gold_only/INIT, color='goldenrod', lw=1, alpha=0.5, label='纯黄金')
ax.plot(balanced.index, balanced/INIT, 'g--', lw=1, alpha=0.5, label='50/30/20保守')
for d, _ in rebal_log:
    ax.axvline(d, color='gray', ls=':', alpha=0.3, lw=0.7)
ax.set_title(f'永久投资组合中国版回测 ({start.year}-{end.year})', fontsize=16, fontweight='bold')
ax.set_ylabel('净值（初始=1）', fontsize=12)
ax.legend(fontsize=11, loc='upper left')
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

# 图2: 四类资产
ax = axes[1]
cs = {'沪深300': '#e74c3c', '黄金': '#f1c40f', '长期国债': '#3498db', '货币基金': '#2ecc71'}
for a in ['沪深300', '黄金', '长期国债', '货币基金']:
    ax.plot(all_series.index, all_series[a], color=cs[a], lw=1.5, label=a)
ax.set_title('四类资产走势（归一化=1）', fontsize=14)
ax.set_ylabel('归一化价格', fontsize=12)
ax.legend(fontsize=11)
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

# 图3: 回撤
ax = axes[2]
for s, name, c in [(portfolio, '永久投资组合', 'red'), (stock_only, '纯沪深300', 'blue')]:
    dd = (s - s.cummax()) / s.cummax()
    ax.fill_between(dd.index, dd.values, 0, alpha=0.25, color=c, label=name)
ax.set_title('回撤对比', fontsize=14)
ax.set_ylabel('回撤', fontsize=12)
ax.legend(fontsize=11)
ax.grid(True, alpha=0.3)

# 图4: 年度收益柱状图
ax = axes[3]
common = yr_p.index.intersection(yr_s.index)
x = np.arange(len(common))
w = 0.35
ax.bar(x - w/2, [yr_p[d] for d in common], w, label='永久投资组合', color='indianred', alpha=0.85)
ax.bar(x + w/2, [yr_s[d] for d in common], w, label='纯沪深300', color='steelblue', alpha=0.5)
ax.set_xticks(x)
ax.set_xticklabels([d.year for d in common], rotation=45, fontsize=10)
ax.set_title('年度收益率对比', fontsize=14)
ax.set_ylabel('年度收益率', fontsize=12)
ax.axhline(0, color='black', lw=0.5)
ax.legend(fontsize=11)
ax.grid(True, alpha=0.3, axis='y')

plt.tight_layout(pad=2)
plt.savefig('output/permanent_portfolio_china.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: output/permanent_portfolio_china.png")

# 购买指南
print("\n\n" + "=" * 60)
print("  实际购买清单（全部支付宝可买，无需股票账户）")
print("=" * 60)
print("""
  ┌──────────┬────────────────────────────────┬──────┐
  │ 资产类别  │ 推荐基金                        │ 比例 │
  ├──────────┼────────────────────────────────┼──────┤
  │ 股票     │ 易方达沪深300ETF联接A (110020)   │ 25%  │
  │ 黄金     │ 华安黄金ETF联接A (000216)        │ 25%  │
  │ 长期债券  │ 长期纯债基金（如鹏扬30年国债联接）│ 25%  │
  │ 现金     │ 余额宝 / 天弘余额宝 (000198)    │ 25%  │
  └──────────┴────────────────────────────────┴──────┘

  操作: 每年1月检查，偏离>5%就再平衡
""")
