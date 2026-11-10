"""Crystal Bowl scanning mat: vector PDF, true 1:1 (1 mm = 72/25.4 pt). Usage: python make_mat.py <outdir>"""
import math, sys, os, random

MM = 72 / 25.4
PAGES = {'A4': (210.0, 297.0), 'Letter': (215.9, 279.4)}
TONES = {
    # name: (work-area fill, minor, mid, major, label, ring)
    'light': ((0.89, 0.95, 0.96), (0.76, 0.87, 0.91), (0.56, 0.76, 0.83), (0.24, 0.55, 0.67), (0.10, 0.30, 0.38), (0.10, 0.30, 0.38)),
    'dark': ((0.12, 0.16, 0.23), (0.22, 0.29, 0.38), (0.33, 0.43, 0.55), (0.55, 0.72, 0.85), (0.92, 0.95, 0.98), (0.80, 0.88, 0.95)),
}


class Page:
    def __init__(self, w, h):
        self.w, self.h, self.ops = w, h, []

    def c(self, s): self.ops.append(s)
    def fill(self, rgb): self.c('%.3f %.3f %.3f rg' % rgb)
    def stroke(self, rgb): self.c('%.3f %.3f %.3f RG' % rgb)
    def width(self, pt): self.c('%.3f w' % pt)

    # all coordinates in mm from the bottom-left corner
    def rect(self, x, y, w, h, fill=True):
        self.c('%.3f %.3f %.3f %.3f re %s' % (x * MM, y * MM, w * MM, h * MM, 'f' if fill else 'S'))

    def line(self, x0, y0, x1, y1):
        self.c('%.3f %.3f m %.3f %.3f l S' % (x0 * MM, y0 * MM, x1 * MM, y1 * MM))

    def circle(self, cx, cy, r, fill=False):
        k = 0.5523 * r
        p = lambda x, y: '%.3f %.3f' % (x * MM, y * MM)
        self.c('%s m %s %s %s c %s %s %s c %s %s %s c %s %s %s c %s' % (
            p(cx + r, cy), p(cx + r, cy + k), p(cx + k, cy + r), p(cx, cy + r), p(cx - k, cy + r), p(cx - r, cy + k), p(cx - r, cy),
            p(cx - r, cy - k), p(cx - k, cy - r), p(cx, cy - r), p(cx + k, cy - r), p(cx + r, cy - k), p(cx + r, cy), 'f' if fill else 'S'))

    def text(self, x, y, s, size=7, bold=False, align='l', rot=0):
        # Helvetica widths approximated (0.5 em average; digits 0.556 em)
        wpt = sum(0.556 if ch.isdigit() else (0.28 if ch in ' .,:;|ilI' else 0.6 if ch.isupper() else 0.5) for ch in s) * size
        if bold: wpt *= 1.06
        dx = {'l': 0, 'c': -wpt / 2, 'r': -wpt}[align]
        s = s.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
        a = math.radians(rot)
        ca, sa = math.cos(a), math.sin(a)
        x0, y0 = x * MM + dx * ca, y * MM + dx * sa
        self.c('BT /%s %.2f Tf %.4f %.4f %.4f %.4f %.3f %.3f Tm (%s) Tj ET' % ('F2' if bold else 'F1', size, ca, sa, -sa, ca, x0, y0, s))


def field_scale(p, x, y, length_cm=10, unit_mm=10.0, label='10 cm', vertical=False, sub='1 cm blocks'):
    """Geologist's field scale: two rows of alternating black/white blocks, a hairline mm ruler on one edge."""
    n = int(length_cm)
    t = 5.0  # bar thickness mm (two rows of 2.5)
    for i in range(n):
        for row in range(2):
            black = (i + row) % 2 == 0
            p.fill((0.05, 0.05, 0.05) if black else (1, 1, 1))
            if vertical:
                p.rect(x + row * t / 2, y + i * unit_mm, t / 2, unit_mm)
            else:
                p.rect(x + i * unit_mm, y + row * t / 2, unit_mm, t / 2)
    p.stroke((0.05, 0.05, 0.05)); p.width(0.6)
    if vertical:
        p.rect(x, y, t, n * unit_mm, fill=False)
    else:
        p.rect(x, y, n * unit_mm, t, fill=False)
    # fine ticks beside the bar
    p.width(0.25)
    steps = int(round(n * unit_mm / (unit_mm / 10)))
    for k in range(steps + 1):
        L = 2.2 if k % 10 == 0 else (1.5 if k % 5 == 0 else 0.9)
        d = k * unit_mm / 10
        if vertical:
            p.line(x + t, y + d, x + t + L, y + d)
        else:
            p.line(x + d, y - L, x + d, y)
    p.fill((0.05, 0.05, 0.05))
    if vertical:
        for i in range(n + 1):
            p.text(x + t + 3.2, y + i * unit_mm - 1, str(i), size=6, bold=i in (0, n))
        p.text(x - 1.5, y + n * unit_mm / 2, label + ' · ' + sub, size=7, bold=True, align='c', rot=90)
    else:
        for i in range(n + 1):
            p.text(x + i * unit_mm, y - 5.2, str(i), size=6, bold=i in (0, n), align='c')
        p.text(x + n * unit_mm + 3, y + 1.2, label + ' · ' + sub, size=7, bold=True)


def mat(paper, tone):
    W, H = PAGES[paper]
    fillc, minor, mid, major, labc, ringc = TONES[tone]
    p = Page(W, H)
    m = 8.0  # printer margin
    # work area: whole cm, centred, leaving bands for scales
    gx0 = 30.0                      # left band: vertical field scale, then the grid's cm numbers
    gw = math.floor((W - gx0 - 30.0) / 10) * 10
    gy0 = 32.0                      # bottom band: field scale and the footer line
    gh = math.floor((H - gy0 - 30.0) / 10) * 10
    p.fill(fillc); p.rect(gx0, gy0, gw, gh)
    # grid: 1 mm, 5 mm, 10 mm
    for level, col, wid, step in ((0, minor, 0.15, 1), (1, mid, 0.3, 5), (2, major, 0.55, 10)):
        p.stroke(col); p.width(wid)
        for i in range(0, int(gw) + 1, step):
            if level < 2 and i % (5 if level == 0 else 10) == 0: continue
            p.line(gx0 + i, gy0, gx0 + i, gy0 + gh)
        for j in range(0, int(gh) + 1, step):
            if level < 2 and j % (5 if level == 0 else 10) == 0: continue
            p.line(gx0, gy0 + j, gx0 + gw, gy0 + j)
    # centre degree ring (orientation; 0° = where the reference mark faces the X-ray source)
    cx, cy = gx0 + gw / 2, gy0 + gh / 2
    R = min(gw, gh) * 0.36
    p.stroke(ringc); p.width(0.45); p.circle(cx, cy, R)
    for a in range(0, 360, 10):
        t = math.radians(a)
        L = 4 if a % 30 == 0 else 2
        dx, dy = math.sin(t), -math.cos(t)
        p.width(0.6 if a % 90 == 0 else 0.35)
        p.line(cx + dx * R, cy + dy * R, cx + dx * (R + L), cy + dy * (R + L))
        if a % 30 == 0:
            v = a if a <= 180 else a - 360
            p.fill(labc)
            p.text(cx + dx * (R + 7.5), cy + dy * (R + 7.5) - 1.2, ('%+d°' % v) if v not in (0, 180) else ('%d°' % abs(v)), size=6.5,
                   bold=a % 90 == 0, align='c')
    p.fill(labc)
    p.text(cx, cy - R + 5, 'mark faces 0° (X-ray side)', size=6, align='c')
    p.stroke(ringc); p.width(0.5)
    p.line(cx - 3, cy, cx + 3, cy); p.line(cx, cy - 3, cx, cy + 3)
    # cm numbers along the work area's bottom and left edges (outside it)
    p.fill((0.15, 0.15, 0.15))
    for i in range(0, int(gw) + 1, 10):
        p.text(gx0 + i, gy0 - 3.6, str(i // 10), size=6.5, bold=(i == 0), align='c')
    for j in range(0, int(gh) + 1, 10):
        p.text(gx0 - 2.2, gy0 + j - 1.1, str(j // 10), size=6.5, bold=(j == 0), align='r')
    p.text(gx0 + gw + 1.5, gy0 - 3.6, 'cm', size=6.5, bold=True)
    p.text(gx0 - 2.2, gy0 + gh + 1.6, 'cm', size=6.5, bold=True, align='r')
    # tracking markers round the work area: unique letters in black squares (no two alike, so the phone keeps its place)
    random.seed(7)
    letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    k = 0
    def marker(x, y):
        nonlocal k
        p.fill((0.05, 0.05, 0.05)); p.rect(x - 2.6, y - 2.6, 5.2, 5.2)
        p.fill((1, 1, 1)); p.text(x, y - 1.6, letters[k % len(letters)], size=8, bold=True, align='c'); k += 1
    for i in range(20, int(gw), 40):
        marker(gx0 + i, gy0 + gh + 5)
    for j in range(20, int(gh), 40):
        marker(gx0 + gw + 5, gy0 + j)
    # scales: metric field scale along the bottom, vertical one on the left, inches along the top
    field_scale(p, gx0, m + 11.0, 10, 10.0, '10 cm', sub='1 cm blocks, mm ticks')
    field_scale(p, m + 4.0, gy0 + 25, 10, 10.0, '10 cm', vertical=True, sub='1 cm blocks')
    field_scale(p, gx0, H - m - 9.5, 4, 25.4, '4 in', sub='1 in blocks, 0.1 in ticks')
    # print check: a 100 mm bracket
    bx = gx0 + gw - 100
    by = H - m - 2.5
    p.stroke((0.05, 0.05, 0.05)); p.width(0.5)
    p.line(bx, by, bx + 100, by); p.line(bx, by - 1.8, bx, by + 1.8); p.line(bx + 100, by - 1.8, bx + 100, by + 1.8)
    p.fill((0.05, 0.05, 0.05))
    p.text(bx + 50, by + 1.4, 'print check: this line must measure exactly 100 mm', size=6.5, bold=True, align='c')
    p.text(W - m, m + 0.3, 'Crystal Bowl scanning mat · %s · %s · print at 100 %% ("Actual size"), never "Fit to page" · keep pieces apart, inside the grid' % (paper, tone),
           size=6, align='r')
    return p


def write_pdf(path, page):
    content = '\n'.join(page.ops).encode('latin-1')
    objs = []
    objs.append(b'<< /Type /Catalog /Pages 2 0 R >>')
    objs.append(b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
    objs.append(('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.3f %.3f] /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>'
                 % (page.w * MM, page.h * MM)).encode())
    objs.append(b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream')
    objs.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
    objs.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>')
    out = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += b'%d 0 obj\n' % i + o + b'\nendobj\n'
    x = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for o in offs: out += b'%010d 00000 n \n' % o
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, x)
    open(path, 'wb').write(out)


if __name__ == '__main__':
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    for paper in PAGES:
        for tone in TONES:
            write_pdf(os.path.join(d, 'CrystalBowl_scanning_mat_%s_%s.pdf' % (paper, tone)), mat(paper, tone))
    print('ok')
