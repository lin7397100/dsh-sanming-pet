#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
三明文宠 · 知识库检索器（SAG2 式两跳检索 / 纯本地）
------------------------------------------------------------
直接读 SAG Wiki 的本地索引（%APPDATA%\\com.sag.desktop\\sag.sqlite）。
SAG 用 SQLite FTS5 存倒排索引，正文以行号指回原文件，所以这里不需要
JEV / Embedding / 任何网络请求：纯本地 BM25 召回，零 key 零外发。

检索路线（对齐 SAG2 的思路，但不接任何模型）：
  ① BM25 初筛   查询分词后先 AND 再 OR，拿到第一跳候选
  ② 锚点提取   从命中段落里挑「编号 / 型号 / 标题词 / 词表实词」当桥梁词
                编号与型号优先——企业内部资料多是靠单号、设备号串联的
  ③ 第二跳     用桥梁词再检索一次，合并去重，分数按跳数衰减
  ④ 排序       正文命中数 + 标题命中权重（标题权重更高），再按 bm25 微调

用法：
  python kb-search.py "高炉利用系数是多少" --limit 8 [--hops 2] [--json]
  python kb-search.py --roots            # 列出已绑定目录
  python kb-search.py --stats            # 索引库体积 / 文档数 / 空闲页
  python kb-search.py --changed          # 比对磁盘与索引，看有没有新增改动
  python kb-search.py --vacuum           # 收缩索引库（删掉的目录会把库撑大）
"""
import argparse
import json
import os
import re
import sqlite3
import sys

# 强制 UTF-8 输出。Windows 上 python 的 stdout 默认跟随系统代码页（中文系统 cp936），
# 而宿主 PowerShell 是按 UTF-8 解码的：桌面快捷方式启动的进程里没有 PYTHONUTF8，
# 中文路径 / 文件名就会变成乱码。这里自己 reconfigure，环境变量缺不缺都不影响。
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


CANDIDATE_DBS = [
    os.path.join(os.environ.get("APPDATA", ""), "com.sag.desktop", "sag.sqlite"),
    os.path.join(os.environ.get("APPDATA", ""), "sag-wiki", "sag.sqlite"),
]

HERE = os.path.dirname(os.path.abspath(__file__))
ALIAS_FILE = os.path.join(os.path.dirname(HERE), "data", "检索别名.json")

# 疑问词 / 语气词：参与检索只会拉低精度
STOP = set("""的 了 是 在 和 与 有 我 你 他 她 它 这 那 就 也 都 还 又 很 更 最
什么 多少 怎么 怎样 如何 为什么 哪些 哪个 哪里 是否 可以 需要 请问 帮我 一下
吗 呢 呀 啊 吧 哦 请 我们 你们 他们 以及 还有 或者 但是 因为 所以 如果 时候
有关 关于 相关 介绍 说说 讲讲 告诉 知道 内容 情况 方面 里 中 上 下 内 外
请问 麻烦 帮忙 看看 查查 查一下 搜索 检索 一段 一条 一篇 文件 文档""".split())

# 能直接按行读的纯文本类扩展名
TEXT_EXT = set(""".md .markdown .txt .text .csv .tsv .json .jsonl .yaml .yml .toml .ini
.conf .log .py .pyw .js .mjs .cjs .ts .tsx .jsx .vue .svelte .go .rs .java .kt .c .h
.cpp .hpp .cs .php .rb .swift .sql .sh .bash .ps1 .psm1 .bat .cmd .html .htm .css
.scss .less .xml .svg .srt .vtt .tex .rst .org""".split())

FORMAT_LABEL = {
    ".pdf": "PDF", ".docx": "Word", ".doc": "Word", ".xlsx": "Excel", ".xls": "Excel",
    ".pptx": "PPT", ".ppt": "PPT", ".epub": "EPUB", ".rtf": "RTF", ".odt": "ODT",
}


# 口语意图 → 资料里的正式说法。「有什么好玩的」这种问法，jieba 词表里切不出
# 可用实词，光靠「三元区」会把整章政务荣誉条目全捞上来。
INTENT_GROUPS = [
    (("好玩", "玩什么", "哪里玩", "哪玩", "去哪玩", "值得去", "值得玩", "打卡",
      "游玩", "旅游", "景点", "逛"),
     ("景区", "景点", "旅游")),
    (("好吃", "吃啥", "吃什么", "小吃", "美食", "特色菜"),
     ("美食", "小吃")),
    (("住哪", "住哪", "住宿", "酒店", "民宿"),
     ("住宿", "酒店")),
]

# 章节名落在这些题材上，段落多半是真答案；反过来「城市名片 / 荣誉 / 名单」
# 这类条目通篇【门票】不适用，不该占版面
PLAY_WORDS = ("景区", "景点", "旅游", "游玩", "公园", "古镇", "遗址", "温泉", "非遗",
              "美食", "小吃", "住宿", "酒店", "民宿", "交通", "门票", "线路", "露营")


def expand_intent(query):
    low = (query or "").lower()
    out = []
    for keys, vals in INTENT_GROUPS:
        if not any(k in low for k in keys):
            continue
        for v in vals:
            if v not in low and v not in out:
                out.append(v)
    return out[:4]


def find_db(explicit=None):
    if explicit and os.path.isfile(explicit):
        return explicit
    for p in CANDIDATE_DBS:
        if p and os.path.isfile(p):
            return p
    return None


def strip_prefix(path):
    for pre in ("\\\\?\\", "\\??\\"):
        if path.startswith(pre):
            return path[len(pre):]
    return path


def load_aliases():
    """用户可编辑的同义词表：一个词 → 一组等价说法。"""
    try:
        with open(ALIAS_FILE, "r", encoding="utf-8-sig") as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    if isinstance(raw, dict):
        for k, v in raw.items():
            if k.startswith("_") or not isinstance(v, list):
                continue
            vals = [str(x).strip() for x in v if str(x).strip()]
            out.append((str(k).strip(), vals))
    return out


def load_vocab(conn):
    """SAG 的词表就是 jieba 切词结果，直接拿来当词典做最长匹配。"""
    return [r[0] for r in conn.execute("select distinct term from chunk_vocab") if r[0]]


def load_docfreq(conn):
    """每个词的文档频率：太高频的词（如「数据」「工作」）当不了桥梁词。"""
    df = {}
    try:
        for term, c in conn.execute("select term, count(*) from chunk_vocab group by term"):
            if term:
                df[term] = c
    except sqlite3.OperationalError:
        pass
    return df


PUNCT = set("，。！？、；：,?!;:'\"“”‘’()（）[]【】《》〈〉…—-*/\t")


def tokenize(query, vocab):
    """按 SAG 的词表切词。

    关键约束：SAG 的 FTS 索引里存的是 jieba 切好的词、以词为单位，
    所以查询也只能落在完整词上——「冷却壁」在库里被切成 `冷却`+`壁`，
    整串去查必然 0 命中。这里逐字推进做最长匹配，匹配不到才走一字，
    （而不是跳两个字）否则「炉冷 / 却壁」这种跨词边界碎片会污染查询。
    """
    vocab_set = set(vocab)
    maxlen = min(max((len(t) for t in vocab), default=1), 8)
    q = query.strip()
    tokens, i, n = [], 0, len(q)
    while i < n:
        ch = q[i]
        if ch.isspace() or ch in PUNCT:
            i += 1
            continue
        m = re.match(r"[A-Za-z0-9_./+#-]+", q[i:])
        if m:
            tokens.append(m.group(0).lower())
            i += m.end()
            continue
        hit = None
        for L in range(min(maxlen, n - i), 1, -1):
            if q[i:i + L] in vocab_set:
                hit = q[i:i + L]
                break
        if hit:
            tokens.append(hit)
            i += len(hit)
        else:
            i += 1

    out = []
    for t in tokens:
        if t in STOP or len(t) < 2:
            continue
        if t not in out:
            out.append(t)

    if out:
        return out[:14]
    # 词表完全没覆盖（新文档没进索引、或领域术语）→ 退化成 2 字滑窗，
    # 至少还能靠 OR 捞出东西，精度交给后面的正文命中计数兜底
    fallback = []
    for i in range(n - 1):
        two = q[i:i + 2]
        if two in STOP or not re.search(r"[\u4e00-\u9fa5A-Za-z0-9]", two):
            continue
        if two not in fallback:
            fallback.append(two)
    return fallback[:10]


def expand_by_alias(query, tokens):
    """同义词扩召回：问「利用系数」也能命中写成「利用率」的段落。

    双向生效——问「中台」也能补出「数据中台」，
    不然用户少打两个字就搜不到了。
    """
    extra = []
    low = query.lower()
    for key, vals in load_aliases():
        hit_key = key.lower() in low
        hit_val = any(v.lower() in low for v in vals if v)
        if not (hit_key or hit_val):
            continue
        for cand in [key] + vals:
            cand = cand.strip()
            if len(cand) >= 2 and cand.lower() not in low and cand not in tokens:
                if cand not in extra:
                    extra.append(cand)
    return extra[:6]


def ext_of(path):
    return os.path.splitext(path)[1].lower()


def read_snippet(path, ranges, max_chars=760):
    """按 chunks.ranges 指回原文件取正文。非文本类读不了，返回空串交给上层兜底。"""
    if ext_of(path) not in TEXT_EXT:
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return ""
    chunks = []
    for a, b in ranges:
        a = max(1, int(a))
        b = min(len(lines), int(b))
        if b >= a:
            chunks.append("".join(lines[a - 1:b]))
    text = "\n".join(chunks).strip()
    return text[:max_chars]


def find_converted(conn, path):
    """SAG 把 PDF/Word 转成纯文本后再索引，转换产物路径存在 conversions 表。"""
    try:
        row = conn.execute(
            "select output from conversions where source like ? or output like ? limit 1",
            ("%" + path + "%", "%" + os.path.splitext(os.path.basename(path))[0] + "%"),
        ).fetchone()
    except (sqlite3.OperationalError, sqlite3.InterfaceError):
        return None
    if not row or not row[0]:
        return None
    out = strip_prefix(row[0])
    return out if os.path.isfile(out) else None


def fts_rows(conn, expr, cap=160):
    try:
        return conn.execute(
            "select rowid, bm25(chunk_fts, 2.0, 2.0, 1.0) as s from chunk_fts "
            "where chunk_fts match ? order by s limit %d" % cap, (expr,)
        ).fetchall()
    except sqlite3.OperationalError:
        return []


def make_expr(tokens, mode):
    toks = [t.replace('"', "") for t in tokens if t]
    if not toks:
        return None
    return (" %s " % mode).join('"%s"' % t for t in toks)


def collect(conn, rows, tokens, root_norm, seen, hop, bridge=None, out=None, bridge_w=0.0):
    """把 FTS 行号变成可读命中，顺带取回正文片段。"""
    out = out if out is not None else []
    for cid, score in rows:
        ch = conn.execute(
            "select document_id, heading, ranges, start_line, end_line from chunks where id = ?",
            (cid,)
        ).fetchone()
        if not ch:
            continue
        doc = conn.execute("select path, name from documents where id = ?", (ch[0],)).fetchone()
        if not doc:
            continue
        path = strip_prefix(doc[0])
        if root_norm and not path.lower().replace("/", "\\").startswith(root_norm):
            continue
        key = (path, int(ch[3]))
        if key in seen:
            continue
        seen.add(key)

        ranges = []
        try:
            ranges = json.loads(ch[2] or "[]")
        except ValueError:
            ranges = [[ch[3], ch[4]]]
        # full 给「段落详情」窗用（一次读够），text 仍是截短的摘要给卡片
        full = read_snippet(path, ranges, max_chars=3200)
        if not full:
            alt = find_converted(conn, path)
            if alt:
                full = read_snippet(alt, ranges, max_chars=3200)
        text = full[:760] if full else ''

        low = (text or "").lower()
        head = ch[1] or ""
        # 弱桥梁词（普通中文词）必须在正文里真的出现，否则它只是同主题的邻近段落，
        # 放进来只会挤掉真正靠单号串过去的那条
        if bridge and text and not is_strong_id(bridge) and bridge.lower() not in low:
            continue
        if text:
            # 单字词（壁 / 水 / 号）满篇都是，只能算半个命中
            matched = sum(1.0 if len(t) >= 2 else 0.5 for t in tokens if t.lower() in low)
            head_hit = sum(1.0 if len(t) >= 2 else 0.5 for t in tokens if t.lower() in head.lower())
        else:
            # 读不到正文时只能靠标题判断，避免把无关段落带上来
            matched = sum(1.0 for t in tokens if t.lower() in head.lower())
            head_hit = matched

        # 第二跳的价值就体现在这里：正文里真的出现了那个单号/型号，才给奖励
        if bridge and low and bridge.lower() in low and len(bridge) >= 3:
            matched += bridge_w

        kind = ext_of(path).lstrip(".")
        out.append({
            "file": doc[1],
            "path": path,
            "heading": head,
            "line": int(ch[3]),
            "end_line": int(ch[4]),
            "score": float(score),
            "matched": matched,
            "head_hit": head_hit,
            "hop": hop,
            "bridge": bridge or "",
            "text": text,
            "full": full,
            "readable": bool(text),
            "format": FORMAT_LABEL.get(ext_of(path), kind.upper() if kind else ""),
            "na": (text or "").count("不适用"),
        })
    return out


BRIDGE_NOISE = re.compile(r"^(的|了|是|在|和|与|有|这|那|其|所|为|及|以|并|或|个|次|年|月|日)$")
# 文档内部锚点：Word 转 markdown 时图片、表格会落成 content_2392873 / t20231106_6290719
# 这种名字，长得像单号，其实是占位符——拿它当桥只会把不同章节乱串
PSEUDO_ID = re.compile(
    r"^(content|contents|image|images|img|pic|pics|table|tables|media|attachment|"
    r"attachments|figure|fig|shape|ole|object|t|d)[-__]?\d{3,}", re.IGNORECASE)


def is_strong_id(term):
    """单号 / 型号：既有字母又有数字，而且够长。

    「W45」这种三位周次串不起线索，必须当弱词处理，否则同一周的记录会全被拉进来。
    """
    if not term or len(term) < 5:
        return False
    if PSEUDO_ID.match(term):
        return False
    return re.search(r"[A-Za-z]", term) is not None and re.search(r"\d", term) is not None


def is_good_bridge(term, tokens, dfreq):
    """桥梁词质量闸门：年份、日期、段号这种纯数字串会把结果串乱。"""
    if not term or len(term) < 2:
        return False
    if term.lower() in set(t.lower() for t in tokens):
        return False
    if re.fullmatch(r"\d{1,5}", term):
        return False                      # 2026 / 11 / 03 一律不当桥
    if len(term) == 2 and dfreq.get(term, 0) > 3:
        return False                      # 太常见的两字词串不起线索
    return True


def extract_bridges(hits, tokens, vocab, dfreq, max_bridges=3):
    """从第一跳命中里挑「桥梁词」——第二步靠它把线索串到别的文档。

    SAG2 的核心假设：企业资料的多跳靠的是单号、设备号、型号这种精确词法
    单元，而不是语义相似。所以这里**只认强标识**（够长、字母数字都有）。

    走过的弯路：早先还拿「标题词」「正文实词」当桥，结果「要求」「第17章」
    这种普通词把毫不相干的文档全捞进来——问高炉跳进文旅大全、问三元区旅游
    又跳出高炉台账，双向串味。宁可少一串，也不要串错。
    """
    if not hits:
        return []
    scores = {}
    for h in hits[:6]:
        text = h.get("text") or h.get("heading") or ""
        for m in re.finditer(r"[A-Za-z]{1,}[-_ ]?\d+(?:[-_]\d+)*", text):
            term = m.group(0).strip()
            if not is_strong_id(term):
                continue          # W45、2026 这种短串或纯数字不当桥
            if not is_good_bridge(term, tokens, dfreq):
                continue          # 查询里已经有的词不重复当桥
            scores[term] = max(scores.get(term, 0.0), 1.5)
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    return [t for t, _ in ranked[:max_bridges]]


def search(db, query, limit=8, root=None, hops=2):
    conn = sqlite3.connect(db, timeout=6)
    try:
        vocab = load_vocab(conn)
        dfreq = load_docfreq(conn)
        tokens = tokenize(query, vocab)
        if not tokens:
            return {"ok": True, "tokens": [], "hits": [], "message": "没有可检索的关键词"}
        aliases = expand_by_alias(query, tokens)

        root_norm = strip_prefix(root).lower().replace("/", "\\") if root else None

        # ---- 第一跳：先 AND 后 OR ----
        # 意图词（景区 / 景点 / 美食…）先参与 AND：问「有什么好玩的」时
        # 「三元区 AND 景区」比「三元区」单打精准得多，命中太少再退回宽召回
        intent = expand_intent(query)
        rows = []
        if intent:
            rows = fts_rows(conn, make_expr(tokens + intent[:1], "AND"))
            if len(rows) < 3:
                rows = []
        if not rows:
            rows = fts_rows(conn, make_expr(tokens, "AND"))
        if not rows and aliases:
            rows = fts_rows(conn, make_expr(tokens + aliases, "AND"))
        if not rows:
            rows = fts_rows(conn, make_expr(tokens, "OR"))
        if not rows:
            return {"ok": True, "tokens": tokens, "hits": [], "total": 0,
                    "message": "索引里没有匹配的关键词，换个说法或换同义词试试"}

        hits, seen = [], set()
        collect(conn, rows, tokens + aliases + intent, root_norm, seen, 1, out=hits)

        # ---- 第二跳：拿锚点词再搜一次 ----
        bridges = extract_bridges(hits, tokens, vocab, dfreq)
        if hops >= 2 and bridges:
            seen2 = set(seen)
            for b in bridges:
                b_rows = fts_rows(conn, '"%s"' % b.replace('"', ""), cap=60)
                if not b_rows:
                    continue
                # 关键：必须并回 hits，否则第二跳捞到的东西会被直接丢掉
                bw = 2.4 if is_strong_id(b) else 0.5
                collect(conn, b_rows, tokens + aliases + [b], root_norm,
                        seen2, 2, bridge=b, out=hits, bridge_w=bw)

        # ---- 排序：正文命中 + 标题权重，跳数与 bm25 只做微调 ----
        for h in hits:
            rel = h["matched"] + 2 * h["head_hit"]
            if any(w in (h["heading"] or "") for w in PLAY_WORDS):
                rel += 1.2          # 章节本身就是景区 / 美食 / 交通题材
            if h["na"] >= 3:
                rel -= 2.6          # 通篇「不适用」的名片模板，别占前排
            if h["hop"] == 1:
                decay = 1.0
            elif (h["bridge"] and is_strong_id(h["bridge"])
                  and h["bridge"].lower() in (h["text"] or "").lower()):
                # 第二跳是靠单号 / 型号精确串过来的，这跟第一跳同等相关，不该打折
                decay = 1.0
            else:
                decay = 0.72
            h["rank"] = -(rel * decay) + h["score"] / 1000.0
        # 第二跳里一个字都没沾上的（只是文件里出现过这个单号）没展示价值，清掉
        hits = [h for h in hits if h["hop"] == 1 or h["matched"] > 0]
        hits.sort(key=lambda h: h["rank"])

        return {
            "ok": True,
            "tokens": tokens,
            "aliases": aliases,
            "bridges": bridges,
            "intent": intent,
            "hops": hops,
            "hits": hits[:limit],
            "total": len(hits),
        }
    finally:
        conn.close()


def list_roots(db):
    conn = sqlite3.connect(db, timeout=6)
    try:
        out = []
        for path, name, status, error in conn.execute(
                "select path, name, status, error from roots"):
            files = conn.execute("select count(*) from documents where root = ?", (path,)).fetchone()[0]
            out.append({
                "path": strip_prefix(path),
                "name": name,
                "status": status,
                "error": error,
                "files": files,
            })
        return {"ok": True, "roots": out}
    finally:
        conn.close()


def db_stats(db):
    size = os.path.getsize(db)
    conn = sqlite3.connect(db, timeout=6)
    try:
        pages = conn.execute("pragma page_count").fetchone()[0]
        free = conn.execute("pragma freelist_count").fetchone()[0]
        docs = conn.execute("select count(*) from documents").fetchone()[0]
        chunks = conn.execute("select count(*) from chunks").fetchone()[0]
        roots = conn.execute("select count(*) from roots").fetchone()[0]
        return {
            "ok": True,
            "size_mb": round(size / 1048576.0, 2),
            "pages": pages,
            "free_pages": free,
            "wasted_mb": round(free * 4096 / 1048576.0, 2),
            "documents": docs,
            "chunks": chunks,
            "roots": roots,
            "suggest_vacuum": free > max(200, pages * 0.25),
        }
    finally:
        conn.close()


def changed(db):
    """比对索引里记的 mtime/size 与磁盘现状，判断要不要重扫。

    SAG 存的是纳秒时间戳，文件系统给的是 float 秒，两者换算后差几十纳秒，
    所以容差要留 1 秒，否则每个文件都会被判成"改过了"。
    """
    conn = sqlite3.connect(db, timeout=6)
    tol = 1_000_000_000  # 1 秒（纳秒单位）
    try:
        modified = missing = 0
        for path, mtime, size in conn.execute("select path, mtime, size from documents"):
            real = strip_prefix(path)
            try:
                st = os.stat(real)
            except OSError:
                missing += 1
                continue
            cur = int(st.st_mtime * 1e9) if st.st_mtime > 1e7 else int(st.st_mtime)
            if abs(cur - int(mtime or 0)) > tol or int(st.st_size) != int(size or 0):
                modified += 1
        return {"ok": True, "modified": modified, "missing": missing,
                "has_change": modified > 0 or missing > 0}
    finally:
        conn.close()


def vacuum(db):
    """收缩索引库。

    绑过一个大目录再移除，SAG 只会逻辑删除，页会一直留着——
    实测一个 demo 库能被撑到 156 MB（真实数据只有 200 KB）。
    WAL 模式下必须先 checkpoint(TRUNCATE) 才能把文件真正截短。
    """
    before = os.path.getsize(db)
    conn = sqlite3.connect(db, timeout=20)
    try:
        try:
            conn.execute("pragma wal_checkpoint(TRUNCATE)")
        except sqlite3.OperationalError:
            pass
        conn.execute("vacuum")
        try:
            conn.execute("pragma wal_checkpoint(TRUNCATE)")
        except sqlite3.OperationalError:
            pass
    finally:
        conn.close()
    after = os.path.getsize(db)
    return {"ok": True, "before_mb": round(before / 1048576.0, 2),
            "after_mb": round(after / 1048576.0, 2),
            "saved_mb": round((before - after) / 1048576.0, 2)}


def main():
    ap = argparse.ArgumentParser(description="SAG 索引本地检索")
    ap.add_argument("query", nargs="?", default="")
    ap.add_argument("--limit", type=int, default=8)
    ap.add_argument("--root", default=None)
    ap.add_argument("--db", default=None)
    ap.add_argument("--hops", type=int, default=2)
    ap.add_argument("--roots", action="store_true")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--changed", action="store_true")
    ap.add_argument("--vacuum", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    db = find_db(a.db)
    if not db:
        print(json.dumps({"ok": False, "message": "还没建过索引，先绑定一个文件夹"},
                         ensure_ascii=False))
        return 1
    try:
        if a.roots:
            payload = list_roots(db)
        elif a.stats:
            payload = db_stats(db)
        elif a.changed:
            payload = changed(db)
        elif a.vacuum:
            payload = vacuum(db)
        else:
            payload = search(db, a.query, a.limit, a.root, max(1, min(a.hops, 3)))
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "message": "检索失败：%s" % e}, ensure_ascii=False))
        return 1
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
