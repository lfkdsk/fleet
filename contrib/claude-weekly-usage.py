#!/usr/bin/env python3
"""估算本机 Claude Code 订阅的周额度用掉了多少、还有多久刷新。

为什么要估：`~/.claude.json` 里的 `cachedUsageUtilization` 只在交互式 `/usage` 跑过时才刷新
（实测三份 backup 里的 fetchedAtMs 完全一致，没有任何后台刷新），`claude` CLI 没有 usage
子命令，读 `~/.claude/.credentials.json` 去问账号又会被 auto-mode 分类器拦。
于是退而求其次：拿 transcript 里每条 assistant 消息自带的 usage 折算挂牌价，
再用少数几个「人肉读到过的真实百分比」标定成本→百分比的换算率。

只读。状态（标定锚点）存在 ~/.local/state/claude-usage/anchors.json，不碰 $FLEET_HOME。
"""
import json, os, glob, datetime, collections, sys

PROJECTS = os.path.expanduser('~/.claude/projects')
CONF     = os.path.expanduser('~/.claude.json')
ANCHORS  = os.path.expanduser('~/.local/state/claude-usage/anchors.json')

# $/MTok 挂牌价 (input, output)；cache write = 1.25x input，cache read = 0.1x input
# （Fable 系例外，cache read 是 $0.25/MTok 定价）。只是换算用的权重，不是账单。
PRICE = {'claude-opus-5': (5, 25), 'claude-opus-4-8': (5, 25), 'claude-opus-4-7': (5, 25),
         'claude-fable-5': (10, 50), 'claude-fable-5-1': (10, 50),
         'claude-sonnet-5': (2, 10), 'claude-sonnet-4-6': (3, 15),
         'claude-haiku-4-5-20251001': (1, 5)}
CACHE_READ = {'claude-fable-5': 0.25, 'claude-fable-5-1': 0.25}


def reset_boundary():
    """周窗口边界。取 cachedUsageUtilization 里的 seven_day.resets_at；它按周复现，
    所以哪怕这份缓存过期了，边界本身仍然可信。"""
    with open(CONF) as fh:
        conf = json.load(fh)
    cu = conf.get('cachedUsageUtilization') or {}
    sd = ((cu.get('utilization') or {}).get('seven_day')) or {}
    ra = sd.get('resets_at')
    if not ra:
        return None, cu, sd
    t = datetime.datetime.fromisoformat(ra.replace('Z', '+00:00'))
    now = datetime.datetime.now(datetime.timezone.utc)
    while t <= now:                      # 缓存旧的话，把边界按周推到下一次
        t += datetime.timedelta(days=7)
    return t, cu, sd


def scan():
    """每条 assistant 消息一行；按 message id 去重（resume/分叉会复制 transcript）。
    只留第一方模型——经第三方网关打出去的模型（不是 claude-* 名字的）不吃订阅额度。"""
    seen, rows = set(), []
    for path in glob.glob(os.path.join(PROJECTS, '*', '*.jsonl')):
        try:
            fh = open(path, errors='replace')
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                msg = d.get('message') or {}
                u = msg.get('usage')
                if d.get('type') != 'assistant' or not isinstance(u, dict):
                    continue
                key = msg.get('id') or d.get('requestId')
                if key in seen:
                    continue
                seen.add(key)
                model = msg.get('model') or ''
                ts = d.get('timestamp')
                if model not in PRICE or not ts:
                    continue
                pin, pout = PRICE[model]
                cr = CACHE_READ.get(model, pin * 0.1)
                cost = ((u.get('input_tokens') or 0) * pin
                        + (u.get('cache_creation_input_tokens') or 0) * pin * 1.25
                        + (u.get('cache_read_input_tokens') or 0) * cr
                        + (u.get('output_tokens') or 0) * pout) / 1e6
                rows.append((datetime.datetime.fromisoformat(ts.replace('Z', '+00:00')), model, cost))
    rows.sort()
    return rows


def main():
    reset, cu, sd = reset_boundary()
    if reset is None:
        sys.exit('~/.claude.json 里没有 seven_day.resets_at，跑一次交互式 /usage 再来')
    now = datetime.datetime.now(datetime.timezone.utc)
    rows = scan()
    win = lambda t: int((reset - t).total_seconds() // (7 * 86400))
    per_win = collections.defaultdict(float)
    for t, _m, c in rows:
        per_win[win(t)] += c
    cur = per_win[0]

    fetched = cu.get('fetchedAtMs')
    fetched_t = datetime.datetime.fromtimestamp(fetched / 1000, datetime.timezone.utc) if fetched else None
    print(f'周窗口   起 {(reset - datetime.timedelta(days=7)):%Y-%m-%d %H:%MZ}  '
          f'止 {reset:%Y-%m-%d %H:%MZ}（本地 {reset.astimezone():%m-%d %H:%M}）'
          f'  还剩 {(reset - now).total_seconds() / 3600:.1f} 小时')
    if fetched_t:
        age = (now - fetched_t).total_seconds() / 3600
        print(f'缓存值   weekly_all {sd.get("utilization")}%  抓于 {fetched_t:%Y-%m-%d %H:%MZ}'
              f'（{age:.0f} 小时前{"，已过期，仅供参考" if age > 6 else ""}）')

    anchors = []
    if os.path.exists(ANCHORS):
        with open(ANCHORS) as fh:
            anchors = (json.load(fh) or {}).get('anchors') or []
    print(f'\n本窗口折算成本 ${cur:,.2f}（挂牌价加权，非账单）')
    print('历史窗口：', '  '.join(
        f'{(reset - datetime.timedelta(days=7 * (k + 1))):%m-%d}=${per_win[k]:,.0f}'
        for k in sorted(per_win) if 0 < k <= 5))

    if not anchors:
        print('\n没有标定锚点，只能给成本不能给百分比。'
              '\n跑一次交互式 /usage，把读到的 weekly_all 百分比追加进 ' + ANCHORS)
        return
    print('\n标定（每个锚点：那一刻窗口内已花的钱 ÷ 当时的真实百分比）：')
    rates = []
    for a in anchors:
        at = datetime.datetime.fromisoformat(a['at'].replace('Z', '+00:00'))
        pct = a['weekly_all_pct_used']
        spent = sum(c for t, _m, c in rows if win(t) == win(at) and t <= at)
        if pct <= 0 or spent <= 0:
            continue
        rate = spent / pct
        rates.append((at, pct, rate))
        print(f'  {at:%Y-%m-%d %H:%MZ}  {pct:>3}%  ←  ${spent:8,.2f}   ⇒ ${rate:6,.2f} / 1%'
              f'   [{a.get("source", "")}]')
    if not rates:
        return
    at, pct, rate = max(rates, key=lambda r: r[1])   # 取百分比最大的那个：取整误差最小
    used = cur / rate
    print(f'\n以 {at:%m-%d} 那个 {pct}% 的锚点为准（取整误差最小）：'
          f'本窗口估计已用 ~{used:.0f}%，剩 ~{100 - used:.0f}%')
    if len(rates) > 1:
        lo = cur / max(r[2] for r in rates)
        hi = cur / min(r[2] for r in rates)
        print(f'各锚点之间不自洽时的范围：{lo:.0f}% – {hi:.0f}%')
    print('注意：官方限额的内部权重不公开，未必与挂牌价成比例；Fable 可能记在独立的 '
          'weekly_scoped 桶里。这是估算，拍板前请以 /usage 为准。')


if __name__ == '__main__':
    main()
