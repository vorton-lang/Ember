import akshare as ak
import pandas as pd
import warnings
warnings.filterwarnings('ignore')

# 更多长债候选
bond_candidates = {
    '003838': '鹏华中债1-3年国债A',
    '006556': '广发中债7-10年国开债A',
    '003376': '广发中债7-10年国开行债券指数A',
    '018973': '鹏扬中债-30年期国债ETF联接A',
    '007539': '富国中债10年期国债ETF联接A',  # 场外10年国债
    '501105': '建信中债3-5年国开行债券指数A',
    '006317': '建信中债1-3年国开行债券指数A',
}

print("长期债券候选:")
for code, name in bond_candidates.items():
    try:
        nav = ak.fund_open_fund_info_em(symbol=code, indicator="累计净值走势")
        nav.columns = ['date', 'nav']
        nav['date'] = pd.to_datetime(nav['date'])
        nav = nav.set_index('date').sort_index()
        latest = nav['nav'].iloc[-1]
        start = nav['nav'].iloc[0]
        start_date = nav.index[0]
        years = (nav.index[-1] - nav.index[0]).days / 365.25
        ann = (latest/start)**(1/years) - 1 if years > 0.5 else 0

        dd = ((nav['nav'] - nav['nav'].cummax()) / nav['nav'].cummax()).min()

        print(f"\n  {code} {name}")
        print(f"    成立: {start_date.date()}, 年化: {ann:+.1%}, 最大回撤: {dd:.1%}")

        for label, days in [('近1年', 252), ('近3年', 756)]:
            if len(nav) > days:
                past = nav['nav'].iloc[-days]
                ret = latest/past - 1
                print(f"    {label}: {ret:+.1%}")

    except Exception as e:
        print(f"\n  {code} {name}: 失败 ({str(e)[:60]})")
