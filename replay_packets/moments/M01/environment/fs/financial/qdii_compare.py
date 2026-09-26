"""
永久投资组合 - 加入美股QDII基金后的效果对比
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
print("  QDII基金调研 + 加入美股后的组合对比")
print("=" * 60)

# ============================
# 1. 查看支付宝可买的QDII基金
# ============================
print("\n--- 支付宝可买的美国QDII基金 ---\n")

qdii_list = {
    '050025': '博时标普500ETF联接A',
    '161125': '易方达标普500指数A(LOF)',
    '270042': '广发纳斯达克100ETF联接A',
    '160213': '国泰纳斯达克100ETF联接A',
    '000834': '大成纳斯达克100指数A',
    '486001': '工银全球精选',
    '164906': '交银中证海外中国互联网',
    '008763': '天弘越南市场A',  # 非美但有趣
}

qdii_nav = {}
for code, name in qdii_list.items():
    try:
        nav = ak.fund_open_fund_info_em(symbol=code, indicator="累计净值走势")
        nav.columns = ['date', 'nav']
        nav['date'] = pd.to_datetime(nav['date'])
        nav = nav.set_index('date').sort_index()

        latest = nav['nav'].iloc[-1]
        start_date = nav.index[0]
        total_years = (nav.index[-1] - start_date).days / 365.25
        ann = (latest / nav['nav'].iloc[0]) ** (1/total_years) - 1 if total_years > 1 else 0
        dd = ((nav['nav'] - nav['nav'].cummax()) / nav['nav'].cummax()).min()

        info_parts = [f"  {code} {name}"]
        info_parts.append(f"    成立: {start_date.date()}, 共{total_years:.1f}年")
        info_parts.append(f"    年化: {ann:+.1%}, 最大回撤: {dd:.1%}")

        for label, days in [('近1年', 252), ('近3年', 756), ('近5年', 1260)]:
            if len(nav) > days:
                past = nav['nav'].iloc[-days]
                ret = latest / past - 1
                info_parts.append(f"    {label}: {ret:+.1%}")

        print("\n".join(info_parts))
        qdii_nav[name] = nav['nav']
        print()
    except Exception as e:
        print(f"  {code} {name}: 失败 ({str(e)[:50]})\n")

# ============================
# 2. 构建原版永久组合 + 美股版组合
# ============================
print("\n--- 构建对比组合 ---")

# 获取原始数据
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
tr = (by.shift(1)/100/252 - 7.5 * by.diff()/100).dropna().clip(-0.03, 0.03)
bond_idx = (1 + tr).cumprod()

money_rates = {2015:3.5,2016:2.8,2017:3.8,2018:3.5,2019:2.5,
               2020:2.0,2021:2.3,2022:1.8,2023:2.2,2024:1.8,2025:1.5,2026:1.5}

# 选一个历史最长的美股QDII: 博时标普500(050025) 或 易方达标普500(161125)
sp500_qdii = None
sp500_name = None
for name in ['博时标普500ETF联接A', '易方达标普500指数A(LOF)']:
    if name in qdii_nav:
        sp500_qdii = qdii_nav[name]
        sp500_name = name
        break

nasdaq_qdii = None
nasdaq_name = None
for name in ['广发纳斯达克100ETF联接A', '国泰纳斯达克100ETF联接A']:
    if name in qdii_nav:
        nasdaq_qdii = qdii_nav[name]
        nasdaq_name = name
        break

# 合并所有数据
all_raw = pd.DataFrame({
    '沪深300': hs300,
    '黄金': gold_cny,
    '长期国债': bond_idx,
})

if sp500_qdii is not None:
    all_raw['标普500QDII'] = sp500_qdii
if nasdaq_qdii is not None:
    all_raw['纳斯达克QDII'] = nasdaq_qdii

all_raw = all_raw.ffill().dropna()

# 货币基金
cash = pd.Series(index=all_raw.index, dtype=float)
cash.iloc[0] = 1.0
for i in range(1, len(cash)):
    r = money_rates.get(cash.index[i].year, 2.0) / 100 / 365
    cash.iloc[i] = cash.iloc[i-1] * (1+r)
all_raw['货币基金'] = cash

# 归一化
for c in all_raw.columns:
    all_raw[c] = all_raw[c] / all_raw[c].iloc[0]

start = all_raw.index[0]
end = all_raw.index[-1]
yrs = (end - start).days / 365.25
print(f"公共区间: {start.date()} ~ {end.date()} ({yrs:.1f}年)")

# ============================
# 3. 回测不同配置
# ============================
INIT = 10000

def run_backtest(data, weights, name):
    assets = list(weights.keys())
    shares = {a: INIT * weights[a] / data[a].iloc[0] for a in assets}
    vals = []
    check_dates = set(data.resample('YE').last().index)
    for date in data.index:
        total = sum(shares[a] * data.loc[date, a] for a in assets)
        vals.append(total)
        if date in check_dates:
            w = {a: shares[a] * data.loc[date, a] / total for a in assets}
            if any(abs(w[a] - weights[a]) > 0.05 for a in assets):
                for a in assets:
                    shares[a] = total * weights[a] / data.loc[date, a]
    return pd.Series(vals, index=data.index, name=name)

def calc_stats(s, name, years):
    ret = s.iloc[-1]/s.iloc[0] - 1
    ann = (1+ret)**(1/years) - 1
    vol = s.pct_change().dropna().std() * np.sqrt(252)
    dd = ((s - s.cummax()) / s.cummax()).min()
    sharpe = (ann - 0.025) / vol if vol > 0 else 0
    calmar = ann / abs(dd) if dd < 0 else 0
    yr = s.resample('YE').last().pct_change().dropna()
    pos = (yr > 0).sum()
    neg = (yr <= 0).sum()
    worst = yr.min()
    return {
        '名称': name, '年化收益': ann, '年化波动': vol,
        '最大回撤': dd, '夏普': sharpe, 'Calmar': calmar,
        '盈利/亏损年': f"{pos}/{neg}", '最差年': worst,
        '1万终值': s.iloc[-1]/s.iloc[0]*10000,
    }

# 方案列表
portfolios = {}

# A) 纯国内原版
portfolios['A: 纯国内原版'] = run_backtest(all_raw,
    {'沪深300': 0.25, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25},
    'A: 纯国内原版')

# B) 股票部分一半换美股（标普500）
if '标普500QDII' in all_raw.columns:
    portfolios['B: 股票半仓换标普500'] = run_backtest(all_raw,
        {'沪深300': 0.125, '标普500QDII': 0.125, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25},
        'B: 股票半仓换标普500')

# C) 股票全换标普500
if '标普500QDII' in all_raw.columns:
    portfolios['C: 股票全换标普500'] = run_backtest(all_raw,
        {'标普500QDII': 0.25, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25},
        'C: 股票全换标普500')

# D) 股票半仓换纳斯达克
if '纳斯达克QDII' in all_raw.columns:
    portfolios['D: 股票半仓换纳指'] = run_backtest(all_raw,
        {'沪深300': 0.125, '纳斯达克QDII': 0.125, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25},
        'D: 股票半仓换纳指')

# E) A股+美股+黄金+债+现金 (各20%)
if '标普500QDII' in all_raw.columns:
    portfolios['E: 五等分(加美股)'] = run_backtest(all_raw,
        {'沪深300': 0.20, '标普500QDII': 0.20, '黄金': 0.20, '长期国债': 0.20, '货币基金': 0.20},
        'E: 五等分(加美股)')

# F) 纳斯达克替代全部股票
if '纳斯达克QDII' in all_raw.columns:
    portfolios['F: 股票全换纳指'] = run_backtest(all_raw,
        {'纳斯达克QDII': 0.25, '黄金': 0.25, '长期国债': 0.25, '货币基金': 0.25},
        'F: 股票全换纳指')

# ============================
# 4. 输出结果
# ============================
stats_list = [calc_stats(s, name, yrs) for name, s in portfolios.items()]
stats_list.sort(key=lambda x: -x['夏普'])

print("\n" + "=" * 110)
print("                        不同配置方案对比（按夏普排序）")
print("=" * 110)
print(f"{'排名':>3s}  {'方案':28s} {'年化收益':>8s} {'年化波动':>8s} {'最大回撤':>8s} {'夏普':>6s} {'Calmar':>7s} {'最差年':>7s} {'1万终值':>10s}")
print("-" * 110)
for i, s in enumerate(stats_list):
    print(f"{i+1:3d}  {s['名称']:28s} {s['年化收益']:>+7.1%} {s['年化波动']:>7.1%} {s['最大回撤']:>7.1%} {s['夏普']:>6.2f} {s['Calmar']:>7.2f} {s['最差年']:>+6.1%} ¥{s['1万终值']:>9,.0f}")

# 年度对比
print("\n\n" + "=" * 90)
print("  年度收益对比")
print("=" * 90)

key_portfolios = ['A: 纯国内原版']
if 'B: 股票半仓换标普500' in portfolios:
    key_portfolios.append('B: 股票半仓换标普500')
if 'D: 股票半仓换纳指' in portfolios:
    key_portfolios.append('D: 股票半仓换纳指')

yr_data = {}
for name in key_portfolios:
    yr_data[name] = portfolios[name].resample('YE').last().pct_change().dropna()

short = {'A: 纯国内原版': '纯国内', 'B: 股票半仓换标普500': '半仓标普', 'D: 股票半仓换纳指': '半仓纳指'}
print(f"  {'年份':>6s}", end="")
for n in key_portfolios:
    print(f"  {short.get(n,n[:6]):>10s}", end="")
print(f"  {'差值(B-A)':>10s}")
print("  " + "-" * 60)

all_years = sorted(set().union(*[set(v.index) for v in yr_data.values()]))
for d in all_years:
    print(f"  {d.year:>6d}", end="")
    vals = {}
    for n in key_portfolios:
        if d in yr_data[n].index:
            r = yr_data[n][d]
            vals[n] = r
            print(f"  {r:>+9.1%}", end="")
        else:
            print(f"  {'N/A':>10s}", end="")
    # 差值
    if 'A: 纯国内原版' in vals and 'B: 股票半仓换标普500' in vals:
        diff = vals['B: 股票半仓换标普500'] - vals['A: 纯国内原版']
        marker = "✓" if diff > 0 else "✗"
        print(f"  {diff:>+8.1%} {marker}", end="")
    print()

# 相关性分析
print("\n\n" + "=" * 60)
print("  资产相关性矩阵（日收益率）")
print("=" * 60)
rets = all_raw.pct_change().dropna()
corr = rets.corr()
print(corr.round(2).to_string())

# ============================
# 5. 画图
# ============================
fig, axes = plt.subplots(3, 1, figsize=(16, 18))

# 图1: 净值对比
ax = axes[0]
colors_port = {'A: 纯国内原版': 'blue', 'B: 股票半仓换标普500': 'red',
               'C: 股票全换标普500': 'darkred', 'D: 股票半仓换纳指': 'green',
               'E: 五等分(加美股)': 'purple', 'F: 股票全换纳指': 'darkgreen'}
for name, s in portfolios.items():
    lw = 2.5 if name in ['A: 纯国内原版', 'B: 股票半仓换标普500'] else 1
    alpha = 1.0 if name in ['A: 纯国内原版', 'B: 股票半仓换标普500'] else 0.6
    ax.plot(s.index, s/INIT, color=colors_port.get(name, 'gray'), lw=lw, alpha=alpha, label=name)
ax.set_title('不同方案净值对比', fontsize=16, fontweight='bold')
ax.set_ylabel('净值')
ax.legend(fontsize=9, loc='upper left')
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

# 图2: 回撤对比
ax = axes[1]
for name in ['A: 纯国内原版', 'B: 股票半仓换标普500']:
    if name in portfolios:
        s = portfolios[name]
        dd = (s - s.cummax()) / s.cummax()
        ax.fill_between(dd.index, dd.values, 0, alpha=0.3,
                       color=colors_port[name], label=name)
ax.set_title('回撤对比: 纯国内 vs 加入标普500', fontsize=14)
ax.set_ylabel('回撤')
ax.legend(fontsize=11)
ax.grid(True, alpha=0.3)

# 图3: 各资产走势
ax = axes[2]
asset_colors = {'沪深300': '#e74c3c', '标普500QDII': '#c0392b',
                '纳斯达克QDII': '#27ae60', '黄金': '#f1c40f',
                '长期国债': '#3498db', '货币基金': '#95a5a6'}
for col in all_raw.columns:
    if col in asset_colors:
        ax.plot(all_raw.index, all_raw[col], color=asset_colors[col], lw=1.5, label=col)
ax.set_title('各类资产走势', fontsize=14)
ax.set_ylabel('归一化价格')
ax.legend(fontsize=10)
ax.set_yscale('log')
ax.grid(True, alpha=0.3)

plt.tight_layout(pad=2)
plt.savefig('output/qdii_compare.png', dpi=150, bbox_inches='tight')
print(f"\n图表已保存: output/qdii_compare.png")

# QDII注意事项
print("\n\n" + "=" * 60)
print("  QDII基金注意事项")
print("=" * 60)
print("""
  1. 限额问题: QDII基金经常限购（每天限额1000-5000元），
     大额建仓需要分多天买入

  2. 赎回慢: T+7~10个工作日才到账（国内基金T+1~3），
     再平衡时资金周转慢

  3. 汇率影响: QDII基金=美元资产×汇率，人民币升值会侵蚀收益，
     贬值则是额外收益（过去10年人民币贬值，QDII额外受益）

  4. 费率偏高: 管理费通常0.8-1.2%，比国内指数基金(0.15-0.5%)贵

  5. 暂停申购风险: 外汇额度用完时基金会暂停申购，
     可能影响再平衡操作
""")
