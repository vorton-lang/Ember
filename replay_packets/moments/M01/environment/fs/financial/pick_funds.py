"""
在支付宝可买的基金中，为永久投资组合挑选最优标的
"""
import akshare as ak
import pandas as pd
import warnings
warnings.filterwarnings('ignore')

# 候选基金列表
candidates = {
    '股票(沪深300联接)': {
        '110020': '易方达沪深300ETF联接A',
        '160706': '嘉实沪深300ETF联接A',
        '000961': '天弘沪深300ETF联接A',
        '002987': '广发沪深300ETF联接A',
    },
    '黄金(黄金ETF联接)': {
        '000216': '华安黄金ETF联接A',
        '002610': '博时黄金ETF联接A',
        '000307': '易方达黄金ETF联接A',
        '001630': '天弘黄金ETF联接A',  # 天弘系支付宝亲儿子
    },
    '长期债券': {
        '019549': '鹏扬30年国债ETF联接A',
        '000171': '易方达裕丰回报债券',
        '003358': '易方达裕祥回报债券',
        '002491': '建信中国政策性银行债A',
        '007004': '民生加银中债1-3年农发债A',
    },
    '现金': {
        '000198': '天弘余额宝',
        '004137': '博时合惠货币B',
    },
}

print("=" * 80)
print("  支付宝可买基金 - 候选基金详情")
print("=" * 80)

for category, funds in candidates.items():
    print(f"\n{'='*60}")
    print(f"  {category}")
    print(f"{'='*60}")

    for code, name in funds.items():
        try:
            # 获取基金基本信息
            info = ak.fund_individual_basic_info_xq(symbol=code)
            info_dict = dict(zip(info.iloc[:, 0], info.iloc[:, 1]))

            # 获取近期净值
            nav = ak.fund_open_fund_info_em(symbol=code, indicator="累计净值走势")
            nav.columns = ['date', 'nav']
            nav['date'] = pd.to_datetime(nav['date'])
            nav = nav.set_index('date').sort_index()

            # 计算近1/3/5年收益
            latest = nav['nav'].iloc[-1]
            latest_date = nav.index[-1]

            results = [f"  {code} {name}"]
            results.append(f"    最新净值: {latest:.4f} ({latest_date.date()})")

            for label, days in [('近1年', 252), ('近3年', 756), ('近5年', 1260)]:
                if len(nav) > days:
                    past = nav['nav'].iloc[-days]
                    ret = (latest / past - 1)
                    ann = (latest / past) ** (252/days) - 1
                    results.append(f"    {label}: {ret:+.1%} (年化{ann:+.1%})")

            # 费率信息
            for key in ['管理费率', '托管费率', '申购费率', '基金规模', '成立日期', '基金类型']:
                if key in info_dict:
                    results.append(f"    {key}: {info_dict[key]}")

            print("\n".join(results))
            print()

        except Exception as e:
            print(f"  {code} {name}: 获取失败 ({e})")
            print()
