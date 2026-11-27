// Image helpers shared by RetroArchForwarderPC.ps1 and DSForwarderPC.ps1:
// banner and icon composition with System.Drawing (C# 5, for Windows PowerShell 5.1).
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class FwdArt
{
    static byte[] Get(Bitmap b)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] a = new byte[d.Stride * b.Height];
        Marshal.Copy(d.Scan0, a, 0, a.Length);
        b.UnlockBits(d);
        return a;
    }

    static void Put(Bitmap b, byte[] a)
    {
        BitmapData d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(a, 0, d.Scan0, a.Length);
        b.UnlockBits(d);
    }

    static Graphics Hq(Bitmap b)
    {
        Graphics g = Graphics.FromImage(b);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SmoothingMode = SmoothingMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        return g;
    }

    // Fills w x h, cropping the excess around the centre.
    public static Bitmap Cover(Image src, int w, int h)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Hq(b))
        using (ImageAttributes ia = new ImageAttributes())
        {
            ia.SetWrapMode(WrapMode.TileFlipXY);
            double s = Math.Max((double)w / src.Width, (double)h / src.Height);
            int dw = (int)Math.Ceiling(src.Width * s), dh = (int)Math.Ceiling(src.Height * s);
            g.Clear(Color.Black);
            g.DrawImage(src, new Rectangle((w - dw) / 2, (h - dh) / 2, dw, dh), 0, 0, src.Width, src.Height, GraphicsUnit.Pixel, ia);
        }
        return b;
    }

    // Three box blur passes, then multiplies the colour by keep (0..1).
    public static void BlurDarken(Bitmap b, int radius, double keep)
    {
        int w = b.Width, h = b.Height, x, y, c, k, pass;
        byte[] a = Get(b);
        byte[] t = new byte[a.Length];
        for (pass = 0; pass < 3 && radius > 0; pass++)
        {
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++)
                    for (c = 0; c < 3; c++)
                    {
                        int sum = 0, n = 0;
                        for (k = -radius; k <= radius; k++)
                        {
                            int xx = x + k;
                            if (xx < 0 || xx >= w) continue;
                            sum += a[(y * w + xx) * 4 + c]; n++;
                        }
                        t[(y * w + x) * 4 + c] = (byte)(sum / n);
                    }
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++)
                    for (c = 0; c < 3; c++)
                    {
                        int sum = 0, n = 0;
                        for (k = -radius; k <= radius; k++)
                        {
                            int yy = y + k;
                            if (yy < 0 || yy >= h) continue;
                            sum += t[(yy * w + x) * 4 + c]; n++;
                        }
                        a[(y * w + x) * 4 + c] = (byte)(sum / n);
                    }
        }
        for (int i = 0; i < a.Length; i += 4)
        {
            a[i] = (byte)(a[i] * keep); a[i + 1] = (byte)(a[i + 1] * keep); a[i + 2] = (byte)(a[i + 2] * keep);
            a[i + 3] = 255;
        }
        Put(b, a);
    }

    public static Bitmap Gradient(int w, int h)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b))
        using (LinearGradientBrush br = new LinearGradientBrush(new Rectangle(0, 0, w, h),
                   Color.FromArgb(48, 48, 60), Color.FromArgb(20, 20, 28), LinearGradientMode.Vertical))
            g.FillRectangle(br, 0, 0, w, h);
        return b;
    }

    // Drops the fully transparent margins around a logo.
    public static Bitmap Trim(Image src)
    {
        Bitmap b = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) g.DrawImage(src, 0, 0, src.Width, src.Height);
        byte[] a = Get(b);
        int w = b.Width, h = b.Height, minx = w, miny = h, maxx = -1, maxy = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (a[(y * w + x) * 4 + 3] > 8)
                {
                    if (x < minx) minx = x; if (x > maxx) maxx = x;
                    if (y < miny) miny = y; if (y > maxy) maxy = y;
                }
        if (maxx < 0) return b;
        Bitmap r = b.Clone(new Rectangle(minx, miny, maxx - minx + 1, maxy - miny + 1), PixelFormat.Format32bppArgb);
        b.Dispose();
        return r;
    }

    // Draws a logo inside the box, centred, aspect kept, with a soft shadow.
    public static void DrawLogo(Bitmap dst, Image logo, int boxW, int boxH, bool shadow)
    {
        using (Bitmap t = Trim(logo))
        {
            double s = Math.Min((double)boxW / t.Width, (double)boxH / t.Height);
            if (s > 2.0) s = 2.0;
            int dw = Math.Max(1, (int)Math.Round(t.Width * s)), dh = Math.Max(1, (int)Math.Round(t.Height * s));
            int ox = (dst.Width - dw) / 2, oy = (dst.Height - dh) / 2;
            using (Bitmap fit = new Bitmap(dw, dh, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Hq(fit)) g.DrawImage(t, 0, 0, dw, dh);
                using (Graphics g = Hq(dst))
                {
                    if (shadow)
                    {
                        Bitmap sh = Silhouette(fit, dst.Width, dst.Height, ox, oy + 1);
                        g.DrawImage(sh, 0, 0);
                        sh.Dispose();
                    }
                    g.DrawImage(fit, ox, oy, dw, dh);
                }
            }
        }
    }

    static Bitmap Silhouette(Bitmap logo, int w, int h, int ox, int oy)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        byte[] src = Get(logo);
        byte[] a = new byte[w * h * 4];
        byte[] t = new byte[w * h];
        byte[] al = new byte[w * h];
        int lw = logo.Width, lh = logo.Height, x, y, k, r = 2;
        for (y = 0; y < lh; y++)
            for (x = 0; x < lw; x++)
            {
                int X = x + ox, Y = y + oy;
                if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
                al[Y * w + X] = src[(y * lw + x) * 4 + 3];
            }
        for (int pass = 0; pass < 2; pass++)
        {
            for (y = 0; y < h; y++) for (x = 0; x < w; x++)
            { int s = 0, n = 0; for (k = -r; k <= r; k++) { int xx = x + k; if (xx < 0 || xx >= w) continue; s += al[y * w + xx]; n++; } t[y * w + x] = (byte)(s / n); }
            for (y = 0; y < h; y++) for (x = 0; x < w; x++)
            { int s = 0, n = 0; for (k = -r; k <= r; k++) { int yy = y + k; if (yy < 0 || yy >= h) continue; s += t[yy * w + x]; n++; } al[y * w + x] = (byte)(s / n); }
        }
        for (int i = 0; i < w * h; i++) a[i * 4 + 3] = (byte)(al[i] * 0.8);
        Put(b, a);
        return b;
    }

    // Banner or icon: logo over the background (blurred, dimmed), or the
    // background alone, filling the frame.
    public static Bitmap Compose(Image bg, Image logo, int w, int h, int boxW, int boxH, int blur)
    {
        Bitmap b;
        if (bg != null)
        {
            b = Cover(bg, w, h);
            if (logo != null) BlurDarken(b, blur, 0.6);
        }
        else
            b = Gradient(w, h);
        if (logo != null) DrawLogo(b, logo, boxW, boxH, true);
        return b;
    }

    // A dedicated icon fitted over the (blurred, dimmed) background.
    public static Bitmap ComposeIcon(Image bg, Image icon)
    {
        Bitmap b = bg != null ? Cover(bg, 48, 48) : Gradient(48, 48);
        if (bg != null) BlurDarken(b, 1, 0.6);
        using (Graphics g = Hq(b))
        {
            double s = Math.Min(48.0 / icon.Width, 48.0 / icon.Height);
            int dw = Math.Max(1, (int)Math.Round(icon.Width * s)), dh = Math.Max(1, (int)Math.Round(icon.Height * s));
            g.DrawImage(icon, (48 - dw) / 2, (48 - dh) / 2, dw, dh);
        }
        return b;
    }

    // A picture whole (aspect kept) inside w x h, over a blurred, dimmed copy
    // of itself filling the frame, or over transparency.
    public static Bitmap FitOver(Image img, int w, int h, int margin, bool transparent)
    {
        Bitmap b;
        if (transparent)
        {
            b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(b)) g.Clear(Color.Transparent);
        }
        else
        {
            b = Cover(img, w, h);
            BlurDarken(b, Math.Max(1, w / 64), 0.55);
        }
        double s = Math.Min((double)(w - 2 * margin) / img.Width, (double)(h - 2 * margin) / img.Height);
        int dw = Math.Max(1, (int)Math.Round(img.Width * s)), dh = Math.Max(1, (int)Math.Round(img.Height * s));
        using (Graphics g = Hq(b)) g.DrawImage(img, (w - dw) / 2, (h - dh) / 2, dw, dh);
        return b;
    }

    // Only the logo, on a fully transparent banner: the HOME menu shows
    // through around it.
    public static Bitmap LogoOnly(Image logo, int w, int h, int boxW, int boxH)
    {
        Bitmap b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(b)) g.Clear(Color.Transparent);
        DrawLogo(b, logo, boxW, boxH, false);
        return b;
    }

    public static void SaveAlpha(Bitmap b, string path)
    {
        b.Save(path, ImageFormat.Png);
    }

    // Icons store no alpha: save flattened, the way it will look.
    public static void SaveOpaque(Bitmap b, string path)
    {
        using (Bitmap o = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb))
        {
            using (Graphics g = Graphics.FromImage(o)) { g.Clear(Color.Black); g.DrawImage(b, 0, 0, b.Width, b.Height); }
            o.Save(path, ImageFormat.Png);
        }
    }
}
