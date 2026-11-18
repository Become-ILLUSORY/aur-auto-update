#!/usr/bin/env python3
"""上游依赖漂移检测。

比对「上游构建定义里的 depends」与「AUR 上已发布包的 depends」，找出上游新增
但你没跟进的依赖。

安全约束：上游 PKGBUILD 是 bash 脚本，绝不能 source / eval 它（等于执行远程代码）。
这里只做纯文本解析，取字面量字符串；含变量展开的条目单独标注、不参与比对。
"""

import json
import re
import sys
import urllib.parse
import urllib.request

AUR_BASE = "https://aur.archlinux.org"
TIMEOUT = 30


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "aur-auto-update-deps-check"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def parse_array(text, varname):
    """从 PKGBUILD 文本里取 varname=(...) 的字面量项。

    返回 (literals, dynamic)：字面量项集合，以及含变量/命令替换而无法静态确定的项。
    只做字符扫描，不执行任何内容。
    """
    literals, dynamic = set(), set()
    # 匹配 varname=( 或 varname_x86_64=( 等，行首（允许前导空白）
    pat = re.compile(
        r"^[ \t]*" + re.escape(varname) + r"(?:_[A-Za-z0-9_]+)?\+?=\(([^)]*)\)",
        re.MULTILINE | re.DOTALL,
    )
    for m in pat.finditer(text):
        body = m.group(1)
        # 只取成对的引号内容，引号外的一律忽略
        for q in re.findall(r"'([^']*)'|\"([^\"]*)\"", body):
            val = (q[0] or q[1]).strip()
            if not val:
                continue
            if "$" in val or "`" in val:
                dynamic.add(val)
            else:
                # optdepends 的 "pkg: desc" 形式在这里不会出现，但防御性处理
                literals.add(norm_dep(val.split(":")[0]))
    # 引号外出现 $ 说明数组里混有变量展开（如 depends+=("$X" 'y')）
    # 这些无法静态确定，标出来避免误判为「一致」
    for m in pat.finditer(text):
        body = m.group(1)
        outside = re.sub(r"'[^']*'|\"[^\"]*\"", "", body)
        for tok in re.findall(r"\$\{?[A-Za-z_][A-Za-z0-9_]*", outside):
            dynamic.add(tok)
    return literals, dynamic


def norm_dep(name):
    """去掉版本约束，便于跨写法比对：'foo>=1.2' -> 'foo'"""
    return re.split(r"[<>=]", name)[0].strip()


def main():
    conf_path = sys.argv[1] if len(sys.argv) > 1 else "scripts/upstream-deps.conf"
    try:
        with open(conf_path, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]
    except OSError as e:
        print(f"!! 读不到配置 {conf_path}: {e}")
        return 1

    rows = []  # (pkg, source, dep, verdict, detail)
    pkg_summary = []

    for line in lines:
        parts = [p.strip() for p in line.split("|")]
        pkg, urls = parts[0], [p for p in parts[1:] if p]
        if not pkg or not urls:
            print(f"!! 配置行无法解析，跳过: {line}")
            continue

        # AUR 已发布的 depends（用 .SRCINFO，字段已规范化）
        try:
            srcinfo = fetch(f"{AUR_BASE}/cgit/aur.git/plain/.SRCINFO?h={urllib.parse.quote(pkg)}")
        except Exception:
            # .SRCINFO 抓取失败时退回解析 PKGBUILD
            try:
                srcinfo = fetch(f"{AUR_BASE}/cgit/aur.git/plain/PKGBUILD?h={urllib.parse.quote(pkg)}")
            except Exception as e:
                pkg_summary.append((pkg, urls[0], "ERROR", f"AUR 数据取不到: {e}"))
                rows.append((pkg, "-", "-", "ERROR", f"AUR 数据取不到: {e}"))
                continue

        aur_pkgs, _ = parse_array(srcinfo, "depends")
        # .SRCINFO 里是 "\tdepends = foo" 形式，parse_array 抓不到，补一条解析
        for m in re.finditer(r"^[ \t]*depends = (.+)$", srcinfo, re.MULTILINE):
            aur_pkgs.add(norm_dep(m.group(1).strip()))
        aur_set = {norm_dep(x) for x in aur_pkgs}

        for url in urls:
            try:
                upstream_text = fetch(url)
            except Exception as e:
                pkg_summary.append((pkg, url, "ERROR", f"上游取不到: {e}"))
                rows.append((pkg, url, "-", "ERROR", str(e)))
                continue

            up_lit, up_dyn = parse_array(upstream_text, "depends")
            up_set = {norm_dep(x) for x in up_lit}

            missing = sorted(up_set - aur_set)
            extra = sorted(aur_set - up_set)

            label = url.rsplit("/", 2)[-2] if "/" in url else url
            if missing:
                pkg_summary.append((pkg, url, "DRIFT", f"上游有 {len(missing)} 项 AUR 没有"))
                for d in missing:
                    rows.append((pkg, label, d, "MISSING", "上游声明，AUR depends 中缺失"))
            else:
                pkg_summary.append((pkg, url, "OK", f"{len(up_set)} 项一致"))

            # AUR 比上游多：通常是合理的（重打包补了真实运行库），只作信息
            for d in extra:
                rows.append((pkg, label, d, "EXTRA", "AUR 有、上游没有（多为合理补充）"))

            for d in sorted(up_dyn):
                rows.append((pkg, label, d, "DYNAMIC", "含变量，无法静态比对"))

    print(format_report(pkg_summary, rows))
    return 0


def format_report(pkg_summary, rows):
    drift = sum(1 for _, _, v, _ in pkg_summary if v == "DRIFT")
    errors = sum(1 for _, _, v, _ in pkg_summary if v == "ERROR")
    out = ["## 上游依赖漂移检测", "", f"- 检查时间：{now_utc()}", f"- 检查包数：{len({p for p, _, _, _ in pkg_summary})}"]
    out.append(f"- 上游源数量：{len(pkg_summary)}")
    out.append(f"- 发现漂移：{drift}")
    out.append(f"- 取数失败：{errors}")
    out.append("")
    if drift:
        out.append(f"> **{drift} 处上游新增依赖未跟进**，见下方 ❌ 行。这些包可能装上后缺库。")
    elif errors:
        out.append(f"> 未发现漂移，但有 {errors} 处取数失败，结果不完整。")
    else:
        out.append("> 上游 depends 与 AUR 已发布包一致。")
    out.append("")
    out.append("| 包 | 上游源 | 结果 | 说明 |")
    out.append("|---|---|---|---|")
    for pkg, url, verdict, detail in pkg_summary:
        icon = {"OK": "✅", "DRIFT": "❌", "ERROR": "⚠️"}.get(verdict, "·")
        short = url if len(url) <= 70 else url[:67] + "..."
        out.append(f"| {pkg} | `{short}` | {icon} {verdict} | {detail} |")
    detailed = [r for r in rows if r[3] in ("MISSING", "ERROR")]
    if detailed:
        out.append("")
        out.append("### 需要处理")
        out.append("")
        out.append("| 包 | 源 | 依赖 | 结果 | 说明 |")
        out.append("|---|---|---|---|---|")
        for pkg, src, dep, verdict, detail in detailed:
            icon = "❌" if verdict == "MISSING" else "⚠️"
            out.append(f"| {pkg} | `{src}` | `{dep}` | {icon} {verdict} | {detail} |")
    extra_rows = [r for r in rows if r[3] == "EXTRA"]
    if extra_rows:
        # 同一个包可能配置了多个上游源（如 fork + 官方），按 包+依赖 去重
        seen, uniq = set(), []
        for pkg, _src, dep, _, _ in extra_rows:
            if (pkg, dep) in seen:
                continue
            seen.add((pkg, dep))
            uniq.append((pkg, dep))
        out.append("")
        out.append("<details><summary>AUR 比上游多出的依赖（仅供核对，通常合理）</summary>")
        out.append("")
        for pkg, dep in uniq:
            out.append(f"- {pkg}: `{dep}`")
        out.append("")
        out.append("</details>")
    return "\n".join(out)


def now_utc():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


if __name__ == "__main__":
    sys.exit(main())
