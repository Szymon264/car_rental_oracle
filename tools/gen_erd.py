"""Generuje diagram ERD (Graphviz DOT) z pliku 01_schemat_i_dane.sql."""
import re
import sys

src, out = sys.argv[1], sys.argv[2]
sql = open(src, encoding="utf8").read()

GROUPS = {
    "Słowniki": ["makes", "maintenance_types", "promotions"],
    "Ludzie i oddziały": ["users", "employees", "customers", "branches"],
    "Flota": ["vehicle_types", "vehicles", "maintenance"],
    "Wypożyczenia i płatności": ["bookings", "payment_details", "transactions", "damages"],
}
GROUP_COLOR = {
    "Słowniki": "#6B7A8F",
    "Ludzie i oddziały": "#2F5D8A",
    "Flota": "#B85C0E",
    "Wypożyczenia i płatności": "#14213D",
}

tables = {}
fks = []
for m in re.finditer(r"CREATE TABLE (\w+) \((.*?)\n\);", sql, re.S):
    name, body = m.group(1), m.group(2)
    cols, pk = [], set()
    for line in body.split("\n"):
        l = line.strip()
        if not l or l.startswith("--"):
            continue
        fk = re.match(r"CONSTRAINT\s+\w+\s+FOREIGN KEY\s*\((\w+)\)\s*REFERENCES\s+(\w+)\s*\((\w+)\)", l)
        if fk:
            fks.append((name, fk.group(1), fk.group(2), fk.group(3)))
            continue
        cm = re.match(r"^([a-z_0-9]+)\s+([A-Z0-9]+(?:\(\d+(?:,\d+)?(?: CHAR)?\))?)", l)
        if cm and not l.startswith("CONSTRAINT"):
            col, typ = cm.group(1), cm.group(2).replace(" CHAR", "")
            if "PRIMARY KEY" in l:
                pk.add(col)
            nn = "NOT NULL" in l or "PRIMARY KEY" in l
            cols.append((col, typ, nn))
    tables[name] = (cols, pk)

fk_cols = {(t, c) for t, c, _, _ in fks}

def odmiana(n):
    if n == 1:
        return "kolumna"
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return "kolumny"
    return "kolumn"

def label(t, color):
    cols, pk = tables[t]
    rows = [f'<TR><TD BGCOLOR="{color}" ALIGN="CENTER" COLSPAN="3">'
            f'<FONT COLOR="#F7F6F2" POINT-SIZE="15"><B>{t.upper()}</B></FONT></TD></TR>']
    compact = len(sys.argv) > 3 and sys.argv[3] == "compact"
    hidden = 0
    for c, typ, nn in cols:
        key = "PK" if c in pk else ("FK" if (t, c) in fk_cols else "")
        if compact and not key:
            hidden += 1
            continue
        key_color = "#B85C0E" if key == "PK" else "#2F5D8A"
        name = f"<B>{c}</B>" if c in pk else c
        if not nn and not key:
            name = f'<FONT COLOR="#5A6474">{c}</FONT>'
        rows.append(
            (f'<TR><TD ALIGN="LEFT" WIDTH="26"><FONT COLOR="{key_color}" POINT-SIZE="10"><B>{key}</B></FONT></TD>' if key else '<TR><TD WIDTH="26"> </TD>') +
            f'<TD ALIGN="LEFT" PORT="{c}">{name}</TD>'
            f'<TD ALIGN="LEFT"><FONT COLOR="#5A6474" POINT-SIZE="10">{typ.lower()}</FONT></TD></TR>')
    if hidden:
        rows.append(f'<TR><TD> </TD><TD ALIGN="LEFT" COLSPAN="2"><FONT COLOR="#5A6474" POINT-SIZE="11">'
                    f'<I>+ {hidden} {odmiana(hidden)}</I></FONT></TD></TR>')
    return ("<" + '<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4" '
            f'COLOR="{color}" BGCOLOR="#FFFFFF">' + "".join(rows) + "</TABLE>>")

lines = [
    "digraph ERD {",
    '  graph [rankdir=LR, splines=spline, nodesep=0.35, ranksep=0.9, newrank=true, bgcolor="#F7F6F2", '
    'fontname="DejaVu Sans", pad=0.4];',
    '  node [shape=plaintext, fontname="DejaVu Sans", fontsize=12];',
    '  edge [color="#5A6474", arrowhead=crow, arrowtail=tee, dir=both, penwidth=1.3];',
]
for i, (g, ts) in enumerate(GROUPS.items()):
    color = GROUP_COLOR[g]
    lines.append(f'  subgraph cluster_{i} {{ label="{g}"; fontname="DejaVu Sans"; fontsize=16; '
                 f'fontcolor="{color}"; color="{color}"; style="rounded,dashed"; penwidth=1.2;')
    for t in ts:
        lines.append(f"    {t} [label={label(t, color)}];")
    lines.append("  }")
for t, c, rt, rc in fks:
    # krawędź: rodzic (1) -> dziecko (wiele)
    lines.append(f"  {rt} -> {t};")
lines.append("}")

missing = set(tables) - {t for ts in GROUPS.values() for t in ts}
if missing:
    sys.exit(f"Tabele bez grupy: {missing}")
open(out, "w", encoding="utf8").write("\n".join(lines))
print(f"{len(tables)} tabel, {len(fks)} kluczy obcych")
