#!/usr/bin/env python3
"""Build the 14-slide Vietnamese deck 'Spot + Karpenter' from Template - Remake.pptx.

Usage:
  deck/.venv/bin/python deck/build_deck.py [--results PATH] [--out PATH]

* Speaker notes come from deck/script.md blocks '<!-- notes:slide-NN -->'.
* Numbers come only from --results (demo/results/summary.json). A metric with n == 0
  is rendered as a placeholder ('Đo: ___', 'TARGET: ___ s (điền sau khi đo)',
  'Ước tính (OpenCost, giá list): $___/giờ'); each cell follows its own metric's n.
* A summary with meta.synthetic=true is refused unless --out is under /tmp; in that case
  every numeric cell is prefixed 'SYNTHETIC '. Synthetic data never reaches the canonical deck.
Exit codes: 0 ok, 2 bad input / refusal, 3 build error.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.dml.color import RGBColor
from pptx.enum.chart import XL_CHART_TYPE, XL_LABEL_POSITION
from pptx.enum.lang import MSO_LANGUAGE_ID
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Inches, Pt

from lxml import etree

DECK_DIR = Path(__file__).resolve().parent
ROOT = DECK_DIR.parent
DEFAULT_TEMPLATE = ROOT / "Template - Remake.pptx"
DEFAULT_SCRIPT = DECK_DIR / "script.md"
DEFAULT_RESULTS = ROOT / "demo" / "results" / "summary.json"
DEFAULT_OUT = DECK_DIR / "karpenter-spot-finops.pptx"

FONT = "Arial"
MONO = "Courier New"
ALLOWED_LAYOUTS = ("Title Slide", "Contents", "Section slide")

# Palette (design 10.3)
BG = "08041B"
WHITE = "FFFFFF"
SOFT = "E6E4F5"
DARK = "08041B"
CARD = "17132E"
EDGE = "4B4678"
ORANGE = "FCA019"
SPOT = "4EA72E"
ONDEMAND = "0F9ED5"
WARN = "E97132"
SCALERS = [
    ("ca", "Cluster Autoscaler", ONDEMAND),
    ("karpenter", "Karpenter", ORANGE),
    ("automode", "EKS Auto Mode", SPOT),
]

PH_MEASURE = "Đo: ___"
PH_TARGET = "TARGET: ___ s (điền sau khi đo)"
PH_COST = "Ước tính (OpenCost, giá list): $___/giờ"

# Slide 10 qualitative text: architecture facts only (design 10.2)
TABLE_ARCH = {
    "cost": {
        "ca": "Node group có kích thước instance cố định. ",
        "karpenter": "Chọn instance theo pod, có consolidation. ",
        "automode": "Cơ chế như Karpenter, cộng phí quản lý ≈12% giá On-Demand. ",
    },
    "scaleup": {
        "ca": "Pending → ASG → node group → node. ",
        "karpenter": "Gọi thẳng EC2 Fleet API, không qua ASG. ",
        "automode": "Karpenter do AWS vận hành. ",
    },
    "chaos": {
        "ca": "Tùy cấu hình node group Spot (Capacity Rebalancing). ",
        "karpenter": "Nghe cảnh báo qua SQS, drain node, chọn instance khác. ",
        "automode": "AWS xử lý cảnh báo Spot và node lỗi. ",
    },
    "ops": {
        "ca": "Tự quản node group, AMI, nâng cấp",
        "karpenter": "Tự cài Helm + IAM + SQS; tự viết NodePool",
        "automode": "AWS quản lý node; node thay mới định kỳ (mặc định 14 ngày, tối đa 21)",
    },
}
TABLE_FOOTNOTE = (
    "Ước tính theo giá list (Spot theo snapshot 2026-10-20, ap-southeast-1) · "
    "CA: cấu hình mặc định của node group Spot, scale-down chỉnh 2 phút · n = 3 · 1 region · 1 buổi"
)

YAML_TEXT = """kind: NodePool
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          values: ["spot", "on-demand"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "8\""""

SLIDES = [
    {"n": 1, "layout": "Title Slide", "title": "Spot + Karpenter: Uptime cao, chi phí thấp"},
    {"n": 2, "layout": "Contents", "title": "Vì sao phải quan tâm chi phí cloud?",
     "lead": "Hôm nay: trả lời một câu hỏi trong 15 phút."},
    {"n": 3, "layout": "Contents", "title": "Spot Instance trong một bức tranh",
     "lead": "Spot = phần dung lượng dư của AWS, bán giảm giá."},
    {"n": 4, "layout": "Contents", "title": "Workload nào hợp với Spot?",
     "lead": "Câu hỏi: nếu node bị tắt ngay bây giờ, chuyện gì xảy ra?"},
    {"n": 5, "layout": "Section slide", "title": "Cluster hết chỗ: Pod Pending",
     "lead": "Pod đã xin máy, nhưng chưa ai thêm máy cho nó."},
    {"n": 6, "layout": "Contents", "title": "3 cách thêm node cho EKS",
     "lead": "Cả ba thêm node khi có Pod Pending. Khác nhau ở cách làm."},
    {"n": 7, "layout": "Contents", "title": "Karpenter hoạt động thế nào",
     "lead": "Hai mảnh cấu hình, bốn bước, một hàng đợi cảnh báo."},
    {"n": 8, "layout": "Contents", "title": "Demo: 1 cluster, 3 autoscaler, 1 ứng dụng", "lead": None},
    {"n": 9, "layout": "Contents", "title": "Đo chi phí bằng OpenCost",
     "lead": "Prometheus thu số liệu, OpenCost nhân với giá, ra chi phí theo namespace."},
    {"n": 10, "layout": "Contents", "title": "So sánh: CA vs Karpenter vs Auto Mode", "lead": None},
    {"n": 11, "layout": "Contents", "title": "Demo 1: Scale-up bao nhiêu giây?",
     "lead": "Từ Pod Pending đến node Ready: bao nhiêu giây?"},
    {"n": 12, "layout": "Contents", "title": "Demo 2: Rút điện một node",
     "lead": "Tắt một node đang chạy: ứng dụng có sống không?"},
    {"n": 13, "layout": "Contents", "title": "Bài học & những cái bẫy",
     "lead": "Sáu việc cần làm trước khi tin vào Spot."},
    {"n": 14, "layout": "Contents", "title": "Mang về nhà", "lead": "Ba điều mang về."},
]


# --------------------------------------------------------------------------- results

class BuildError(Exception):
    pass


def load_results(path):
    """Return the parsed summary or None when the file is absent."""
    if path is None or not Path(path).is_file():
        return None
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BuildError(f"cannot read results {path}: {exc}")
    if not isinstance(data, dict) or "scalers" not in data:
        raise BuildError(f"results {path}: missing 'scalers'")
    return data


def metric(summary, scaler, group, name):
    """(median, n) for a metric; (None, 0) when absent or n == 0."""
    if not summary:
        return None, 0
    try:
        m = summary["scalers"][scaler][group][name]
    except (KeyError, TypeError):
        return None, 0
    n = m.get("n") or 0
    if n >= 1 and m.get("median") is not None:
        return m["median"], n
    return None, 0


def scaler_status(summary, scaler):
    if not summary:
        return "TARGET"
    try:
        return summary["scalers"][scaler].get("status", "TARGET")
    except (KeyError, TypeError):
        return "TARGET"


def fmt_num(v):
    return f"{v:g}"


def fmt_cost(v):
    return f"{v:.3f}"


def fmt_pct(v):
    return f"{v:.1f}"


def get_value(summary, scaler, group, name):
    try:
        return summary["scalers"][scaler][group][name]
    except (KeyError, TypeError):
        return None


def cell_seconds(summary, scaler, group, name, syn):
    med, _ = metric(summary, scaler, group, name)
    return f"{syn}Đo: {fmt_num(med)} s" if med is not None else f"{PH_MEASURE} s"


def cell_cost(summary, scaler, syn):
    v = get_value(summary, scaler, "cost", "opencost_per_hour_usd")
    if v is None:
        return PH_COST
    return f"{syn}Ước tính (OpenCost, giá list): ${fmt_cost(v)}/giờ"


def cell_fail_pct(summary, scaler, syn):
    v = get_value(summary, scaler, "chaos", "probe_failed_pct")
    return f"{syn}{fmt_pct(v)}% lỗi" if v is not None else "___% lỗi"


# --------------------------------------------------------------------------- notes

NOTES_RE = re.compile(r"<!--\s*notes:slide-(\d\d)\s*-->(.*?)<!--\s*/notes:slide-\1\s*-->", re.S)


def parse_notes(script_path):
    try:
        text = Path(script_path).read_text(encoding="utf-8")
    except OSError as exc:
        raise BuildError(f"cannot read {script_path}: {exc}")
    notes = {int(m.group(1)): m.group(2).strip() for m in NOTES_RE.finditer(text)}
    missing = [s["n"] for s in SLIDES if s["n"] not in notes]
    if missing:
        raise BuildError(f"script.md lacks notes blocks for slides {missing}")
    return notes


# --------------------------------------------------------------------------- drawing helpers

def rgb(hex_):
    return RGBColor.from_string(hex_)


def _strip_style(shape):
    st = shape._element.find(qn("p:style"))
    if st is not None:
        shape._element.remove(st)


def _no_bullet(paragraph):
    pPr = paragraph._p.get_or_add_pPr()
    pPr.set("marL", "0")
    pPr.set("indent", "0")
    for child in list(pPr):
        if child.tag in (qn("a:buNone"), qn("a:buChar"), qn("a:buAutoNum")):
            pPr.remove(child)
    etree.SubElement(pPr, qn("a:buNone"))


def _add_run(par, text, size, color, bold=False, font=FONT):
    r = par.add_run()
    r.text = text
    f = r.font
    f.name = font
    f.size = Pt(size)
    f.bold = bold
    f.color.rgb = rgb(color)
    f.language_id = MSO_LANGUAGE_ID.VIETNAMESE
    return r


def _norm_paras(paras):
    """Normalise to a list of paragraphs; each is a list of (text, opts) runs."""
    if isinstance(paras, (str, tuple)):
        paras = [paras]
    out = []
    for p in paras:
        if isinstance(p, str):
            out.append([(p, {})])
        elif isinstance(p, tuple):
            out.append([p])
        else:
            out.append(list(p))
    return out


def fill_frame(tf, paras, size=20, color=WHITE, bold=False, align="l", font=FONT, space_after=0):
    amap = {"l": PP_ALIGN.LEFT, "c": PP_ALIGN.CENTER, "r": PP_ALIGN.RIGHT}
    first = True
    for runs in _norm_paras(paras):
        par = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        par.alignment = amap[align]
        if space_after:
            par.space_after = Pt(space_after)
        for text, opts in runs:
            _add_run(par, text, opts.get("size", size), opts.get("color", color),
                     opts.get("bold", bold), opts.get("font", font))
    return tf


def add_text(slide, name, x, y, w, h, paras, size=20, color=WHITE, bold=False, align="l",
             anchor="t", fill=None, line=None, line_w=1.5, font=FONT, round_=False, margin=0.1,
             space_after=0):
    """Rectangle/rounded text shape. Inches for geometry."""
    kind = MSO_SHAPE.ROUNDED_RECTANGLE if round_ else MSO_SHAPE.RECTANGLE
    shp = slide.shapes.add_shape(kind, Inches(x), Inches(y), Inches(w), Inches(h))
    _strip_style(shp)
    shp.name = name
    if round_:
        shp.adjustments[0] = 0.08
    if fill:
        shp.fill.solid()
        shp.fill.fore_color.rgb = rgb(fill)
    else:
        shp.fill.background()
    if line:
        shp.line.color.rgb = rgb(line)
        shp.line.width = Pt(line_w)
    else:
        shp.line.fill.background()
    tf = shp.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = Inches(margin)
    tf.margin_top = tf.margin_bottom = Inches(0.05)
    tf.vertical_anchor = {"t": MSO_ANCHOR.TOP, "m": MSO_ANCHOR.MIDDLE, "b": MSO_ANCHOR.BOTTOM}[anchor]
    fill_frame(tf, paras, size, color, bold, align, font, space_after)
    return shp


def add_card(slide, name, x, y, w, h, header, body_paras, accent, header_h=0.6, header_size=24,
             body_size=22):
    """Accent header bar (dark text) over a dark body with accent outline."""
    add_text(slide, f"{name}-body", x, y + header_h, w, h - header_h, body_paras, size=body_size,
             fill=CARD, line=accent, margin=0.15, space_after=4)
    add_text(slide, f"{name}-head", x, y, w, header_h, header, size=header_size, color=DARK, bold=True,
             anchor="m", fill=accent, margin=0.15)


def add_arrow(slide, name, x, y, w, h, color=SOFT, direction="right"):
    kind = MSO_SHAPE.RIGHT_ARROW if direction == "right" else MSO_SHAPE.DOWN_ARROW
    shp = slide.shapes.add_shape(kind, Inches(x), Inches(y), Inches(w), Inches(h))
    _strip_style(shp)
    shp.name = name
    shp.fill.solid()
    shp.fill.fore_color.rgb = rgb(color)
    shp.line.fill.background()
    return shp


def add_flow(slide, name, x, y, w, h, labels, colors, size=20, gap=0.5, text_colors=None):
    """Row of boxes joined by right arrows; total width w."""
    n = len(labels)
    bw = (w - gap * (n - 1)) / n
    for i, label in enumerate(labels):
        bx = x + i * (bw + gap)
        tc = (text_colors[i] if text_colors else DARK)
        add_text(slide, f"{name}-{i + 1}", bx, y, bw, h, label, size=size, color=tc, bold=True,
                 align="c", anchor="m", fill=colors[i], round_=True)
        if i < n - 1:
            add_arrow(slide, f"{name}-arrow-{i + 1}", bx + bw + 0.08, y + h / 2 - 0.2, gap - 0.16, 0.4)


def set_cell_border(cell, color=BG, width=19050):
    tcPr = cell._tc.get_or_add_tcPr()
    for tag in ("a:lnL", "a:lnR", "a:lnT", "a:lnB"):
        for old in tcPr.findall(qn(tag)):
            tcPr.remove(old)
    # borders must precede the fill element in tcPr
    first_fill = None
    for child in tcPr:
        if child.tag in (qn("a:solidFill"), qn("a:noFill")):
            first_fill = child
            break
    for tag in ("a:lnL", "a:lnR", "a:lnT", "a:lnB"):
        ln = etree.Element(qn(tag), w=str(width), cap="flat", cmpd="sng", algn="ctr")
        sf = etree.SubElement(ln, qn("a:solidFill"))
        etree.SubElement(sf, qn("a:srgbClr"), val=color)
        etree.SubElement(ln, qn("a:prstDash"), val="solid")
        if first_fill is not None:
            first_fill.addprevious(ln)
        else:
            tcPr.append(ln)


def add_table(slide, name, x, y, w, col_w, rows, header_fill=ORANGE, size=14):
    """rows: list of rows; each cell is a paragraph spec (str / runs). Row 0 is the header."""
    nrows, ncols = len(rows), len(rows[0])
    gf = slide.shapes.add_table(nrows, ncols, Inches(x), Inches(y), Inches(w), Inches(0.5 * nrows))
    gf.name = name
    tbl = gf.table
    tblPr = tbl._tbl.tblPr
    sid = tblPr.find(qn("a:tableStyleId"))
    if sid is None:
        sid = etree.SubElement(tblPr, qn("a:tableStyleId"))
    sid.text = "{2D5ABB26-0587-4C30-8999-92F81FD0307C}"  # No Style, No Grid
    tbl.first_row = True
    tbl.horz_banding = False
    for i, cw in enumerate(col_w):
        tbl.columns[i].width = Inches(cw)
    for r, row in enumerate(rows):
        tbl.rows[r].height = Inches(0.45 if r == 0 else 0.7)
        for c, spec in enumerate(row):
            cell = tbl.cell(r, c)
            cell.margin_left = cell.margin_right = Inches(0.1)
            cell.margin_top = cell.margin_bottom = Inches(0.05)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            cell.fill.solid()
            if r == 0:
                cell.fill.fore_color.rgb = rgb(header_fill)
                fill_frame(cell.text_frame, spec, size=size + 2, color=DARK, bold=True)
            else:
                cell.fill.fore_color.rgb = rgb(CARD if c else "221D45")
                fill_frame(cell.text_frame, spec, size=size, color=WHITE, bold=(c == 0))
            cell.text_frame.word_wrap = True
            set_cell_border(cell)
    return gf


def add_bar_chart(slide, name, x, y, w, h, categories, values, colors, syn=""):
    cd = CategoryChartData(number_format="0")
    cd.categories = categories
    cd.add_series(f"{syn}node_provision_s (giây)", values)
    gf = slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(x), Inches(y), Inches(w),
                                Inches(h), cd)
    gf.name = name
    ch = gf.chart
    ch.has_legend = False
    ch.has_title = False
    ch.font.size = Pt(16)
    ch.font.name = FONT
    ch.font.color.rgb = rgb(WHITE)
    plot = ch.plots[0]
    plot.gap_width = 80
    plot.has_data_labels = True
    dl = plot.data_labels
    dl.font.size = Pt(18)
    dl.font.bold = True
    dl.font.color.rgb = rgb(WHITE)
    dl.number_format = "0"
    dl.number_format_is_linked = False
    dl.position = XL_LABEL_POSITION.OUTSIDE_END
    ser = plot.series[0]
    for i, col in enumerate(colors):
        pt = ser.points[i]
        pt.format.fill.solid()
        pt.format.fill.fore_color.rgb = rgb(col)
    va = ch.value_axis
    va.has_major_gridlines = True
    va.major_gridlines.format.line.color.rgb = rgb(EDGE)
    va.format.line.color.rgb = rgb(EDGE)
    va.minimum_scale = 0
    va.tick_labels.font.size = Pt(14)
    va.tick_labels.font.color.rgb = rgb(SOFT)
    va.has_title = True
    va.axis_title.text_frame.text = "giây"
    for par in va.axis_title.text_frame.paragraphs:
        for r in par.runs:
            r.font.size = Pt(14)
            r.font.color.rgb = rgb(SOFT)
            r.font.name = FONT
    ca = ch.category_axis
    ca.tick_labels.font.size = Pt(16)
    ca.tick_labels.font.color.rgb = rgb(WHITE)
    ca.format.line.color.rgb = rgb(EDGE)
    return gf


def set_placeholder(ph, paras, size, color=WHITE, bold=False, geom=None, align="l", anchor=None):
    if geom:
        ph.left, ph.top, ph.width, ph.height = (Inches(v) for v in geom)
    tf = ph.text_frame
    tf.word_wrap = True
    for p in list(tf.paragraphs)[1:]:
        p._p.getparent().remove(p._p)
    first = tf.paragraphs[0]
    for r in list(first.runs):
        r._r.getparent().remove(r._r)
    fill_frame(tf, paras, size, color, bold, align)
    for par in tf.paragraphs:
        _no_bullet(par)
    if anchor:
        tf.vertical_anchor = {"t": MSO_ANCHOR.TOP, "m": MSO_ANCHOR.MIDDLE, "b": MSO_ANCHOR.BOTTOM}[anchor]


def drop_unused_placeholders(slide, keep):
    for ph in list(slide.placeholders):
        if ph.placeholder_format.idx not in keep:
            ph._element.getparent().remove(ph._element)


def footnote(slide, name, text, y=6.12, h=0.45):
    add_text(slide, name, 0.5, y, 12.3, h, text, size=12, color=SOFT, anchor="m")


def ph_by_idx(slide, idx):
    for ph in slide.placeholders:
        if ph.placeholder_format.idx == idx:
            return ph
    raise BuildError(f"placeholder idx {idx} missing on layout {slide.slide_layout.name}")


# --------------------------------------------------------------------------- per-slide builders

def contents_header(slide, spec):
    set_placeholder(ph_by_idx(slide, 0), spec["title"], 28, WHITE, True)
    if spec.get("lead"):
        set_placeholder(ph_by_idx(slide, 10), spec["lead"], 20, SOFT, geom=(0.504, 1.12, 12.3, 0.55))
        drop_unused_placeholders(slide, {0, 10})
    else:
        drop_unused_placeholders(slide, {0})


def s01(slide, spec, ctx):
    set_placeholder(ph_by_idx(slide, 15), ["Spot + Karpenter:", "Uptime cao, chi phí thấp"], 36, WHITE, True,
                    geom=(0.5, 1.7, 6.9, 1.6), anchor="b")
    set_placeholder(ph_by_idx(slide, 16), "Talk 15 phút về FinOps trên EKS", 22, ORANGE,
                    geom=(0.5, 3.45, 6.9, 0.5))
    set_placeholder(ph_by_idx(slide, 13), "Lê Kiến Troup", 24, WHITE, True, geom=(0.5, 4.56, 6.9, 0.45))
    set_placeholder(ph_by_idx(slide, 14), "Platform Architect, Enops", 20, SOFT, geom=(0.5, 4.96, 6.9, 0.4))
    drop_unused_placeholders(slide, {13, 14, 15, 16})


def s02(slide, spec, ctx):
    contents_header(slide, spec)
    add_text(slide, "s02-bignumber", 0.5, 1.9, 4.6, 3.1,
             [("10-20%", {"size": 80, "bold": True, "color": ORANGE}),
              ("chi phí vận hành là tiền cloud (kinh nghiệm diễn giả)", {"size": 20})],
             fill=CARD, line=ORANGE, align="c", anchor="m", round_=True)
    add_text(slide, "s02-question", 5.4, 1.9, 7.4, 3.1,
             ["~100% uptime", "mà không đốt tiền?"], size=40, bold=True, color=WHITE, fill=CARD,
             line=EDGE, anchor="m", align="c", round_=True)
    chips = [("1  Spot", SPOT), ("2  Thêm node", ONDEMAND), ("3  Demo đo đạc", ORANGE), ("4  Cái bẫy", WARN)]
    for i, (label, col) in enumerate(chips):
        add_text(slide, f"s02-chip-{i + 1}", 0.5 + i * 3.1, 5.25, 2.95, 0.75, label, size=20, color=DARK,
                 bold=True, fill=col, anchor="m", align="c", round_=True)
    footnote(slide, "s02-footnote", "Nguồn: kinh nghiệm của diễn giả tại Enops (không phải thống kê công bố)",
             y=6.15, h=0.4)


def s03(slide, spec, ctx):
    contents_header(slide, spec)
    cell, gap = 0.22, 0.04
    for i in range(100):
        r, c = divmod(i, 10)
        col = ONDEMAND if i < 70 else SPOT
        shp = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0.5 + c * (cell + gap)),
                                     Inches(1.9 + r * (cell + gap)), Inches(cell), Inches(cell))
        _strip_style(shp)
        shp.name = f"s03-cell-{i + 1:03d}"
        shp.fill.solid()
        shp.fill.fore_color.rgb = rgb(col)
        shp.line.fill.background()
    add_text(slide, "s03-legend-ondemand", 0.5, 4.6, 4.4, 0.45, "70 ô: bán đủ giá (On-Demand)", size=20,
             color=ONDEMAND, bold=True, anchor="m")
    add_text(slide, "s03-legend-spot", 0.5, 5.1, 4.4, 0.45, "30 ô: giảm giá (Spot)", size=20,
             color=SPOT, bold=True, anchor="m")
    add_text(slide, "s03-badge-discount", 5.2, 1.9, 3.8, 1.9,
             [("Giảm 50-70%", {"size": 34, "bold": True}), ("AWS: điển hình, tới ~90%", {"size": 20})],
             color=DARK, fill=SPOT, anchor="m", align="c", round_=True)
    add_text(slide, "s03-badge-clock", 9.2, 1.9, 3.6, 1.9,
             [("2 phút", {"size": 34, "bold": True}), ("báo trước khi bị thu hồi", {"size": 20})],
             color=DARK, fill=ORANGE, anchor="m", align="c", round_=True)
    add_text(slide, "s03-analogy", 5.2, 4.1, 7.6, 1.5,
             "Như taxi còn trống chạy giá rẻ: nhưng có thể bị gọi về bất cứ lúc nào.", size=22,
             color=WHITE, anchor="m")
    footnote(slide, "s03-footnote",
             "Snapshot ap-southeast-1, 2026-10-20: Spot thấp hơn On-Demand khoảng 54-67% (giá list, ước tính). "
             "Nguồn: trang AWS Spot, snapshot của demo.", y=6.05, h=0.5)


def s04(slide, spec, ctx):
    contents_header(slide, spec)
    add_card(slide, "s04-fit", 0.5, 1.9, 6.0, 3.0, "Hợp với Spot",
             ["• Web không giữ trạng thái", "• Worker / hàng đợi", "• Batch, CI"], SPOT, body_size=28)
    add_card(slide, "s04-nofit", 6.8, 1.9, 6.0, 3.0, "Không hợp",
             ["• Database một bản", "• Việc không thể làm lại", "• Node hệ thống"], WARN, body_size=28)
    add_text(slide, "s04-banner", 0.5, 5.2, 12.3, 0.9,
             "Cái gì có thể hỏng thì sẽ hỏng: hãy rút dây điện thử trước.", size=24, color=DARK, bold=True,
             fill=ORANGE, anchor="m", align="c", round_=True)


def s05(slide, spec, ctx):
    set_placeholder(ph_by_idx(slide, 0), ["Cluster hết chỗ:", "Pod Pending"], 36, WHITE, True,
                    geom=(0.504, 2.2, 6.3, 1.5), anchor="b")
    set_placeholder(ph_by_idx(slide, 1), spec["lead"], 22, SOFT, geom=(0.5, 3.85, 6.0, 1.0))
    drop_unused_placeholders(slide, {0, 1})


def s06(slide, spec, ctx):
    contents_header(slide, spec)
    cards = [
        ("Cluster Autoscaler", ONDEMAND,
         ["Pod Pending → Auto Scaling Group → node group → node", "Loại máy cố định theo node group"]),
        ("Karpenter", ORANGE,
         ["Pod Pending → EC2 Fleet API → node", "Chọn máy vừa đủ theo nhu cầu Pod"]),
        ("EKS Auto Mode", SPOT,
         ["Karpenter do AWS vận hành", "Có phí quản lý ≈12% giá On-Demand"]),
    ]
    for i, (name, col, body) in enumerate(cards):
        add_card(slide, f"s06-card-{i + 1}", 0.5 + i * 4.18, 1.9, 3.95, 3.3, name, body, col,
                 header_h=0.7, body_size=22)
    footnote(slide, "s06-footnote", "Phí Auto Mode: ước tính theo giá list ngày 2026-10-20. "
             "Trong demo, \"kube net auto scaler\" được hiểu là EKS Auto Mode.", y=6.05, h=0.5)


def s07(slide, spec, ctx):
    contents_header(slide, spec)
    steps = ["1  Thấy Pod Pending", "2  Chọn máy vừa đủ", "3  Gọi EC2 Fleet API", "4  Gắn Pod vào node"]
    cols = [ORANGE, ORANGE, ORANGE, ORANGE]
    for i, s in enumerate(steps):
        add_text(slide, f"s07-step-{i + 1}", 0.5, 1.85 + i * 0.85, 5.6, 0.72, s, size=22, color=DARK, bold=True,
                 fill=cols[i], anchor="m", round_=True, margin=0.2)
    add_text(slide, "s07-yaml", 6.4, 1.85, 6.4, 3.3, YAML_TEXT.split("\n"), size=14, color=SOFT, font=MONO,
             fill=CARD, line=EDGE, margin=0.2, anchor="m")
    add_text(slide, "s07-sqs", 0.5, 5.4, 12.3, 0.8,
             "Spot sắp bị thu hồi → EventBridge → SQS → Karpenter dọn node", size=20, color=DARK, bold=True,
             fill=WARN, anchor="m", align="c", round_=True)


def s08(slide, spec, ctx):
    contents_header(slide, spec)
    frame = add_text(slide, "diagram-frame", 0.5, 1.45, 12.33, 5.0, "", size=16, line=EDGE, line_w=2,
                     round_=True)
    frame.adjustments[0] = 0.03
    add_text(slide, "diagram-title", 0.7, 1.5, 11.9, 0.4, "EKS 1.35 · ap-southeast-1 · 3 AZ", size=16,
             color=SOFT, bold=True, anchor="m")
    add_text(slide, "diagram-system", 0.7, 2.0, 5.6, 0.85,
             "Node hệ thống: 2 × On-Demand (CoreDNS, Karpenter, CA, OpenCost)", size=16, color=WHITE,
             fill="2A2650", anchor="m", round_=True)
    add_text(slide, "diagram-opencost", 6.5, 2.0, 6.1, 0.85,
             "Prometheus + OpenCost: chi phí theo namespace (ước tính)", size=16, color=WHITE,
             fill="2A2650", anchor="m", round_=True)
    pools = [
        ("Cluster Autoscaler", "pool ca · Spot node group, 0-4 node", "scaler=ca", ONDEMAND, "boutique-ca"),
        ("Karpenter", "pool karpenter · NodePool Spot + On-Demand", "scaler=karpenter", ORANGE,
         "boutique-karpenter"),
        ("EKS Auto Mode", "pool automode · NodePool do AWS quản lý", "scaler=automode", SPOT,
         "boutique-automode"),
    ]
    for i, (name, l2, l3, col, ns) in enumerate(pools):
        x = 0.7 + i * 4.065
        add_text(slide, f"diagram-pool-{i + 1}", x, 3.1, 3.8, 1.75,
                 [(name, {"size": 18, "bold": True}), l2, f"nhãn + taint {l3}"], size=16, color=DARK, fill=col,
                 anchor="m", round_=True, margin=0.15)
        add_text(slide, f"diagram-ns-{i + 1}", x, 5.0, 3.8, 0.55, f"namespace {ns}", size=16, color=WHITE,
                 line=col, line_w=2, anchor="m", align="c", round_=True)
    add_text(slide, "diagram-note", 0.7, 5.7, 11.9, 0.6,
             "Cùng một chart Online Boutique · cùng số replica · PDB + topology spread", size=16, color=SOFT,
             anchor="m", align="c")


def s09(slide, spec, ctx):
    contents_header(slide, spec)
    add_flow(slide, "s09-flow", 0.5, 1.95, 12.3, 1.25,
             ["Pod: CPU + RAM", "Prometheus", "OpenCost", ["Chi phí theo", "namespace", "(ước tính)"]],
             [ONDEMAND, ORANGE, SPOT, WARN], size=20, gap=0.55)
    reasons = ["Mã nguồn mở (CNCF)", "Nhẹ: một Prometheus nhỏ", "Đủ dùng cho bài này"]
    for i, r in enumerate(reasons):
        add_text(slide, f"s09-reason-{i + 1}", 0.5 + i * 4.18, 3.55, 3.95, 1.5, r, size=22, bold=True,
                 fill=CARD, line=EDGE, anchor="m", align="c", round_=True)
    add_text(slide, "s09-callout", 0.5, 5.3, 12.3, 0.85,
             "Ước tính theo giá list, không phải hóa đơn AWS. Kubecost = bản thương mại.", size=20,
             color=DARK, bold=True, fill=ORANGE, anchor="m", align="c", round_=True)


def s10(slide, spec, ctx):
    contents_header(slide, spec)
    summary, syn = ctx["summary"], ctx["syn"]
    emph = {"bold": True, "color": ORANGE}
    ids = [s[0] for s in SCALERS]

    def measure(sid, group, name):
        return (cell_seconds(summary, sid, group, name, syn), emph)

    rows = [["Tiêu chí"] + [s[1] for s in SCALERS]]
    rows.append([
        "1. Chi phí (ước tính)",
        *[[(TABLE_ARCH["cost"][sid], {}),
           (cell_cost(summary, sid, syn) + (", chưa gồm phí" if sid == "automode" else ""), emph)]
          for sid in ids]])
    rows.append([
        "2. Thời gian scale-up (Pending → Ready)",
        *[[(TABLE_ARCH["scaleup"][sid], {}), measure(sid, "scaleup", "node_provision_s")] for sid in ids]])
    rows.append([
        "3. Chịu lỗi (Spot bị thu hồi / node chết)",
        *[[(TABLE_ARCH["chaos"][sid], {}),
           (cell_seconds(summary, sid, "chaos", "recovery_s", syn) + ", " + cell_fail_pct(summary, sid, syn),
            emph)] for sid in ids]])
    rows.append(["4. Độ phức tạp vận hành", *[TABLE_ARCH["ops"][sid] for sid in ids]])
    add_table(slide, "s10-table", 0.5, 1.4, 12.3, [2.4, 3.3, 3.3, 3.3], rows, size=16)
    add_text(slide, "s10-footnote", 0.5, 5.95, 12.3, 0.6, TABLE_FOOTNOTE, size=12, color=SOFT, anchor="m")


def card_row(slide, prefix, y, h, summary, syn, lines_fn, header_size=22):
    for i, (sid, name, col) in enumerate(SCALERS):
        x = 0.5 + i * 4.18
        add_card(slide, f"{prefix}-{sid}-card", x, y, 3.95, h, name, "", col, header_h=0.55,
                 header_size=header_size)
        lines_fn(slide, sid, x, y + 0.65, h - 0.7)


def s11(slide, spec, ctx):
    contents_header(slide, spec)
    summary, syn = ctx["summary"], ctx["syn"]
    has_chart = any(metric(summary, sid, "scaleup", "node_provision_s")[1] >= 1 for sid, _, _ in SCALERS)
    if has_chart:
        cats = [n for _, n, _ in SCALERS]
        vals = [metric(summary, sid, "scaleup", "node_provision_s")[0] for sid, _, _ in SCALERS]
        add_bar_chart(slide, "s11-chart", 0.5, 1.7, 12.3, 1.7, cats, vals, [c for _, _, c in SCALERS], syn)
        y, h = 3.45, 2.6
    else:
        y, h = 1.9, 2.7

    def lines(slide_, sid, x, ly, lh):
        med, _ = metric(summary, sid, "scaleup", "node_provision_s")
        allp, _ = metric(summary, sid, "scaleup", "all_pods_running_s")
        ph_h, all_y, badge_y = 0.75, ly + 0.77, ly + 1.5
        add_text(slide_, f"s11-{sid}-prov", x + 0.05, ly, 3.85, ph_h,
                 f"{syn}{fmt_num(med)} s" if med is not None else PH_TARGET, size=22, bold=True, anchor="m")
        add_text(slide_, f"s11-{sid}-all", x + 0.05, all_y, 3.85, 0.7,
                 f"Pod chạy hết: {syn}{fmt_num(allp)} s" if allp is not None else f"Pod chạy hết: {PH_MEASURE} s",
                 size=20, anchor="m")
        add_text(slide_, f"s11-{sid}-badge", x + 0.05, badge_y, 3.85, 0.4,
                 f"Trạng thái: {scaler_status(summary, sid)}", size=20, color=SOFT, anchor="m")

    card_row(slide, "s11", y, h, summary, syn, lines)
    if not has_chart:
        add_text(slide, "s11-method", 0.5, 4.85, 12.3, 0.9,
                 "Cách đo: Pod Pending → node đầu tiên Ready · 4 Pod × 1 vCPU · pool bắt đầu từ 0 node",
                 size=20, color=SOFT, anchor="m")
    footnote(slide, "s11-footnote",
             "Giây: lấy từ API server, trung vị 3 lần, bỏ lần chạy lạnh. Chi phí (nếu có) chỉ là ước tính theo "
             "giá list. 1 region · 1 buổi", y=6.1, h=0.5)


def s12(slide, spec, ctx):
    contents_header(slide, spec)
    summary, syn = ctx["summary"], ctx["syn"]
    steps = [("Rút điện 1 node", WARN), ("Node thay thế lên", ORANGE), ("Pod Ready lại", SPOT)]
    bw, gap = 3.5, 0.9
    for i, (label, col) in enumerate(steps):
        x = 0.5 + i * (bw + gap)
        add_text(slide, f"s12-step-{i + 1}", x, 1.85, bw, 0.9, label, size=22, color=DARK, bold=True,
                 fill=col, anchor="m", align="c", round_=True)
        if i < 2:
            add_arrow(slide, f"s12-arrow-{i + 1}", x + bw + 0.15, 2.1, gap - 0.3, 0.4)

    def lines(slide_, sid, x, ly, lh):
        rec, _ = metric(summary, sid, "chaos", "recovery_s")
        pct = get_value(summary, sid, "chaos", "probe_failed_pct")
        add_text(slide_, f"s12-{sid}-rec", x + 0.05, ly, 3.85, 0.8,
                 f"Phục hồi: {syn}{fmt_num(rec)} s" if rec is not None else f"Phục hồi: {PH_MEASURE} s",
                 size=22, bold=True, anchor="m")
        add_text(slide_, f"s12-{sid}-fail", x + 0.05, ly + 0.85, 3.85, 0.8,
                 f"Request lỗi: {syn}{fmt_pct(pct)}%" if pct is not None else f"Request lỗi: {PH_MEASURE}%",
                 size=20, anchor="m")
        add_text(slide_, f"s12-{sid}-badge", x + 0.05, ly + 1.7, 3.85, 0.4,
                 f"Trạng thái: {scaler_status(summary, sid)}", size=20, color=SOFT, anchor="m")

    card_row(slide, "s12", 3.0, 2.95, summary, syn, lines)
    footnote(slide, "s12-footnote",
             "Thời điểm kill lấy từ đồng hồ máy chạy script: sai số khoảng 2 giây. n = 3 · 1 region · 1 buổi",
             y=6.0, h=0.5)


def s13(slide, spec, ctx):
    contents_header(slide, spec)
    items = [
        ("1  Nhiều AZ", "Rải Pod qua nhiều vùng", SPOT),
        ("2  Nhiều loại máy", "Đừng khóa một instance type", ONDEMAND),
        ("3  PodDisruptionBudget", "Giới hạn số Pod bị tắt cùng lúc", ORANGE),
        ("4  Topology spread", "Pod không dồn một chỗ", SPOT),
        ("5  Dự phòng On-Demand", "Khi Spot hết chỗ", ONDEMAND),
        ("6  Đủ IP trong subnet", "/24 = 256 IP (AWS giữ 5)", WARN),
    ]
    for i, (t, sub, col) in enumerate(items):
        r, c = divmod(i, 3)
        add_text(slide, f"s13-item-{i + 1}", 0.5 + c * 4.18, 1.85 + r * 1.75, 3.95, 1.6,
                 [(t, {"size": 22, "bold": True, "color": col}), (sub, {"size": 20})],
                 fill=CARD, line=col, anchor="m", round_=True, margin=0.15)
    add_text(slide, "s13-banner", 0.5, 5.4, 12.3, 0.7,
             "Từng có 10+ node Spot mất cùng lúc: nhờ nhiều AZ và dự phòng mà hệ thống vẫn sống.", size=20,
             color=DARK, bold=True, fill=ORANGE, anchor="m", align="c", round_=True)
    footnote(slide, "s13-footnote", "Nguồn: kinh nghiệm của diễn giả (sự cố thật); tài liệu AWS VPC (subnet CIDR)",
             y=6.15, h=0.4)


def s14(slide, spec, ctx):
    contents_header(slide, spec)
    takeaways = [("1", "Thiết kế để chịu được bị tắt"), ("2", "Đo trong hệ thống của bạn"),
                 ("3", "Đo chi phí trước khi tối ưu")]
    for i, (num, text) in enumerate(takeaways):
        add_text(slide, f"s14-chip-{i + 1}", 0.5 + i * 4.18, 1.85, 3.95, 1.5,
                 [(num, {"size": 28, "bold": True, "color": ORANGE}), (text, {"size": 22, "bold": True})],
                 fill=CARD, line=EDGE, anchor="m", align="c", round_=True)
    add_text(slide, "s14-resources", 0.5, 3.55, 12.3, 1.35,
             [("Tài liệu học tiếp", {"bold": True, "color": ORANGE}),
              "opencost.io  ·  karpenter.sh  ·  docs.aws.amazon.com/eks (EKS Auto Mode)  ·  finops.org"],
             size=16, fill=CARD, line=EDGE, anchor="m", margin=0.2, round_=True)
    add_text(slide, "s14-banner", 0.5, 5.1, 12.3, 0.8,
             "Hãy thử Spot + Karpenter với chi phí thấp nhất", size=24, color=DARK, bold=True, fill=ORANGE,
             anchor="m", align="c", round_=True)
    add_text(slide, "s14-qa", 0.5, 6.0, 12.3, 0.5, "Hỏi đáp  ·  Nhớ xóa cluster demo sau khi thử", size=20,
             color=SOFT, anchor="m", align="c")


BUILDERS = {1: s01, 2: s02, 3: s03, 4: s04, 5: s05, 6: s06, 7: s07, 8: s08, 9: s09, 10: s10, 11: s11,
            12: s12, 13: s13, 14: s14}


# --------------------------------------------------------------------------- assembly

def remove_template_slides(prs):
    lst = prs.slides._sldIdLst
    for sld in list(lst):
        rid = sld.get(qn("r:id"))
        lst.remove(sld)
        prs.part.drop_rel(rid)


def build(template, script, summary, out, synthetic):
    if not Path(template).is_file():
        raise BuildError(f"template not found: {template}")
    notes = parse_notes(script)
    prs = Presentation(str(template))
    if (prs.slide_width, prs.slide_height) != (12192000, 6858000):
        raise BuildError(f"unexpected slide size {prs.slide_width}x{prs.slide_height}")
    layouts = {l.name: l for l in prs.slide_layouts}
    for name in ALLOWED_LAYOUTS:
        if name not in layouts:
            raise BuildError(f"template lacks layout '{name}'")
    remove_template_slides(prs)
    ctx = {"summary": summary, "syn": "SYNTHETIC " if synthetic else ""}
    for spec in SLIDES:
        slide = prs.slides.add_slide(layouts[spec["layout"]])
        BUILDERS[spec["n"]](slide, spec, ctx)
        slide.notes_slide.notes_text_frame.text = notes[spec["n"]]
    cp = prs.core_properties
    cp.title = "Spot + Karpenter: Uptime cao, chi phí thấp"
    cp.author = "Lê Kiến Troup"
    cp.last_modified_by = "Lê Kiến Troup"
    cp.subject = "FinOps trên EKS: Spot, Karpenter, OpenCost"
    cp.keywords = "Spot, Karpenter, EKS Auto Mode, OpenCost, FinOps"
    cp.created = cp.modified = datetime.datetime(2026, 10, 20, 0, 0, 0)
    cp.revision = 1
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(out))


def is_under_tmp(path):
    p = Path(path).resolve()
    return p == Path("/tmp") or Path("/tmp") in p.parents


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--results", type=Path, default=DEFAULT_RESULTS,
                    help="summary.json (default demo/results/summary.json; absent file = placeholders)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    ap.add_argument("--script", type=Path, default=DEFAULT_SCRIPT)
    args = ap.parse_args(argv)
    try:
        summary = load_results(args.results)
        synthetic = bool(summary and summary.get("meta", {}).get("synthetic"))
        if synthetic and not is_under_tmp(args.out):
            print("[ERROR] refusing: results are synthetic (meta.synthetic=true); --out must be under /tmp",
                  file=sys.stderr)
            return 2
        build(args.template, args.script, summary, args.out, synthetic)
    except BuildError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 3
    print(f"[INFO] wrote {args.out}" + (" (SYNTHETIC numbers, not for presentation)" if synthetic else ""),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
