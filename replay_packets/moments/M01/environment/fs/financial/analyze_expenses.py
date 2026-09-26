"""
支付宝 + 微信账单合并分析
解析导出文件 → 归类 → 月度汇总 → 对比 FIRE 预算假设
输出: HTML 交互报告 (output/expense_report.html)
"""
import pandas as pd
import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import plotly.express as px
from pathlib import Path
from io import StringIO
from datetime import datetime

EXPENSE_DIR = Path(__file__).parent / 'expenses'
OUTPUT_DIR = Path(__file__).parent / 'output'
OUTPUT_DIR.mkdir(exist_ok=True)

# ============================
# FIRE 预算基准（月）
# ============================
BUDGET = {
    '租房': 2900,
    '餐饮': 2000,
    '交通': 300,
    '日用': 500,
    '通讯/订阅': 200,
    'AI工具': 800,
    '成人用品': 500,
    '社交/娱乐': 500,
    '旅行': 1500,
    '其他': 500,
}
BUDGET_TOTAL = sum(BUDGET.values())

OFF_ACCOUNT = {
    '租房': 2900,       # 杭州房租，直接转账（人才补贴到手后调为 400）
}
OFF_ACCOUNT_TOTAL = sum(OFF_ACCOUNT.values())

SUBSIDY = 2500

# ============================
# 分类规则
# ============================
CATEGORY_RULES = [
    ('成人用品', ['倒模', '名器', '飞机杯', '自慰', '臀模', '情趣', '实体娃娃',
                '等身', '史莱姆', '脂软', '肉厚', 'GOSE', '格斯', 'G PROJECT',
                'HOTPOWER', '慢玩', '内衣', '蕾丝', '文胸']),
    ('AI工具', ['ChatGPT', 'Claude', 'OpenAI', 'DeepSeek', 'API服务',
              'Cursor', 'cursor', 'Copilot', 'AutoDL', 'OpenRouter',
              '服务器租赁', 'GPU租', 'TUC100', '云浣溪']),
    ('租房', ['房租', '租房', '租金', '公寓', '自如', '蛋壳', '贝壳', '绿凯']),
    ('旅行', ['机票', '酒店', '民宿', '门票', '景区', '旅游', '签证',
              '东京', '大阪', '京都', '日本', '免税', '携程', '相铁',
              'Fresa', '能力测试报名费']),
    ('餐饮', ['美食', '餐饮', '外卖', '饿了么', '美团', '麦当劳', '肯德基', '星巴克',
              '瑞幸', 'luckin', '料理', '拌饭', '烧烤', '火锅', '奶茶', '咖啡',
              '食堂', '便利店', '超市', '水果', '零食', '饮料', '面包',
              '淘宝闪购', '盒马', '叮咚', '面馆', '快餐', '小吃',
              '酸菜鱼', '黄焖鸡', '沙拉', '寿司', '披萨', '饺子',
              '鸡排', '烤肉', '米线', '粥', '馄饨', '三明治', '牛肉面',
              '可口可乐', '矿泉水', '气泡水', '卡旺卡',
              '茶百道', '蜜雪冰城', 'Cotti', '烤冷面', '冰淇淋', '甜品']),
    ('交通', ['地铁', '公交', '打车', '滴滴', '出行', '高铁', '火车',
              '航空', '铁路', '12306', '出租车', '单车', '骑行', '停车',
              '加油', '高速', '电瓶车', '地铁站']),
    ('通讯/订阅', ['话费', '流量', '宽带', '移动', '联通', '电信',
                 '订阅', '会员', 'VIP', 'iCloud',
                 'Spotify', '网易云', 'QQ音乐', 'B站', '爱奇艺', '腾讯视频',
                 'Netflix', 'YouTube', 'Apple', 'Google', 'Microsoft',
                 'GitHub', 'lowiro']),
    ('水电燃气', ['电费', '供电', '水费', '水务', '燃气', '燃气费', '物业']),
    ('日用', ['日用', '洗护', '纸巾', '洗衣', '理发', '家居', '收纳',
              '快递', '邮费', '充电', '文具', '药', '医疗', '体检', '口罩',
              '顺丰', '速运', '云打印']),
    ('数码/设备', ['电脑', '手机', '耳机', '键盘', '鼠标', '显示器', 'iPad',
                 'MacBook', 'ThinkPad', 'GPU', '硬盘', 'SSD', 'U盘',
                 '充电器', '转接头', 'MIDI', '音频', '声卡']),
    ('游戏/二次元', ['游戏', 'Steam', 'Arcaea', '音游', '手办', '模型',
                   '直播', '哔哩哔哩']),
    ('社交/转账', ['红包', '转账']),
    ('服饰', ['衣服', '裤子', '鞋', '外套', '优衣库', 'UNIQLO', 'MUJI']),
    ('外包/委托', ['代做', '代付', '代订', '外包']),
    ('教育/书籍', ['书', '课程', '培训', '学习', '教育', '论文']),
]

# 手动标注：无法通过关键词自动识别的特定交易
MANUAL_OVERRIDES = {
    '长沙奋斗': '成人用品',        # 等身娃娃衣服
    'butterfly': '成人用品',       # 等身娃娃定金
    'bu**店': '成人用品',          # 同上（支付宝脱敏显示）
    '池袋店': '旅行',
    '兰湘子': '餐饮',
    '陕七街': '餐饮',
    'HopeGoo': '旅行',           # 成田Express车票
    'はなまるうどん': '旅行',
    '浅草店': '旅行',
    'マルチエキューブ': '旅行',     # 上野站储物柜
    '国际代收关税': '成人用品',     # 海淘飞机杯
    '国际代报关': '成人用品',
    '科浴美发': '日用',            # 理发
    '中国知网': '教育/书籍',
    '纯游互动': '游戏/二次元',     # 范式：起源
    '链动小铺': 'AI工具',          # windsurf 体验
    '丽阳广告图文': '日用',        # 签证照相费
    '范子奇': '餐饮',             # 师弟，饭钱
    '邵一波': '餐饮',             # 师弟，饭钱
    '东北烤冷面': '餐饮',
    'smspva': 'AI工具',           # 接码平台（注册海外服务用）
    'rq**店': '成人用品',
    'rqs': '成人用品',
    '窝趣买': '日用',             # 学校打印机
    '恒生活': '餐饮',             # 路边自助饮料机
    '**辉': '旅行',              # 朋友的朋友，结旅游钱
}

def classify(row):
    cp = str(row.get('counterpart', ''))
    desc = str(row.get('description', ''))
    text = f"{row.get('category_raw', '')} {cp} {desc}".lower()

    for key, cat in MANUAL_OVERRIDES.items():
        if key.lower() in cp.lower() or key.lower() in desc.lower():
            return cat

    for cat, keywords in CATEGORY_RULES:
        for kw in keywords:
            if kw.lower() in text:
                return cat
    return '其他'


# ============================
# 解析
# ============================
def parse_alipay(filepath):
    with open(filepath, 'r', encoding='gbk') as f:
        lines = f.readlines()
    header_idx = next(i for i, l in enumerate(lines) if '交易时间' in l)
    data_lines = []
    for line in lines[header_idx + 1:]:
        line = line.strip().rstrip(',').replace('\t', '')
        if line and not line.startswith('-'):
            data_lines.append(line)
    header = lines[header_idx].strip().rstrip(',')
    df = pd.read_csv(StringIO(header + '\n' + '\n'.join(data_lines)), dtype=str, on_bad_lines='skip')
    df.columns = [c.strip() for c in df.columns]
    records = []
    for _, row in df.iterrows():
        direction = str(row.get('收/支', '')).strip()
        status = str(row.get('交易状态', '')).strip()
        if '退款' in status or '关闭' in status:
            continue
        try:
            amount = float(str(row.get('金额', '0')).strip())
        except ValueError:
            continue
        records.append({
            'date': pd.to_datetime(str(row.get('交易时间', '')).strip()),
            'source': '支付宝', 'direction': direction, 'amount': amount,
            'counterpart': str(row.get('交易对方', '')).strip(),
            'description': str(row.get('商品说明', '')).strip(),
            'category_raw': str(row.get('交易分类', '')).strip(),
            'payment': str(row.get('收/付款方式', '')).strip(), 'status': status,
        })
    return pd.DataFrame(records)


def parse_wechat(filepath):
    df_raw = pd.read_excel(filepath)
    header_idx = next(i for i in range(30) if '交易时间' in str(df_raw.iloc[i, 0]))
    columns = df_raw.iloc[header_idx].tolist()
    data = df_raw.iloc[header_idx + 1:].reset_index(drop=True)
    data.columns = [str(c).strip() for c in columns]
    records = []
    for _, row in data.iterrows():
        direction = str(row.get('收/支', '')).strip()
        status = str(row.get('当前状态', '')).strip()
        if '退款' in status or '已退款' in status:
            continue
        try:
            amount = float(str(row.get('金额(元)', 0)).replace('¥', '').strip())
        except (ValueError, TypeError):
            continue
        records.append({
            'date': pd.to_datetime(row.get('交易时间', '')),
            'source': '微信', 'direction': direction, 'amount': amount,
            'counterpart': str(row.get('交易对方', '')).strip(),
            'description': str(row.get('商品', '')).strip(),
            'category_raw': str(row.get('交易类型', '')).strip(),
            'payment': str(row.get('支付方式', '')).strip(), 'status': status,
        })
    return pd.DataFrame(records)


# ============================
# 数据加工
# ============================
print("解析账单...")
dfs = []
for f in EXPENSE_DIR.glob('支付宝*.csv'):
    dfs.append(parse_alipay(f))
for f in EXPENSE_DIR.glob('微信*.xlsx'):
    dfs.append(parse_wechat(f))
if not dfs:
    raise SystemExit("未找到账单文件")

df = pd.concat(dfs, ignore_index=True)
df['month'] = df['date'].dt.to_period('M')

expenses = df[df['direction'] == '支出'].copy()
income = df[df['direction'] == '收入'].copy()
expenses['category'] = expenses.apply(classify, axis=1)

monthly = expenses.groupby('month')['amount'].sum()
months_count = len(monthly)
monthly_avg = monthly.mean()
corrected_avg = monthly_avg + OFF_ACCOUNT_TOTAL

cat_sum = expenses.groupby('category')['amount'].agg(['sum', 'count', 'mean'])
cat_sum = cat_sum.sort_values('sum', ascending=False)
cat_sum['monthly'] = cat_sum['sum'] / months_count
cat_sum['pct'] = cat_sum['sum'] / expenses['amount'].sum() * 100

big = expenses[expenses['amount'] > 200].sort_values('amount', ascending=False)

# 月度分类交叉表
monthly_cat = expenses.groupby(['month', 'category'])['amount'].sum().unstack(fill_value=0)

# 刚性 vs 弹性
rigid_cats = ['餐饮', '租房', '交通', '日用', '通讯/订阅', '水电燃气', 'AI工具']
rigid_monthly = cat_sum.loc[cat_sum.index.isin(rigid_cats), 'monthly'].sum() + OFF_ACCOUNT_TOTAL
flex_monthly = cat_sum.loc[~cat_sum.index.isin(rigid_cats), 'monthly'].sum()

print(f"数据加工完成: {len(expenses)} 笔支出, {months_count} 个月")

# ============================
# 生成图表
# ============================
COLORS = px.colors.qualitative.Set2

# 图1: 月度支出趋势
fig_monthly = go.Figure()
months_str = [str(m) for m in sorted(monthly.index)]
vals = [monthly[m] for m in sorted(monthly.index)]
bar_colors = ['#e74c3c' if v > BUDGET_TOTAL else '#2ecc71' for v in vals]
fig_monthly.add_trace(go.Bar(x=months_str, y=vals, marker_color=bar_colors, name='月支出',
                              hovertemplate='%{x}<br>支出: ¥%{y:,.0f}<extra></extra>'))
fig_monthly.add_hline(y=BUDGET_TOTAL, line_dash="dash", line_color="blue",
                       annotation_text=f"FIRE预算 ¥{BUDGET_TOTAL:,}")
fig_monthly.add_hline(y=monthly_avg, line_dash="dot", line_color="orange",
                       annotation_text=f"账内月均 ¥{monthly_avg:,.0f}")
fig_monthly.update_layout(title='月度支出 vs FIRE预算', yaxis_title='支出 (元)',
                           height=400, template='plotly_white')

# 图2: 分类占比（环形图）
fig_pie = go.Figure(data=[go.Pie(
    labels=cat_sum.index, values=cat_sum['sum'],
    hole=0.4, textinfo='label+percent', textposition='outside',
    hovertemplate='%{label}<br>¥%{value:,.0f} (%{percent})<extra></extra>'
)])
fig_pie.update_layout(title=f'支出分类占比（年度 ¥{expenses["amount"].sum():,.0f}）',
                       height=450, template='plotly_white', showlegend=False)

# 图3: 分类月均 vs 预算
all_cats = sorted(set(list(BUDGET.keys()) + list(cat_sum.index)))
cat_labels, actual_vals, budget_vals = [], [], []
for cat in all_cats:
    cat_labels.append(cat)
    actual_vals.append(cat_sum.loc[cat, 'monthly'] if cat in cat_sum.index else 0)
    budget_vals.append(BUDGET.get(cat, 0))

fig_budget = go.Figure()
fig_budget.add_trace(go.Bar(y=cat_labels, x=actual_vals, orientation='h', name='实际',
                             marker_color='#3498db',
                             hovertemplate='%{y}: ¥%{x:,.0f}/月<extra></extra>'))
fig_budget.add_trace(go.Bar(y=cat_labels, x=budget_vals, orientation='h', name='预算',
                             marker_color='#e74c3c', opacity=0.4,
                             hovertemplate='%{y}: ¥%{x:,.0f}/月<extra></extra>'))
fig_budget.update_layout(title='分类月均 vs FIRE预算（账内部分）', xaxis_title='月均 (元)',
                          barmode='group', height=500, template='plotly_white')

# 图4: 大额支出散点
if len(big) > 0:
    fig_big = go.Figure()
    fig_big.add_trace(go.Scatter(
        x=big['date'], y=big['amount'], mode='markers',
        marker=dict(size=big['amount'].clip(upper=2000) / 50 + 5,
                    color=big['amount'], colorscale='Reds', showscale=True,
                    colorbar=dict(title='金额')),
        text=big.apply(lambda r: f"{r['category']}<br>{r['counterpart']}<br>{r['description'][:30]}", axis=1),
        hovertemplate='%{text}<br>¥%{y:,.0f}<br>%{x|%Y-%m-%d}<extra></extra>'
    ))
    fig_big.update_layout(title='大额支出时间线 (>200元)', yaxis_title='金额 (元)',
                           height=400, template='plotly_white')
else:
    fig_big = go.Figure()

# 图5: 月度分类堆叠
fig_stack = go.Figure()
sorted_months = sorted(monthly_cat.index)
for i, cat in enumerate(cat_sum.index):
    if cat in monthly_cat.columns:
        fig_stack.add_trace(go.Bar(
            x=[str(m) for m in sorted_months],
            y=[monthly_cat.loc[m, cat] if m in monthly_cat.index else 0 for m in sorted_months],
            name=cat, marker_color=COLORS[i % len(COLORS)],
            hovertemplate='%{x}<br>' + cat + ': ¥%{y:,.0f}<extra></extra>'
        ))
fig_stack.update_layout(barmode='stack', title='月度支出分类构成',
                         yaxis_title='支出 (元)', height=450, template='plotly_white')

# 图6: 刚性 vs 弹性
fig_rigid = go.Figure(data=[go.Pie(
    labels=['刚性支出', '弹性支出'], values=[rigid_monthly, flex_monthly],
    hole=0.5, marker_colors=['#3498db', '#e74c3c'],
    textinfo='label+value', texttemplate='%{label}<br>¥%{value:,.0f}/月'
)])
fig_rigid.update_layout(title='刚性 vs 弹性支出（含账外修正）',
                         height=350, template='plotly_white')

# ============================
# 构建 HTML
# ============================
def fig_to_html(fig):
    return fig.to_html(full_html=False, include_plotlyjs=False)

# 分类表格
cat_rows = ""
for cat, row in cat_sum.iterrows():
    budget_val = BUDGET.get(cat, 0)
    diff = row['monthly'] - budget_val
    diff_class = 'over' if diff > 0 and budget_val > 0 else 'under' if diff < 0 else ''
    diff_str = f"{diff:+,.0f}" if budget_val > 0 else "—"
    budget_str = f"¥{budget_val:,}" if budget_val > 0 else "—"
    cat_rows += f"""<tr>
        <td>{cat}</td><td>¥{row['sum']:,.0f}</td><td>¥{row['monthly']:,.0f}</td>
        <td>{row['pct']:.1f}%</td><td>{int(row['count'])}</td>
        <td>{budget_str}</td><td class="{diff_class}">{diff_str}</td>
    </tr>"""

# 大额支出表格
big_rows = ""
for _, row in big.head(40).iterrows():
    desc = str(row['description'])[:35]
    big_rows += f"""<tr>
        <td>{row['date'].strftime('%Y-%m-%d')}</td><td>¥{row['amount']:,.0f}</td>
        <td>{row['category']}</td><td>{row['source']}</td>
        <td>{row['counterpart']}</td><td title="{row['description']}">{desc}</td>
    </tr>"""

# 未归类
other = expenses[expenses['category'] == '其他']
other_rows = ""
if len(other) > 0:
    other_top = other.groupby(['counterpart', 'description'])['amount'].agg(['sum', 'count']).sort_values('sum', ascending=False)
    for (cp, desc), row in other_top.head(15).iterrows():
        other_rows += f"""<tr>
            <td>{str(cp)[:25]}</td><td>{str(desc)[:30]}</td>
            <td>¥{row['sum']:,.0f}</td><td>{int(row['count'])}</td>
        </tr>"""

html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>消费分析报告</title>
<script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>
<style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ font-family: -apple-system, 'Microsoft YaHei', sans-serif; background: #f5f5f5; color: #333; }}
    .container {{ max-width: 1200px; margin: 0 auto; padding: 20px; }}
    h1 {{ text-align: center; padding: 30px 0 10px; font-size: 28px; }}
    .subtitle {{ text-align: center; color: #888; margin-bottom: 30px; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 30px; }}
    .card {{ background: #fff; border-radius: 12px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }}
    .card .label {{ font-size: 13px; color: #888; margin-bottom: 5px; }}
    .card .value {{ font-size: 26px; font-weight: 700; }}
    .card .note {{ font-size: 12px; color: #aaa; margin-top: 5px; }}
    .card .over {{ color: #e74c3c; }}
    .card .under {{ color: #2ecc71; }}
    .section {{ background: #fff; border-radius: 12px; padding: 25px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }}
    .section h2 {{ font-size: 18px; margin-bottom: 15px; padding-bottom: 10px; border-bottom: 2px solid #eee; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th {{ background: #f8f9fa; padding: 10px 12px; text-align: left; font-weight: 600; border-bottom: 2px solid #dee2e6; }}
    td {{ padding: 8px 12px; border-bottom: 1px solid #eee; }}
    tr:hover {{ background: #f8f9fa; }}
    .over {{ color: #e74c3c; font-weight: 600; }}
    .under {{ color: #2ecc71; }}
    .chart-row {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 20px; }}
    .chart-full {{ margin-bottom: 20px; }}
    @media (max-width: 768px) {{ .chart-row {{ grid-template-columns: 1fr; }} }}
    .tag {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; }}
    .tag-info {{ background: #e3f2fd; color: #1976d2; }}
    .tag-warn {{ background: #fff3e0; color: #e65100; }}
    details {{ margin-top: 10px; }}
    summary {{ cursor: pointer; color: #1976d2; font-weight: 600; }}
</style>
</head>
<body>
<div class="container">
    <h1>消费分析报告</h1>
    <p class="subtitle">{df['date'].min().strftime('%Y-%m-%d')} ~ {df['date'].max().strftime('%Y-%m-%d')} · 生成于 {datetime.now().strftime('%Y-%m-%d %H:%M')}</p>

    <div class="cards">
        <div class="card">
            <div class="label">账内月均支出</div>
            <div class="value">¥{monthly_avg:,.0f}</div>
            <div class="note">支付宝 + 微信</div>
        </div>
        <div class="card">
            <div class="label">修正后月均</div>
            <div class="value {'over' if corrected_avg > BUDGET_TOTAL else 'under'}">¥{corrected_avg:,.0f}</div>
            <div class="note">含账外房租 + AI订阅</div>
        </div>
        <div class="card">
            <div class="label">FIRE 预算</div>
            <div class="value">¥{BUDGET_TOTAL:,}</div>
            <div class="note">差异 {corrected_avg - BUDGET_TOTAL:+,.0f}/月 ({(corrected_avg/BUDGET_TOTAL-1)*100:+.1f}%)</div>
        </div>
        <div class="card">
            <div class="label">如获人才补贴</div>
            <div class="value under">¥{corrected_avg - SUBSIDY:,.0f}</div>
            <div class="note">补贴 {SUBSIDY:,}/月 → 低于预算 {BUDGET_TOTAL - (corrected_avg - SUBSIDY):,}</div>
        </div>
        <div class="card">
            <div class="label">总笔数</div>
            <div class="value">{len(expenses):,}</div>
            <div class="note">{months_count} 个月数据</div>
        </div>
        <div class="card">
            <div class="label">刚性 / 弹性</div>
            <div class="value">{rigid_monthly/(rigid_monthly+flex_monthly)*100:.0f}% / {flex_monthly/(rigid_monthly+flex_monthly)*100:.0f}%</div>
            <div class="note">¥{rigid_monthly:,.0f} / ¥{flex_monthly:,.0f}</div>
        </div>
    </div>

    <div class="chart-full section">
        <h2>月度支出趋势</h2>
        {fig_to_html(fig_monthly)}
    </div>

    <div class="chart-row">
        <div class="section">
            <h2>支出分类占比</h2>
            {fig_to_html(fig_pie)}
        </div>
        <div class="section">
            <h2>刚性 vs 弹性</h2>
            {fig_to_html(fig_rigid)}
        </div>
    </div>

    <div class="chart-full section">
        <h2>月度分类构成</h2>
        {fig_to_html(fig_stack)}
    </div>

    <div class="chart-full section">
        <h2>分类月均 vs FIRE 预算</h2>
        <p style="color:#888;font-size:13px;margin-bottom:10px;">预算列中账外部分（租房、AI工具）仅在上方卡片中修正，此处显示账内实际</p>
        {fig_to_html(fig_budget)}
    </div>

    <div class="section">
        <h2>分类明细</h2>
        <table>
            <thead><tr><th>类别</th><th>年度总额</th><th>月均</th><th>占比</th><th>笔数</th><th>预算</th><th>差额</th></tr></thead>
            <tbody>{cat_rows}</tbody>
        </table>
    </div>

    <div class="chart-full section">
        <h2>大额支出时间线</h2>
        {fig_to_html(fig_big)}
    </div>

    <div class="section">
        <h2>大额支出明细 (>200元)</h2>
        <p style="color:#888;margin-bottom:10px;">共 {len(big)} 笔，合计 ¥{big['amount'].sum():,.0f}（占总支出 {big['amount'].sum()/expenses['amount'].sum()*100:.1f}%）</p>
        <table>
            <thead><tr><th>日期</th><th>金额</th><th>类别</th><th>来源</th><th>对方</th><th>说明</th></tr></thead>
            <tbody>{big_rows}</tbody>
        </table>
    </div>

    <div class="section">
        <h2>未归类交易 TOP 15</h2>
        <p style="color:#888;margin-bottom:10px;">用于优化分类规则</p>
        <table>
            <thead><tr><th>对方</th><th>说明</th><th>总额</th><th>笔数</th></tr></thead>
            <tbody>{other_rows}</tbody>
        </table>
    </div>

    <div class="section">
        <h2>FIRE 模型校验</h2>
        <table>
            <tr><th style="width:40%">指标</th><th>值</th></tr>
            <tr><td>FIRE 预算</td><td>¥{BUDGET_TOTAL:,}/月</td></tr>
            <tr><td>账内月均</td><td>¥{monthly_avg:,.0f}/月</td></tr>
            <tr><td>+ 账外（房租 + AI）</td><td>+¥{OFF_ACCOUNT_TOTAL:,}/月</td></tr>
            <tr><td>修正后月均</td><td class="{'over' if corrected_avg > BUDGET_TOTAL else 'under'}">¥{corrected_avg:,.0f}/月（{corrected_avg - BUDGET_TOTAL:+,.0f}）</td></tr>
            <tr><td>如获人才补贴</td><td class="under">¥{corrected_avg - SUBSIDY:,.0f}/月（{corrected_avg - SUBSIDY - BUDGET_TOTAL:+,.0f}）</td></tr>
            <tr><td>月支出标准差</td><td>¥{monthly.std():,.0f}（变异系数 {monthly.std()/monthly.mean()*100:.0f}%）</td></tr>
            <tr><td>最低/最高月</td><td>¥{monthly.min():,.0f} / ¥{monthly.max():,.0f}</td></tr>
            <tr><td>刚性支出（含账外）</td><td>¥{rigid_monthly:,.0f}/月</td></tr>
            <tr><td>弹性支出</td><td>¥{flex_monthly:,.0f}/月（{flex_monthly/(rigid_monthly+flex_monthly)*100:.0f}%）</td></tr>
        </table>
    </div>
</div>
</body>
</html>"""

output_path = OUTPUT_DIR / 'expense_report.html'
output_path.write_text(html, encoding='utf-8')
print(f"报告已生成: {output_path}")
