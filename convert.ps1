# Aya sight converter v3: image -> vector line-art sight (drawLines contours)
# v3 fix: 正确的 WT 坐标系转换（之前完全没做坐标变换，图像会歪到屏幕一角）
# WT 坐标系：X 中心 0 范围 [-0.5, +0.5]，Y 中心 0 范围 [-0.28125, +0.28125]（向下为正）
# sight box: x0/w/y0 都是图像相对 WT 屏幕的比例（和 wt-sight-studio.html 完全一致）
param(
  [string]$src  = "E:\ai\wt_sights\aya_source.png",
  [string]$out  = "E:\ai\wt_sights\sight_1.blk",
  [string]$prev = "E:\ai\wt_sights\preview.png",
  [double]$x0   = 0.325,   # sight box 左上角 X（WT 屏幕比例），默认 0.325 = 居中
  [double]$y0   = 0.0,     # sight box 左上角 Y（WT 屏幕比例），默认 0 = 屏幕顶部
  [double]$w    = 0.35,    # sight box 宽度（WT 屏幕宽度比例），默认 0.35
  [int]$gridW   = 520,
  [double]$dpEps = 0.8,
  [double]$cL = 0.0, [double]$cT = 0.0, [double]$cR = 1.0, [double]$cB = 1.0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# === WT 坐标系常量（和 wt-sight-studio.html 完全一致）===
$WT_X_OFFSET = -0.5       # WT X 中心在 0，屏幕左半 = [-0.5, 0]，右半 = [0, +0.5]
$WT_Y_CENTER = 9.0/32.0   # = 0.28125，WT Y 半高（屏幕中心在 Y=0）
$Y_BLK_SCALE = 9.0/16.0   # = 0.5625，WT Y 以屏幕宽度为基准的高度比例
# sight box 在 WT Y 方向的实际高度 = w * GH/GW * Y_BLK_SCALE
# bx = sightX0 + gx/GW * sightW + WT_X_OFFSET
# by = sightY0 * Y_BLK_SCALE + gy/GH * artH - WT_Y_CENTER

$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Text;

public class WTTrace {
    static double[] lum; static int[] mm; static bool[] red;
    static bool[] bgFlood; static bool[] content;
    static int GW, GH;
    static double cropW, cropH;

    static int Idx(int x, int y) { return y * GW + x; }

    public static string Run(string src, string outBlk, string prev,
        double cL, double cT, double cR, double cB,
        int gridW, double x0, double y0, double w, double dpEps,
        double WT_X_OFFSET, double WT_Y_CENTER, double Y_BLK_SCALE) {

        Bitmap srcBmp = new Bitmap(src);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        int cx = (int)(srcBmp.Width * cL), cy = (int)(srcBmp.Height * cT);
        int cw = (int)(srcBmp.Width * (cR - cL)), ch = (int)(srcBmp.Height * (cB - cT));
        Bitmap crop = srcBmp.Clone(new Rectangle(cx, cy, cw, ch), srcBmp.PixelFormat);
        cropW = cw; cropH = ch;
        GH = (int)Math.Round((double)gridW * ch / cw); GW = gridW;

        lum = new double[GW * GH]; mm = new int[GW * GH]; red = new bool[GW * GH];
        // flatten to 24bpp over white once (handles transparent PNGs), then fast LockBits access
        Bitmap bmp24 = new Bitmap(cw, ch, PixelFormat.Format24bppRgb);
        Graphics g0 = Graphics.FromImage(bmp24);
        g0.Clear(Color.White);
        g0.DrawImage(crop, new Rectangle(0, 0, cw, ch), new Rectangle(0, 0, cw, ch), GraphicsUnit.Pixel);
        g0.Dispose();
        BitmapData bd = bmp24.LockBits(new Rectangle(0, 0, cw, ch), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = bd.Stride;
        byte[] px = new byte[stride * ch];
        System.Runtime.InteropServices.Marshal.Copy(bd.Scan0, px, 0, px.Length);
        bmp24.UnlockBits(bd);
        bmp24.Dispose();
        double bw = (double)cw / GW, bh = (double)ch / GH;
        for (int j = 0; j < GH; j++) {
            for (int i = 0; i < GW; i++) {
                int x0p = (int)(i * bw), y0p = (int)(j * bh);
                int x1p = Math.Min(cw, (int)((i + 1) * bw)), y1p = Math.Min(ch, (int)((j + 1) * bh));
                double sl = 0; int smm = 0; bool sred = false; int n = 0;
                for (int yy = y0p; yy < y1p; yy += 2) {
                    int row = yy * stride;
                    for (int xx = x0p; xx < x1p; xx += 2) {
                        int off = row + xx * 3;
                        int b = px[off], g2 = px[off + 1], r = px[off + 2];
                        int mx = Math.Max(r, Math.Max(g2, b));
                        int mn = Math.Min(r, Math.Min(g2, b));
                        sl += 0.299 * r + 0.587 * g2 + 0.114 * b;
                        if (mx - mn > smm) smm = mx - mn;
                        if (r - g2 > 18 && r - b > 18 && r > 70) sred = true;
                        n++;
                    }
                }
                lum[Idx(i, j)] = n > 0 ? sl / n : 255;
                mm[Idx(i, j)] = smm; red[Idx(i, j)] = sred;
            }
        }

        // background = light & unsaturated, flood-filled from borders
        bgFlood = new bool[GW * GH];
        Stack<int> st = new Stack<int>();
        for (int i = 0; i < GW; i++) { TrySeedBg(i, 0, st); TrySeedBg(i, GH - 1, st); }
        for (int j = 0; j < GH; j++) { TrySeedBg(0, j, st); TrySeedBg(GW - 1, j, st); }
        while (st.Count > 0) {
            int c = st.Pop(); int ci = c % GW, cj = c / GW;
            TrySpreadBg(ci + 1, cj, st); TrySpreadBg(ci - 1, cj, st);
            TrySpreadBg(ci, cj + 1, st); TrySpreadBg(ci, cj - 1, st);
        }
        content = new bool[GW * GH];
        for (int k = 0; k < GW * GH; k++) content[k] = !bgFlood[k];

        List<double[][]> loops = new List<double[][]>();
        // 1) silhouette + holes
        foreach (var lp in TraceLoops(content)) loops.Add(lp);
        // 2) dark interior detail (hair, eyes, pen)
        bool[] dark = new bool[GW * GH];
        for (int k = 0; k < GW * GH; k++) dark[k] = content[k] && lum[k] < 135;
        foreach (var lp in TraceLoops(dark)) loops.Add(lp);
        // 3) red accents
        bool[] redm = new bool[GW * GH];
        for (int k = 0; k < GW * GH; k++) redm[k] = content[k] && red[k];
        foreach (var lp in TraceLoops(redm)) loops.Add(lp);

        // map to screen fractions; smooth curves then simplify each loop
        double artH = w * GH / GW;
        var polylines = new List<double[][]>();
        StringBuilder sb = new StringBuilder();
        int segCount = 0;
        foreach (var loop in loops) {
            if (loop.Length < 8) continue;
            var s = Simplify(Chaikin(PreFilter(loop), 2), dpEps);
            if (s.Length < 3) continue;
            polylines.Add(s);
            for (int i = 0; i < s.Length; i++) {
                var a = s[i]; var b = s[(i + 1) % s.Length];
                // v3 fix: 正确的 WT 坐标系转换
                // bx = sightX0 + gx/GW * sightW + WT_X_OFFSET  (WT_X_OFFSET = -0.5)
                // by = sightY0 * Y_BLK_SCALE + gy/GH * artH - WT_Y_CENTER  (WT_Y_CENTER = 0.28125, Y_BLK_SCALE = 0.5625)
                double ax = x0 + a[0] / GW * w + WT_X_OFFSET;
                double ay = y0 * Y_BLK_SCALE + a[1] / GH * artH - WT_Y_CENTER;
                double bx = x0 + b[0] / GW * w + WT_X_OFFSET;
                double by = y0 * Y_BLK_SCALE + b[1] / GH * artH - WT_Y_CENTER;
                if (Math.Abs(ax - bx) < 1e-6 && Math.Abs(ay - by) < 1e-6) continue;
                sb.AppendLine("  line {line:p4 = " + F(ax) + "," + F(ay) + "," + F(bx) + "," + F(by) + ";move:b=false;}");
                segCount++;
            }
        }
        string lines = sb.ToString();

        StringBuilder blk = new StringBuilder();
        blk.AppendLine("crosshairHorVertSize:p2=3, 2");
        blk.AppendLine("rangefinderProgressBarColor1:c=0, 255, 0, 64");
        blk.AppendLine("rangefinderProgressBarColor2:c=255, 255, 255, 64");
        blk.AppendLine("rangefinderTextScale:r=0.7");
        blk.AppendLine("rangefinderVerticalOffset:r=0.1");
        blk.AppendLine("rangefinderHorizontalOffset:r=5");
        blk.AppendLine("fontSizeMult:r=1");
        blk.AppendLine("lineSizeMult:r=1");
        blk.AppendLine("drawCentralLineVert:b=yes");
        blk.AppendLine("drawCentralLineHorz:b=yes");
        blk.AppendLine("crosshairColor:c=235, 235, 235, 255");
        blk.AppendLine("crosshairLightColor:c=255, 255, 255, 255");
        blk.AppendLine("crosshairDistHorSizeMain:p2=0.03, 0.02");
        blk.AppendLine("crosshairDistHorSizeAdditional:p2=0.005, 0.003");
        blk.AppendLine("drawDistanceCorrection:b=yes");
        blk.AppendLine("");
        blk.AppendLine("crosshair_distances{");
        int[] dists = { 200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400, 2600, 2800 };
        foreach (int d in dists) blk.AppendLine("  distance:p3=" + d + ", " + (d % 400 == 0 ? (d / 400 * 4) : 0) + ", 0");
        blk.AppendLine("}");
        blk.AppendLine("");
        blk.AppendLine("crosshair_hor_ranges{");
        blk.AppendLine("}");
        blk.AppendLine("");
        blk.AppendLine("matchExpClass{");
        blk.AppendLine("  exp_tank:b = yes");
        blk.AppendLine("  exp_heavy_tank:b = yes");
        blk.AppendLine("  exp_tank_destroyer:b = yes");
        blk.AppendLine("  exp_SPAA:b = yes");
        blk.AppendLine("}");
        blk.AppendLine("");
        blk.AppendLine("drawTexts{");
        blk.AppendLine("  text {");
        blk.AppendLine("    text:t = \"文\"");
        blk.AppendLine("    align:i = 0");
        blk.AppendLine("    pos:p2 = " + F(x0 + w + 0.025 + WT_X_OFFSET) + ", " + F(y0 * Y_BLK_SCALE + 0.015 - WT_Y_CENTER));
        blk.AppendLine("    move:b = no");
        blk.AppendLine("    size:r = 1.6");
        blk.AppendLine("  }");
        blk.AppendLine("}");
        blk.AppendLine("");
        blk.AppendLine("drawLines{");
        blk.Append(lines);
        blk.AppendLine("}");
        File.WriteAllText(outBlk, blk.ToString(), new UTF8Encoding(false));

        // preview (reuse the exact polylines that went into the blk)
        int pw = 560, ph = (int)(pw * artH / w);
        Bitmap pv = new Bitmap(pw, ph);
        Graphics g = Graphics.FromImage(pv);
        g.Clear(Color.White);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Pen pen = new Pen(Color.Black, 1.4f);
        foreach (var s in polylines) {
            PointF[] pts = new PointF[s.Length + 1];
            for (int i = 0; i <= s.Length; i++) {
                var p = s[i % s.Length];
                pts[i] = new PointF((float)((x0 + p[0] / GW * w - x0) / w * pw),
                                    (float)(ph - ((y0 + (1 - p[1] / GH) * artH - y0) / artH * ph)));
            }
            g.DrawLines(pen, pts);
        }
        g.Dispose(); pv.Save(prev, System.Drawing.Imaging.ImageFormat.Png); pv.Dispose();
        crop.Dispose(); srcBmp.Dispose();
        return "SEGMENTS=" + segCount + " GH=" + GH + " SEC=" + sw.Elapsed.TotalSeconds.ToString("F1");
    }

    static string F(double v) { return v.ToString("F6", System.Globalization.CultureInfo.InvariantCulture); }

    static bool IsBgLike(int i, int j) { int k = Idx(i, j); return lum[k] >= 200 && mm[k] <= 32; }
    static void TrySeedBg(int i, int j, Stack<int> st) { if (IsBgLike(i, j) && !bgFlood[Idx(i, j)]) { bgFlood[Idx(i, j)] = true; st.Push(Idx(i, j)); } }
    static void TrySpreadBg(int i, int j, Stack<int> st) {
        if (i < 0 || i >= GW || j < 0 || j >= GH) return;
        int k = Idx(i, j);
        if (!bgFlood[k] && IsBgLike(i, j)) { bgFlood[k] = true; st.Push(k); }
    }

    // Moore-neighbor contour tracing (clockwise, y-down)
    static List<double[][]> TraceLoops(bool[] mask) {
        var loops = new List<double[][]>();
        var cellDone = new bool[GW * GH];
        int[] dx = { 1, 1, 0, -1, -1, -1, 0, 1 };
        int[] dy = { 0, 1, 1, 1, 0, -1, -1, -1 };
        for (int sy = 0; sy < GH; sy++) {
            for (int sx = 0; sx < GW; sx++) {
                int sk = Idx(sx, sy);
                if (!mask[sk] || cellDone[sk]) continue;
                bool boundary = false;
                for (int d = 0; d < 8; d++) {
                    int nx = sx + dx[d], ny = sy + dy[d];
                    if (nx < 0 || nx >= GW || ny < 0 || ny >= GH || !mask[Idx(nx, ny)]) { boundary = true; break; }
                }
                if (!boundary) continue;
                var pts = new List<int[]>();
                int cur = sk, back = 0;
                // initial backtrack: direction of the first false neighbor scanning clockwise
                for (int d = 0; d < 8; d++) {
                    int nx = sx + dx[d], ny = sy + dy[d];
                    if (nx < 0 || nx >= GW || ny < 0 || ny >= GH || !mask[Idx(nx, ny)]) { back = d; break; }
                }
                int steps = 0, maxSteps = GW * GH;
                bool ok = false;
                var seen = new HashSet<int>(); // (cell,back) states: breaks oscillation on thin 8-connected paths
                do {
                    if (!seen.Add(cur * 8 + back)) break;
                    pts.Add(new int[] { cur % GW, cur / GW });
                    cellDone[cur] = true;
                    int ci = cur % GW, cj = cur / GW;
                    bool moved = false;
                    for (int k = 1; k <= 8; k++) {
                        int d = (back + k) % 8;
                        int nx = ci + dx[d], ny = cj + dy[d];
                        if (nx >= 0 && nx < GW && ny >= 0 && ny < GH && mask[Idx(nx, ny)]) {
                            back = (d + 4) % 8;
                            cur = Idx(nx, ny);
                            moved = true; break;
                        }
                    }
                    if (!moved) break;
                    steps++;
                    if (steps > maxSteps) break;
                    if (cur == sk) { ok = true; break; }
                } while (true);
                if (pts.Count >= 8) loops.Add(pts.ConvertAll(p => new double[] { p[0], p[1] }).ToArray());
                if (!ok && pts.Count < 8) cellDone[sk] = true;
            }
        }
        return loops;
    }

    // O(n) pass: drop points lying (almost) on the chord of their neighbours
    // (collinear staircase runs collapse to corners -> keeps DP fast)
    static double[][] PreFilter(double[][] pts) {
        int n = pts.Length;
        if (n < 8) return pts;
        var keep = new List<double[]>(n);
        for (int i = 0; i < n; i++) {
            var a = pts[(i + n - 1) % n]; var b = pts[i]; var c = pts[(i + 1) % n];
            double ax = c[0] - a[0], ay = c[1] - a[1];
            double len = Math.Sqrt(ax * ax + ay * ay);
            double d;
            if (len < 1e-9) {
                double px = b[0] - a[0], py = b[1] - a[1];
                d = Math.Sqrt(px * px + py * py);
            } else {
                d = Math.Abs((b[0] - a[0]) * ay - (b[1] - a[1]) * ax) / len;
            }
            if (d > 0.45) keep.Add(b);
        }
        return keep.ToArray();
    }

    // Chaikin corner-cutting: removes pixel-grid staircase, keeps closed loop smooth
    static double[][] Chaikin(double[][] pts, int iters) {
        for (int it = 0; it < iters; it++) {
            int n = pts.Length;
            var res = new List<double[]>(n * 2);
            for (int i = 0; i < n; i++) {
                var a = pts[i]; var b = pts[(i + 1) % n];
                res.Add(new double[] { 0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1] });
                res.Add(new double[] { 0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1] });
            }
            pts = res.ToArray();
        }
        return pts;
    }

    // Douglas-Peucker on closed loop (treat as open from p0 back to p0)
    static double[][] Simplify(double[][] pts, double eps) {
        int n = pts.Length;
        if (n > 30000) { // pathological guard: decimate before DP
            var sub = new List<double[]>();
            for (int i = 0; i < n; i += 2) sub.Add(pts[i]);
            pts = sub.ToArray(); n = pts.Length;
        }
        if (n < 4) return pts;
        var open = new List<double[]>(pts); open.Add(pts[0]);
        var flags = new bool[n + 1];
        Dp(open, 0, n, eps, flags);
        flags[0] = true; // anchor: guarantee the loop closes at p0
        var res = new List<double[]>();
        for (int i = 0; i < n; i++) if (flags[i]) res.Add(pts[i]);
        return res.ToArray();
    }
    static void Dp(List<double[]> p, int s, int e, double eps, bool[] keep) {
        if (e <= s + 1) return;
        double maxD = -1; int maxI = s;
        double ax = p[s][0], ay = p[s][1], bx = p[e][0], by = p[e][1];
        double dxv = bx - ax, dyv = by - ay;
        double len2 = dxv * dxv + dyv * dyv;
        for (int i = s + 1; i < e; i++) {
            double d;
            if (len2 < 1e-12) {
                double px = p[i][0] - ax, py = p[i][1] - ay;
                d = Math.Sqrt(px * px + py * py);
            } else {
                double t = ((p[i][0] - ax) * dxv + (p[i][1] - ay) * dyv) / len2;
                t = Math.Max(0, Math.Min(1, t));
                double px = p[i][0] - (ax + t * dxv), py = p[i][1] - (ay + t * dyv);
                d = Math.Sqrt(px * px + py * py);
            }
            if (d > maxD) { maxD = d; maxI = i; }
        }
        if (maxD > eps) { keep[maxI] = true; Dp(p, s, maxI, eps, keep); Dp(p, maxI, e, eps, keep); }
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing

$r = [WTTrace]::Run($src, $out, $prev, $cL, $cT, $cR, $cB, $gridW, $x0, $y0, $w, $dpEps, $WT_X_OFFSET, $WT_Y_CENTER, $Y_BLK_SCALE)
Write-Output $r
Write-Output ("BLK_KB=" + [int]((Get-Item $out).Length / 1KB))
