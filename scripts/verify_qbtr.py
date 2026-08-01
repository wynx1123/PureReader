import json, re, urllib.request, urllib.parse

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
BASE = "https://www.qbtr.org"

# ── CSS 引擎模拟（对齐 PureReader）──
VOID = {"img","br","input","hr","meta","link","source","embed","area","base","col","wbr","track","param"}
def closing_tag_end(ns, tag, after):
    depth, i = 1, after
    while i < len(ns):
        m = re.match(r'<([a-z0-9]+)((?:[^>"\']|"[^"]*"|\'[^\']*\')*)>', ns[i:])
        if m:
            t = m.group(1)
            if t == tag and not ns[i:].startswith('</'): depth += 1
            i += len(m.group(0))
        elif ns.startswith('</' + tag + '>', i):
            depth -= 1
            if depth <= 0: return i + len(tag) + 3
            i += len(tag) + 3
        elif ns.startswith('</', i): i += 2
        else: i += 1
    return len(ns)
def match_simple(html, selector):
    selector = selector.strip()
    m = re.match(r'^([a-z0-9]+)?(?:#([a-zA-Z0-9_-]+))?(?:\.([a-zA-Z0-9_-]+))?$', selector)
    if not m or not (m.group(1) or m.group(2) or m.group(3)): return []
    tag, eid, cls = m.group(1), m.group(2), m.group(3)
    tag = tag or r'[a-z0-9]+'
    pat = re.compile(r'<(%s)((?:(?:"[^"]*")|(?:\'[^\']*\')|[^>"\'])*)>' % tag, re.I)
    out = []
    for m2 in pat.finditer(html):
        attrs = m2.group(2) or ''
        if eid and not re.search(r'id=["\']%s["\']' % re.escape(eid), attrs): continue
        if cls:
            cm = re.search(r'class=["\']([^"\']*)["\']', attrs)
            if not cm or cls not in cm.group(1).split(): continue
        if m2.group(1).lower() in VOID:
            out.append(m2.group(0))
        else:
            out.append(html[m2.start():closing_tag_end(html, m2.group(1), m2.end())])
        if len(out) >= 200: break
    return out
def inner_html(el):
    m = re.match(r'<[^>]+>', el)
    if not m: return el
    tag = re.match(r'<([a-z0-9]+)', el).group(1)
    if not el.rstrip().endswith('</' + tag + '>'): return el[m.end():]
    return el[m.end():-len('</%s>' % tag) - 2]
def match_elements(html, selector):
    segs = [s for s in selector.replace('>', ' ').strip().split(' ') if s]
    if not segs: return []
    if len(segs) == 1: return match_simple(html, segs[0])
    current = [html]
    for off, seg in enumerate(segs):
        nxt = []
        for scope in current:
            nxt += match_simple(scope if off == 0 else inner_html(scope), seg)
        if not nxt: return []
        current = nxt[:200]
    return current
def strip_tags(s):
    s = re.sub(r'<script[\s\S]*?</script>', '', s, flags=re.I)
    s = re.sub(r'<style[\s\S]*?</style>', '', s, flags=re.I)
    s = re.sub(r'<br\s*/?>', '\n', s, flags=re.I)
    s = re.sub(r'</p>', '\n', s, flags=re.I)
    s = re.sub(r'</div>', '\n', s, flags=re.I)
    s = re.sub(r'<[^>]+>', '', s)
    s = s.replace('&nbsp;', ' ')
    while '\n\n\n' in s: s = s.replace('\n\n\n', '\n\n')
    return s.strip()
def extract_attr(el, attr, base=None):
    a = attr.lower()
    if a == 'text': return strip_tags(el)
    if a == 'html':
        m = re.match(r'<[^>]+>', el)
        tag = re.match(r'<([a-z0-9]+)', el).group(1)
        if el.rstrip().endswith('</' + tag + '>'):
            return el[m.end():-len('</%s>' % tag) - 2]
        return el[m.end():]
    m = re.search(r'%s\s*=\s*["\']([^"\']*)["\']' % re.escape(attr), el, re.I)
    if not m: return None
    v = m.group(1)
    if a in ('href', 'src') and base and v.startswith('/'):
        return base.rstrip('/') + v
    return v
def parse_field(block, rule, base=None):
    rule = rule.strip()
    m = re.match(r"^(.*?)##(.+?)##(.*)$", rule)
    expr = None
    if m and not rule.startswith("##"):
        rule, expr = m.group(1), m.group(2)
    if rule.startswith("##") and rule.endswith("##"):
        mm = re.search(rule[2:-2], block)
        return mm.group(1) if (mm and mm.groups()) else (mm.group(0) if mm else None)
    # 交替规则 ||
    for alt in rule.split("||"):
        alt = alt.strip()
        if not alt: continue
        v = None
        if '@' in alt:
            sel, attr = alt.rsplit('@', 1)
            els = match_elements(block, sel)
            v = extract_attr(els[0], attr, base) if els else None
        else:
            els = match_elements(block, alt)
            v = strip_tags(els[0]) if els else None
        if v:
            if expr:
                ee = expr.split('##')
                v = re.sub(ee[0], ee[1] if len(ee) > 1 else '', v)
            return v
    return None

# ── 网络 ──
def fetch(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=25).read().decode('gb18030', 'replace')
def post_search(kw):
    # 模拟 formEncoded：GB2312 逐字节 percent-encode
    raw = kw.encode('gb2312')
    enc = ''.join('%%%02X' % b if b not in b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*%' else chr(b) for b in raw)
    body = ("keyboard=" + enc + "&show=title&classid=0").encode('ascii')
    req = urllib.request.Request(BASE + "/e/search/index.php", data=body, headers={
        "User-Agent": UA,
        "Content-Type": "application/x-www-form-urlencoded; charset=gb2312",
        "Referer": BASE + "/"})
    return urllib.request.urlopen(req, timeout=25).read().decode('gb18030', 'replace')

ok = total = 0
def check(label, cond, extra=""):
    global ok, total
    total += 1
    if cond: ok += 1; print(f"✅ {label} {extra}")
    else: print(f"❌ {label} {extra}")

# 1. 搜索（POST + GB2312）
html = post_search("火影")
blocks = match_elements(html, "div.bk")
check("搜索列表", len(blocks) > 0, f"{len(blocks)} 条")
if blocks:
    name = parse_field(blocks[0], "h3 a@text||h3@text")
    url = parse_field(blocks[0], "h3 a@href||a@href", BASE)
    intro = parse_field(blocks[0], "p@text##^简介：\\s*##")
    check("书名", bool(name), f"「{name[:22]}」")
    check("详情URL", bool(url) and url.startswith("http"), url or "")
    check("简介去前缀", bool(intro) and not intro.startswith("简介"), intro[:25])

# 2. 详情页 → 目录
if blocks:
    detail = fetch(url)
    chapters = match_elements(detail, "div.book_list li a")
    check("目录", len(chapters) > 5, f"{len(chapters)} 章")
    if chapters:
        t1 = parse_field(chapters[0], "a@text##^\\s+##")
        u1 = parse_field(chapters[0], "a@href", BASE)
        check("章节名去空格", bool(t1) and not t1.startswith(" "), f"「{t1[:20]}」")
        check("章节URL", bool(u1) and len(u1.split("/")) >= 5, u1 or "")

# 3. 正文
if blocks and chapters:
    chap = fetch(u1)
    content = parse_field(chap, "div.read_chapterDetail@text")
    check("正文", bool(content) and len(content) > 200, f"{len(content or '')} 字")
    if content: print("   开头:", content[:50].replace(chr(10), ' '))

# 4. 发现页（3 个分类）
for path in ["/hot/", "/tongren/", "/changgui/"]:
    disc = fetch(BASE + path)
    dblocks = match_elements(disc, "div.bk")
    if dblocks:
        dname = parse_field(dblocks[0], "h3 a@text||h3@text")
        durl = parse_field(dblocks[0], "a@href", BASE)
        check(f"发现页 {path}", bool(dname) and bool(durl), f"{len(dblocks)} 条 | 「{(dname or '')[:18]}」")
    else:
        check(f"发现页 {path}", False, "无 div.bk")

print(f"\n结果: {ok}/{total} 通过")
