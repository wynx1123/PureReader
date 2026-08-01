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
