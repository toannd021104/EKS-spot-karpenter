#!/usr/bin/env python3
"""make_screenshots.py: run a fixed list of REAL offline commands and render each output as a terminal-style PNG.

Usage (from anywhere): python3 docs/make_screenshots.py [name ...]   -> docs/img/<name>.png
Needs: Pillow, DejaVu Sans Mono (fonts-dejavu-core), bash, terraform (+ provider cache), helm, jq, and presentation/.venv.

Safety: no command here calls AWS or a cluster. Subprocesses get a scrubbed environment (no AWS_*, KUBECONFIG=/dev/null),
the 01-up.sh prompt demo uses the STUB aws/terraform from scripts/tests/lib_sandbox.sh, and fill_results.py only
reads SYNTHETIC fixtures and writes below /tmp. The script refuses to write an image if the text contains a 12-digit
number other than the synthetic account ids 000000000001/000000000002, an access-key pattern or a home directory path.

Content rules: the text shown is exactly what the command printed (stdout+stderr). The only edits are
  * long outputs keep the head and tail with a visible "..." marker line,
  * the throw-away sandbox directory is replaced by <sandbox>,
  * presentation colouring of tokens that carry no colour of their own ([INFO]/[WARN]/[ERROR], ok/FAIL/PASS).
"""
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "docs" / "img"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FONT_SIZE = 16
DEFAULT_COLS = 110  # wrap width, like a terminal of that width
COLS = DEFAULT_COLS
PAD = 22
TITLE_H = 40
LINE_GAP = 4
SYNTHETIC_ACCOUNTS = {"000000000001", "000000000002"}

BG = (24, 26, 33)
TITLE_BG = (44, 47, 58)
FG = (214, 218, 226)
DIM = (125, 132, 148)
PALETTE = {  # ANSI 30-37 / 90-97
    30: (70, 74, 88), 31: (240, 96, 96), 32: (120, 214, 130), 33: (236, 200, 96),
    34: (110, 160, 250), 35: (200, 130, 230), 36: (96, 210, 220), 37: FG,
    90: DIM, 91: (255, 130, 130), 92: (150, 235, 160), 93: (250, 220, 130),
    94: (140, 185, 255), 95: (225, 160, 250), 96: (130, 230, 235), 97: (245, 247, 250),
}
PROMPT_GREEN = (120, 214, 130)
ANSI_RE = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")
# presentation colouring for plain output: (regex, colour, bold)
TOKEN_STYLES = [
    (re.compile(r"\[ERROR\]|\bFAIL\b"), PALETTE[31], True),
    (re.compile(r"\[WARN\]"), PALETTE[33], True),
    (re.compile(r"\[INFO\]"), PALETTE[36], True),
    (re.compile(r"\bPASS\b|(?<=  )ok(?=   )"), PALETTE[32], True),
    (re.compile(r"\b\d+ passed, 0 failed\b"), PALETTE[32], True),
    (re.compile(r"\bSYNTHETIC\b"), PALETTE[33], True),
]

BASE_ENV = {
    "PATH": "/usr/local/bin:/usr/bin:/bin:" + str(Path.home() / ".local/bin"),
    "HOME": str(Path.home()),
    "LANG": "C.UTF-8",
    "KUBECONFIG": "/dev/null",
    "TF_PLUGIN_CACHE_DIR": str(Path.home() / ".terraform.d/plugin-cache"),
}


# ------------------------------------------------------------------ running commands
def run(argv, env_extra=None, cwd=ROOT, timeout=300):
    env = dict(BASE_ENV)
    env.update(env_extra or {})
    p = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def run_pty(argv, env, answer, wait_for=b"Enter to continue", timeout=30):
    """Run argv under a pseudo-terminal, type `answer` when the prompt appears, return (rc, output)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    out, sent, deadline = b"", False, time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if not sent and wait_for in out:
            time.sleep(0.4)
            os.write(fd, (answer + "\n").encode())
            sent = True
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), out.decode("utf-8", "replace")


# ------------------------------------------------------------------ cases
SCRUB_ENV = ["env", "-i", "PATH=/usr/bin:/bin"]


def case_guards():
    steps = []
    for label, env in (
        ("# CLUSTER_NAME and EXPECTED_AWS_ACCOUNT_ID missing", []),
        ("# the existing cluster (boutique-dev-eks) is refused by name", ["CLUSTER_NAME=boutique-dev-eks", "EXPECTED_AWS_ACCOUNT_ID=000000000001"]),
        ("# malformed account id", ["CLUSTER_NAME=finops-spot-demo", "EXPECTED_AWS_ACCOUNT_ID=12345"]),
    ):
        shown = " ".join(env + ["bash scripts/01-up.sh"])
        rc, out = run([*SCRUB_ENV, *env, "bash", "scripts/01-up.sh"])
        steps.append({"comment": label, "cmd": shown, "out": out, "rc": rc})
    return {"steps": steps, "show_rc": True}


def case_confirm():
    sb = subprocess.run(["bash", "-c", "source scripts/tests/lib_sandbox.sh; make_sandbox; echo $SB"], cwd=ROOT,
                        capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
    try:
        Path(sb, "terraform/terraform.tfvars").write_text("")
        env = {"PATH": f"{sb}/stub:{sb}/tools", "HOME": sb, "STUB_LOG": f"{sb}/calls.log", "STUB_DATA": f"{sb}/data",
               "CLUSTER_NAME": "finops-spot-demo", "EXPECTED_AWS_ACCOUNT_ID": "000000000001"}
        rc, out = run_pty([f"{sb}/tools/bash", f"{sb}/scripts/01-up.sh"], env, "yes")
        out = out.replace(sb, "<sandbox>")
    finally:
        shutil.rmtree(sb, ignore_errors=True)
    return {"cols": 136, "steps": [{
        "comment": "# aws and terraform are STUBS from the test sandbox (no real AWS call); a wrong answer is refused",
        "cmd": "CLUSTER_NAME=finops-spot-demo EXPECTED_AWS_ACCOUNT_ID=000000000001 bash scripts/01-up.sh",
        "out": out, "rc": rc}], "show_rc": True}


def tf_step(sub):
    rc, out = run(["terraform", f"-chdir=terraform", sub])
    return {"cmd": f"terraform -chdir=terraform {sub}", "out": out, "rc": rc}


def case_terraform_test():
    init = subprocess.run(["terraform", "-chdir=terraform", "init", "-backend=false", "-input=false"], cwd=ROOT,
                          env={**BASE_ENV}, capture_output=True, text=True)
    if init.returncode != 0:
        raise RuntimeError("terraform init failed:\n" + init.stdout + init.stderr)
    try:
        return {"steps": [tf_step("test")], }
    finally:
        shutil.rmtree(ROOT / "terraform/.terraform", ignore_errors=True)


def case_terraform_validate():
    subprocess.run(["terraform", "-chdir=terraform", "init", "-backend=false", "-input=false"], cwd=ROOT,
                   env={**BASE_ENV}, capture_output=True, check=True)
    try:
        return {"steps": [
            {"cmd": "terraform -chdir=terraform fmt -check -recursive && echo \"fmt: ok\"",
             **dict(zip(("rc", "out"), run(["bash", "-c", "terraform -chdir=terraform fmt -check -recursive && echo \"fmt: ok\""])))},
            tf_step("validate")]}
    finally:
        shutil.rmtree(ROOT / "terraform/.terraform", ignore_errors=True)


HELM_CMD = r'''C=kubernetes/boutique
for s in ca karpenter automode; do
  r=$(helm template boutique-$s $C -f $C/values-common.yaml -f $C/values-$s.yaml)
  d=$(grep -c '^kind: Deployment$' <<<"$r")
  p=$(grep -c '^kind: PodDisruptionBudget$' <<<"$r")
  n=$(grep -A1 'nodeSelector:' <<<"$r" | grep -c "scaler: $s")
  echo "$s: Deployments=$d PDBs=$p nodeSelector[scaler=$s]=$n"
done'''


def case_helm():
    rc, out = run(["bash", "-c", HELM_CMD])
    return {"steps": [{"comment": "# helm template runs locally, no cluster needed; every scaler gets its own nodeSelector",
                       "cmd": HELM_CMD, "out": out, "rc": rc}]}


def case_tests():
    rc, out = run(["bash", "scripts/tests/test_guards.sh"])
    return {"steps": [{"comment": "# guard tests with stub binaries: no AWS, no cluster",
                       "cmd": "bash scripts/tests/test_guards.sh", "out": out, "rc": rc}], "trim": (14, 10)}


NODEPOOL_CMD = ("CLUSTER_NAME=finops-spot-demo envsubst '${CLUSTER_NAME}' < kubernetes/karpenter/nodepool.yaml.tpl \\\n"
                "  | grep -vE '^[[:space:]]*#'")
def case_nodepool():
    rc, out = run(["bash", "-c", NODEPOOL_CMD])
    return {"steps": [{"comment": "# the Karpenter NodePool used in the demo: Spot first, On-Demand fallback, consolidation (rendered offline)",
                       "cmd": NODEPOOL_CMD, "out": out, "rc": rc}]}
SYN_DIR = "/tmp/finops-syn"
FILL_CMD = (f"python3 scripts/fill_results.py --input-dir scripts/tests/fixtures \\\n"
            f"  --prefix SYNTHETIC- --out {SYN_DIR} && \\\n"
            f"grep -E '^\\| (Scaler|ca|karpenter|automode) ' {SYN_DIR}/RESULTS.md | cut -d'|' -f2-5")


def case_fill():
    shutil.rmtree(SYN_DIR, ignore_errors=True)
    try:
        rc, out = run(["bash", "-c", FILL_CMD])
    finally:
        shutil.rmtree(SYN_DIR, ignore_errors=True)
    return {"steps": [{"comment": "# input = SYNTHETIC fixtures in scripts/tests/fixtures; columns 6-8 are cut to fit the image",
                       "cmd": FILL_CMD, "out": out, "rc": rc}],
            "banner": "SYNTHETIC SAMPLE DATA (test fixtures), NOT MEASURED"}


def case_deck():
    rc, out = run(["presentation/.venv/bin/python", "presentation/verify_deck.py"])
    return {"steps": [{"cmd": "presentation/.venv/bin/python presentation/verify_deck.py", "out": out, "rc": rc}]}


CASES = {
    "01-guard-refuses": ("guards", case_guards),
    "02-typed-confirmation": ("confirm", case_confirm),
    "03-terraform-test": ("terraform-test", case_terraform_test),
    "04-terraform-validate": ("terraform-validate", case_terraform_validate),
    "05-helm-per-scaler": ("helm", case_helm),
    "06-guard-tests": ("tests", case_tests),
    "07-fill-results-synthetic": ("fill", case_fill),
    "08-deck-verify": ("deck", case_deck),
    "09-karpenter-nodepool": ("nodepool", case_nodepool),
}


# ------------------------------------------------------------------ text -> styled cells
def sgr_apply(state, params):
    fg, bold, dim = state
    codes = [int(p) if p.isdigit() else 0 for p in (params.split(";") if params else ["0"])]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            fg, bold, dim = None, False, False
        elif c == 1:
            bold = True
        elif c == 2:
            dim = True
        elif c == 22:
            bold = dim = False
        elif c in PALETTE:
            fg = PALETTE[c]
        elif c == 39:
            fg = None
        elif c in (38, 48) and i + 1 < len(codes):
            if codes[i + 1] == 5 and i + 2 < len(codes):
                i += 2
            elif codes[i + 1] == 2:
                if c == 38 and i + 4 < len(codes):
                    fg = tuple(codes[i + 2:i + 5])
                i += 4
        i += 1
    return fg, bold, dim


def parse_line(line, plain_style=True):
    """Return a list of (char, fg, bold) for one logical line (ANSI SGR honoured, other escapes dropped)."""
    if "\r" in line:
        line = line.split("\r")[-1] if line.rstrip("\r") else ""
    cells, state, pos, had_ansi = [], (None, False, False), 0, False
    for m in ANSI_RE.finditer(line):
        for ch in line[pos:m.start()]:
            cells.append((ch, *state))
        pos = m.end()
        if m.group(2) == "m":
            state = sgr_apply(state, m.group(1))
            had_ansi = True
    for ch in line[pos:]:
        cells.append((ch, *state))
    result = [(ch, (DIM if dim and fg is None else fg), bold) for ch, fg, bold, dim in cells]
    if plain_style and not had_ansi:
        text = "".join(c[0] for c in result)
        for rx, colour, bold in TOKEN_STYLES:
            for m in rx.finditer(text):
                for k in range(m.start(), m.end()):
                    result[k] = (result[k][0], colour, bold)
    return result


def wrap(cells, cols=None):
    cols = cols or COLS
    if not cells:
        return [[]]
    return [cells[i:i + cols] for i in range(0, len(cells), cols)]


def trim_lines(lines, head, tail):
    if len(lines) <= head + tail + 1:
        return lines
    omitted = len(lines) - head - tail
    return lines[:head] + [f"... [{omitted} lines omitted; run the command for the full output] ..."] + lines[-tail:]


def build_rows(spec):
    """Turn the case into display rows: list of cell lists."""
    rows = []
    head, tail = spec.get("trim", (10_000, 0))
    for n, step in enumerate(spec["steps"]):
        if n:
            rows.append([])
        if step.get("comment"):
            for ch_line in step["comment"].split("\n"):
                rows += wrap([(c, DIM, False) for c in ch_line])
        for k, cmd_line in enumerate(step["cmd"].split("\n")):
            prefix = "$ " if k == 0 else "> "
            rows += wrap([(c, PROMPT_GREEN, True) for c in prefix] + [(c, PALETTE[97], False) for c in cmd_line])
        out = step["out"].replace("\r\n", "\n").rstrip("\n")
        lines = trim_lines(out.split("\n") if out else [], head, tail)
        for line in lines:
            if line.startswith("... ["):
                rows += wrap([(c, PALETTE[33], True) for c in line])
            else:
                rows += wrap(parse_line(line))
        if spec.get("show_rc") or step["rc"] != 0:
            colour = PALETTE[32] if step["rc"] == 0 else PALETTE[31]
            rows += wrap([(c, colour, False) for c in f"[exit {step['rc']}]"])
    rows.append([("$", PROMPT_GREEN, True), (" ", FG, False), ("█", DIM, False)])
    return rows


def check_safe(rows, name):
    text = "\n".join("".join(c[0] for c in r) for r in rows)
    for m in re.finditer(r"(?<![0-9])[0-9]{12}(?![0-9])", text):
        if m.group(0) not in SYNTHETIC_ACCOUNTS:
            raise SystemExit(f"{name}: refusing to render, 12-digit number {m.group(0)} in output")
    for bad in (r"AKIA[0-9A-Z]{16}", r"/home/", r"BEGIN [A-Z ]*PRIVATE KEY", r"arn:aws:eks:[a-z0-9-]+:\d{12}:cluster/frt-outbound-proxy"):
        if re.search(bad, text):
            raise SystemExit(f"{name}: refusing to render, pattern {bad!r} in output")


# ------------------------------------------------------------------ drawing
def render(name, spec):
    global COLS
    COLS = spec.get("cols", DEFAULT_COLS)
    rows = build_rows(spec)
    check_safe(rows, name)
    reg = ImageFont.truetype(FONT_REG, FONT_SIZE)
    bold = ImageFont.truetype(FONT_BOLD, FONT_SIZE)
    cw = reg.getlength("M")
    line_h = FONT_SIZE + LINE_GAP + 4
    banner_h = 44 if spec.get("banner") else 0
    width = int(cw * COLS + PAD * 2)
    height = TITLE_H + banner_h + PAD * 2 + line_h * len(rows)
    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width, TITLE_H], fill=TITLE_BG)
    for i, colour in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        cx = 22 + i * 24
        d.ellipse([cx - 7, TITLE_H // 2 - 7, cx + 7, TITLE_H // 2 + 7], fill=colour)
    title = f"finops-eks-spot-opencost: {name}"
    d.text((width / 2 - reg.getlength(title) / 2, TITLE_H // 2 - 9), title, font=reg, fill=DIM)
    y = TITLE_H
    if spec.get("banner"):
        d.rectangle([0, y, width, y + banner_h], fill=(120, 20, 20))
        t = "⚠  " + spec["banner"] + "  ⚠"
        d.text((width / 2 - bold.getlength(t) / 2, y + 12), t, font=bold, fill=(255, 235, 150))
        y += banner_h
    y += PAD
    for row in rows:
        x = PAD
        for ch, fg, is_bold in row:
            d.text((x, y), ch, font=bold if is_bold else reg, fill=fg or FG)
            x += cw
        y += line_h
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.png"
    img.save(path, optimize=True)
    return path


def main(argv):
    wanted = argv[1:] or list(CASES)
    unknown = [w for w in wanted if w not in CASES]
    if unknown:
        raise SystemExit(f"unknown image name(s): {unknown}; known: {list(CASES)}")
    for name in wanted:
        _, fn = CASES[name]
        spec = fn()
        path = render(name, spec)
        print(f"wrote {path.relative_to(ROOT)} ({len(spec['steps'])} command(s))")


if __name__ == "__main__":
    main(sys.argv)
