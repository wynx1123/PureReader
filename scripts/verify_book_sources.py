#!/usr/bin/env python3
"""模拟 PureReader RuleParser 逻辑，对 Linpx/Pixiv 真实 API 响应做全链路验证"""
import json, re, urllib.request, urllib.parse

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"

def fetch(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")

# ---------- 模拟 RuleParser ----------
def normalize_path(path):
    p = path
    if p.startswith("$"): p = p[1:]
    if p.startswith("."): p = p[1:]
    p = p.replace("[*]", ".*").replace("[", ".").replace("]", "")
    return [x for x in p.split(".") if x]

def walk(node, path):
    if not path: return [node]
    first, rest = path[0], path[1:]
    if first == "*":
        if isinstance(node, list):
            out = []
            for it in node: out += walk(it, rest)
            return out
        return []
    if isinstance(node, dict) and first in node:
        return walk(node[first], rest)
    if isinstance(node, list) and first.isdigit() and int(first) < len(node):
        return walk(node[int(first)], rest)
    return []

def stringify(v):
    if isinstance(v, str): return v
    if isinstance(v, (int, float)): return str(v)
    if v is None: return None
    if isinstance(v, (dict, list)): return json.dumps(v, ensure_ascii=False)
    return str(v)

def json_list(content, path):
    try: data = json.loads(content)
    except Exception: return []
    out = []
    for v in walk(data, normalize_path(path)):
        if isinstance(v, list):  # 模拟 flattenedJSONValues
            for it in v:
                s = stringify(it)
                if s is not None: out.append(s)
        else:
            s = stringify(v)
            if s is not None: out.append(s)
    return out

def json_string(content, path):
    ls = json_list(content, path)
    return ls[0] if ls else None

def get_string(content, rule):
    for alt in [x.strip() for x in rule.split("||")]:
        if not alt: continue
        if "{{" in alt and "}}" in alt:
            v = render_template(content, alt)
        elif alt.startswith("$.") or alt.startswith("$["):
            v = json_string(content, alt)
        else:
            continue  # CSS 等不在本次验证范围
        if v: return v
    return None

def get_strings(content, rule):
    for alt in [x.strip() for x in rule.split("||")]:
        if not alt: continue
        if "{{" in alt and "}}" in alt:
            return template_list(content, alt)
        if alt.startswith("$.") or alt.startswith("$["):
            return json_list(content, alt)
    return []

def render_template(content, template):
    paths = re.findall(r"\{\{(\$[^}]+)\}\}", template)
    if not paths: return template
    result = template
    for path in paths:
        m = re.search(r"\{\{" + re.escape(path) + r"\}\}", result)
        if not m: continue
        v = json_string(content, path)
        if v is None: return None
        result = result[:m.start()] + v + result[m.end():]
    return None if "{{" in result else result

def template_list(content, template):
    paths = re.findall(r"\{\{(\$[^}]+)\}\}", template)
    if not paths: return []
    lists = [json_list(content, p) for p in paths]
    counts = [len(l) for l in lists if l]
    if not counts: return []
    n = max(counts)
    results = []
    for i in range(n):
        rendered = template
        failed = False
        for p, lst in zip(paths, lists):
            m = re.search(r"\{\{" + re.escape(p) + r"\}\}", rendered)
            if not m: continue
            v = lst[min(i, len(lst)-1)] if lst else None
            if v is None: failed = True; break
            rendered = rendered[:m.start()] + v + rendered[m.end():]
        if not failed and "{{" not in rendered:
            results.append(rendered)
    return results

# ---------- 规则定义（与书源 JSON 一致） ----------
LINPX = {
    "search": {
        "bookList": "$.novels", "name": "$.title", "author": "$.userName",
        "intro": "$.desc", "coverUrl": "$.coverUrl",
        "bookUrl": "https://api.linpx.ink/pixiv/novel/{{$.id}}/cache",
    },
    "tocUrl": "https://api.linpx.ink/pixiv/series/{{$.series.id}}/cache",
    "toc": {
        "chapterList": "$.novels", "chapterName": "$.title",
        "chapterUrl": "https://api.linpx.ink/pixiv/novel/{{$.id}}/cache",
    },
    "content": "$.content",
}
PIXIV = {
    "search": {
        "bookList": "$.body.novel.data", "name": "$.title", "author": "$.userName",
        "intro": "$.description", "coverUrl": "$.url",
        "bookUrl": "https://www.pixiv.net/ajax/novel/{{$.id}}",
    },
    "tocUrl": "https://www.pixiv.net/ajax/novel/series_content/{{$.body.seriesId}}?limit=30&offset=0",
    "toc": {
        "chapterList": "$.body.thumbnails.novel", "chapterName": "$.title",
        "chapterUrl": "https://www.pixiv.net/ajax/novel/{{$.id}}",
    },
    "content": "$.body.content",
}

HDRS = {"User-Agent": UA, "Referer": "https://www.pixiv.net/", "X-Requested-With": "XMLHttpRequest"}

results = []
def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'✅' if ok else '❌'} {name} {detail}")

# ========== Linpx ==========
print("="*60)
print("Linpx 验证")
print("="*60)
try:
    body = fetch("https://api.linpx.ink/pixiv/search/novel/%E9%BE%99/cache?page=1", HDRS)
    blocks = get_strings(body, LINPX["search"]["bookList"])
    check("Linpx 搜索 bookList", len(blocks) > 0, f"{len(blocks)} 条")
    if blocks:
        b0 = blocks[0]
        name = get_string(b0, LINPX["search"]["name"])
        author = get_string(b0, LINPX["search"]["author"])
        cover = get_string(b0, LINPX["search"]["coverUrl"])
        book_url = get_string(b0, LINPX["search"]["bookUrl"])
        check("Linpx 搜索书名", bool(name), str(name)[:30])
        check("Linpx 搜索作者", bool(author), str(author)[:20])
        check("Linpx 搜索封面", bool(cover), str(cover)[:60])
        check("Linpx 搜索详情URL", bool(book_url), str(book_url))
        # 目录（详情响应 → tocUrl 跳转系列）
        detail = fetch(book_url, HDRS)
        toc_target = get_string(detail, LINPX["tocUrl"])
        if toc_target:
            series_body = fetch(toc_target, HDRS)
            chapters = get_strings(series_body, LINPX["toc"]["chapterList"])
            check("Linpx 系列目录", len(chapters) > 0, f"{len(chapters)} 章, 来源 {toc_target}")
            if chapters:
                c0 = chapters[0]
                t = get_string(c0, LINPX["toc"]["chapterName"])
                u = get_string(c0, LINPX["toc"]["chapterUrl"])
                check("Linpx 目录章节名", bool(t), str(t)[:30])
                check("Linpx 目录章节URL", bool(u), str(u))
                # 正文
                content_body = fetch(u, HDRS)
                content = get_string(content_body, LINPX["content"])
                check("Linpx 正文", bool(content) and len(content) > 50, f"{len(content or '')} 字")
        else:
            # 单篇：zip fallback 单章
            chapters = get_strings(detail, LINPX["toc"]["chapterList"])
            names = get_strings(detail, LINPX["toc"]["chapterName"])
            urls = get_strings(detail, LINPX["toc"]["chapterUrl"])
            check("Linpx 单篇目录", len(urls) == 1 and names, f"{names[:1]} -> {urls[:1]}")
            if urls:
                content_body = fetch(urls[0], HDRS)
                content = get_string(content_body, LINPX["content"])
                check("Linpx 单篇正文", bool(content) and len(content) > 50, f"{len(content or '')} 字")
except Exception as e:
    check("Linpx 网络", False, str(e)[:100])

# ========== Pixiv ==========
print("="*60)
print("Pixiv 验证")
print("="*60)
try:
    body = fetch("https://www.pixiv.net/ajax/search/novels/%E5%B0%8F%E8%AF%B4?order=date_d&mode=safe&p=1", HDRS)
    blocks = get_strings(body, PIXIV["search"]["bookList"])
    check("Pixiv 搜索 bookList", len(blocks) > 0, f"{len(blocks)} 条")
    if blocks:
        b0 = blocks[0]
        name = get_string(b0, PIXIV["search"]["name"])
        author = get_string(b0, PIXIV["search"]["author"])
        intro = get_string(b0, PIXIV["search"]["intro"])
        cover = get_string(b0, PIXIV["search"]["coverUrl"])
        book_url = get_string(b0, PIXIV["search"]["bookUrl"])
        check("Pixiv 搜索书名", bool(name), str(name)[:30])
        check("Pixiv 搜索作者", bool(author), str(author)[:20])
        check("Pixiv 搜索简介", bool(intro), str(intro)[:20])
        check("Pixiv 搜索封面", bool(cover), str(cover)[:60])
        check("Pixiv 搜索详情URL", bool(book_url), str(book_url))
        # 详情
        detail = fetch(book_url, HDRS)
        toc_target = get_string(detail, PIXIV["tocUrl"])
        series_id = json_string(detail, "$.body.seriesId")
        if toc_target:
            series_body = fetch(toc_target, HDRS)
            chapters = get_strings(series_body, PIXIV["toc"]["chapterList"])
            check("Pixiv 系列目录", len(chapters) > 0, f"{len(chapters)} 章 seriesId={series_id}")
            if chapters:
                c0 = chapters[0]
                t = get_string(c0, PIXIV["toc"]["chapterName"])
                u = get_string(c0, PIXIV["toc"]["chapterUrl"])
                check("Pixiv 目录章节名/URL", bool(t) and bool(u), f"{str(t)[:20]} -> {u}")
                content_body = fetch(u, HDRS)
                content = get_string(content_body, PIXIV["content"])
                check("Pixiv 正文", bool(content) and len(content) > 20, f"{len(content or '')} 字")
        else:
            names = get_strings(detail, "$.body.title")
            urls = get_strings(detail, "https://www.pixiv.net/ajax/novel/{{$.body.id}}")
            check("Pixiv 单篇目录", len(urls) == 1 and names, f"{names[:1]} -> {urls[:1]}")
            if urls:
                content_body = fetch(urls[0], HDRS)
                content = get_string(content_body, PIXIV["content"])
                check("Pixiv 单篇正文", bool(content) and len(content) > 20, f"{len(content or '')} 字")
        # 单篇详情（独立验证 seriesId=null 路径）
        single = fetch("https://www.pixiv.net/ajax/novel/28723882", HDRS)
        sid = json_string(single, "$.body.seriesId")
        check("Pixiv 单篇 seriesId 为 null", sid is None or sid == "None", str(sid))
        names = get_strings(single, "$.body.title")
        urls = get_strings(single, "https://www.pixiv.net/ajax/novel/{{$.body.id}}")
        check("Pixiv 单篇 zip 目录", len(urls) == 1 and names, f"{names[:1]} -> {urls[:1]}")
        content = get_string(single, PIXIV["content"])
        check("Pixiv 单篇正文", bool(content) and len(content) > 20, f"{len(content or '')} 字")
except Exception as e:
    check("Pixiv 网络", False, str(e)[:100])

print("="*60)
ok = sum(1 for _, o, _ in results if o)
print(f"结果: {ok}/{len(results)} 通过")


def closing_tag_end(ns, tag, after):
    # 简化：找到第一个 </tag>，深度计数处理嵌套
    depth = 1
    open_re = re.compile(rf"<{tag}\b[^>]*>", re.I)
    close_re = re.compile(rf"</{tag}\s*>", re.I)
    pos = after
    while depth > 0:
        om = open_re.search(ns, pos)
        cm = close_re.search(ns, pos)
        if cm is None:
            return None
        if om is not None and om.start() < cm.start():
            depth += 1
            pos = om.end()
        else:
            depth -= 1
            pos = cm.end()
    return pos

def match_simple(html, selector):
    sel = selector.strip()
    if ":" in sel: sel = sel.split(":")[0]
    if not sel: return []
    tag_pat = "[a-zA-Z0-9]+"; cls = None; idn = None
    if sel.startswith("."):
        cls = sel[1:]
    elif sel.startswith("#"):
        idn = sel[1:]
    else:
        m = re.match(r"^([a-zA-Z0-9]+)", sel)
        tag_pat = m.group(1) if m else "[a-zA-Z0-9]+"
        rest = sel[len(tag_pat):]
        if rest.startswith("."): cls = rest[1:]
        elif rest.startswith("#"): idn = rest[1:]
    open_re = re.compile(rf"<({tag_pat})\b([^>]*)>", re.I)
    results = []
    for m in open_re.finditer(html):
        attrs = m.group(2)
        if attrs.rstrip().endswith("/"): continue
        if cls is not None:
            cm = re.search(r'class\s*=\s*["\']([^"\']*)["\']', attrs, re.I)
            if not cm: continue
            classes = cm.group(1).split()
            if cls not in classes: continue
        if idn is not None:
            if not re.search(rf'id\s*=\s*["\']{re.escape(idn)}["\']', attrs, re.I): continue
        tag = m.group(1).lower()
        if tag in VOID:
            results.append(m.group(0))
        else:
            end = closing_tag_end(html, tag, m.end())
            if end is None: continue
            results.append(html[m.start():end])
        if len(results) >= 200: break
    return results

def inner_html(el):
    m = re.match(r"^<[^>]*>(.*)$", el, re.S)
    return m.group(1) if m else el

def match_elements(html, selector):
    segments = [s for s in re.split(r"\s+", selector.replace(">", " ")) if s]
    if len(segments) == 1:
        return match_simple(html, segments[0])
    current = [html]
    for i, seg in enumerate(segments):
        nxt = []
        for scope in current:
            hay = scope if i == 0 else inner_html(scope)
            nxt.extend(match_simple(hay, seg))
        if not nxt: return []
        current = nxt[:200]
    return current

def extract_attr(el, attr, base=None):
    m = re.search(rf'{re.escape(attr)}\s*=\s*["\']([^"\']*)["\']', el, re.I)
    if m:
        return m.group(1)
    return None

def strip_tags(s):
    s = re.sub(r"<script[\s\S]*?</script>", "", s, flags=re.I)
    s = re.sub(r"<style[\s\S]*?</style>", "", s, flags=re.I)
    s = re.sub(r"<br\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"</p>", "\n", s, flags=re.I)
    s = re.sub(r"</div>", "\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    for a, b in [("&nbsp;"," "),("&lt;","<"),("&gt;",">"),("&amp;","&"),("&quot;",'"'),("&#39;","'")]:
        s = s.replace(a, b)
    while "\n\n\n" in s: s = s.replace("\n\n\n", "\n\n")
    return s.strip()

def get_text(el):
    return strip_tags(el)

def css_blocks(html, rule):
    rule = rule.strip()
    if "@" in rule:
        parts = [p for p in rule.split("@") if p]
        sel = parts[0]
        return match_elements(html, sel)
    return match_elements(html, rule)

def parse_list(html, rule, base):
    """evaluateList: CSS 块列表"""
    return css_blocks(html, rule)

def parse_field(block, rule, base):
    """evaluateSingle: 从块内取字段，支持 rule@text / rule@href / 正则"""
    rule = rule.strip()
    # 替换 ##...##
    m = re.match(r"^(.*?)##(.+?)##(.*)$", rule)
    expr = None
    if m and not rule.startswith("##"):
        rule = m.group(1); expr = m.group(2)
    if rule.startswith("##") and rule.endswith("##"):
        pat = rule[2:-2]
        mm = re.search(pat, block)
        return mm.group(1) if (mm and mm.groups()) else (mm.group(0) if mm else None)
    if "@" in rule:
        parts = [p for p in rule.split("@") if p]
        if len(parts) == 2 and parts[1] in ("text","href","src","html","title","alt","data-src","data-original"):
            els = match_elements(block, parts[0])
            if not els: return None
            if parts[1] == "text": v = get_text(els[0])
            elif parts[1] == "html": v = els[0]
            else: v = extract_attr(els[0], parts[1], base)
            if expr:
                ee = expr.split("##")
                v = re.sub(ee[0], ee[1] if len(ee) > 1 else "", v) if v else v
            return v
    els = match_elements(block, rule)
    if not els: return None
    return get_text(els[0])

print("=" * 50)
print("爱丽丝书屋 书源规则验证")
print("=" * 50)
BASE = "https://www.alicesw.com"
ok = fail = 0
VOID = {"img","br","input","hr","meta","link","source","embed","area","base","col","wbr","track","param"}

# ══════════════════════════════════════════════════════════════
# 爱丽丝书屋（HTML 站点，CSS 规则）
# ══════════════════════════════════════════════════════════════
def verify_alicesw():
    print("=" * 60)
    print("爱丽丝书屋 验证")
    print("=" * 60)
    A = "https://www.alicesw.com"
    ALICE_UA = {"User-Agent": UA}
    ok = 0; total = 0
    def check(label, cond, extra=""):
        nonlocal ok, total
        total += 1
        if cond: ok += 1; print(f"✅ {label} {extra}")
        else: print(f"❌ {label} {extra}")

    # 发现页（同人分类，ruleExplore）
    disc = fetch(f"{A}/lists/73.html", ALICE_UA)
    disc_blocks = match_elements(disc, "ul.txt-list li")
    check("爱丽丝 发现页", len(disc_blocks) > 0, f"{len(disc_blocks)} 条")
    if disc_blocks:
        dname = parse_field(disc_blocks[0], r"span.s2 a@text##^\[[^\]]*\]\s*##", A)
        durl = parse_field(disc_blocks[0], "span.s2 a@href", A)
        check("爱丽丝 发现书名去前缀", bool(dname) and not dname.startswith("["), f"「{dname[:20]}」")
        check("爱丽丝 发现URL", bool(durl) and "/novel/" in durl, durl or "")

    # 搜索
    body = fetch(f"{A}/search.html?q=%E5%9C%B0%E9%93%81", ALICE_UA)
    blocks = css_blocks(body, "div.list-group-item")
    check("爱丽丝 搜索列表", len(blocks) > 0, f"{len(blocks)} 条")
    if blocks:
        name = parse_field(blocks[0], r"h5 a@text##^\d+\.\s+##", A)
        url = parse_field(blocks[0], "h5 a@href", A)
        author = parse_field(blocks[0], "p.mb-1 a@text", A)
        intro = parse_field(blocks[0], "p.content-txt@text", A)
        check("爱丽丝 书名", bool(name), f"「{name[:20]}」")
        check("爱丽丝 详情URL", bool(url) and "/novel/" in url, url or "")
        check("爱丽丝 作者", bool(author), author or "")
        check("爱丽丝 简介", bool(intro), intro[:20] or "")
        # 详情页 → tocUrl 正则
        detail = fetch(url if url.startswith("http") else A + url, ALICE_UA)
        toc = re.search(r"/other/chapters/id/\d+\.html", detail)
        check("爱丽丝 tocUrl 提取", bool(toc), toc.group(0) if toc else "")
        if toc:
            toc_html = fetch(toc.group(0) if toc.group(0).startswith("http") else A + toc.group(0), ALICE_UA)
            chapters = css_blocks(toc_html, "ul.section-list li a")
            check("爱丽丝 目录", len(chapters) > 0, f"{len(chapters)} 章")
            if chapters:
                title = parse_field(chapters[0], "a@text", A)
                u1 = parse_field(chapters[0], "a@href", A)
                check("爱丽丝 章节名", bool(title), title[:20])
                check("爱丽丝 章节URL", bool(u1) and "/book/" in u1, u1 or "")
                if u1:
                    chap = fetch(u1 if u1.startswith("http") else A + u1, ALICE_UA)
                    content = parse_field(chap, "div.content_txt@text", A)
                    check("爱丽丝 正文", bool(content) and len(content) > 100, f"{len(content or '')} 字")
    return ok, total

if __name__ == "__main__":
    ok, total = verify_alicesw()
    print(f"\n结果: {ok}/{total} 通过")
