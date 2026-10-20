#language slang 2026
// ASCII sharks: sharks drawn as a grid of glyph cells that swim behind the
// terminal text. Inspired by https://github.com/stackedlol/ascii-sharks
//
// Every pixel works out which glyph cell it is in, tests the cell centre
// against each shark's body (a bent spine that follows its swim path), and
// draws a shaded block with a procedurally rendered 5x7 glyph on top.

import kitty_custom_shader_types;

// ---- tunables (override with `var` in a pipeline file) ----
static const float2 CELL_PX = float2(16.0, 26.0); // glyph cell size in device pixels
static const int NUM_SHARKS = 4;                  // up to 8
static const float SHARK_LENGTH = 0.6;            // length of the nearest shark, in window heights
static const float SPEED = 1.0;                   // swim speed multiplier
static const float OPACITY = 0.85;                // opacity of the nearest shark
static const float ACCENT_CHANCE = 0.06;          // fraction of body cells tinted with an accent colour
static const bool BEHIND_TEXT = true;             // keep terminal text and cell colours on top
static const float TEXT_THRESHOLD = 0.02;         // linear RGB distance from the background that counts as text
static const bool SHOW_GRID = true;               // leave a 1px gap between cell blocks

// ---- internals ----
static const float PI = 3.14159265359;
static const float TAU = 6.28318530718;
static const float PERIOD = 3600.0; // swim paths repeat after this many seconds; sharks may jump once per period
static const int SPINE = 14;        // spine segments per shark
static const float SWIM_HZ = 0.5;   // tail beats per second

static const int FLAG_NONE = 0;
static const int FLAG_BODY = 1;
static const int FLAG_EDGE = 2;
static const int FLAG_FIN = 3;
static const int FLAG_RIDGE = 4;
static const int FLAG_EYE = 5;
static const int FLAG_MARK = 6;
static const int FLAG_GILL = 7;

// 5x7 glyphs, one row per 5 bits, MSB on the left. x holds rows 0-3, y rows 4-6.
static const uint2 GLYPHS[14] = {
    uint2(0u, 396u),        //  0 .
    uint2(135424u, 0u),     //  1 '
    uint2(266240u, 0u),     //  2 `
    uint2(0u, 12424u),      //  3 ,
    uint2(12672u, 12672u),  //  4 :
    uint2(12672u, 12424u),  //  5 ;
    uint2(271240u, 8486u),  //  6 t
    uint2(812100u, 8803u),  //  7 %
    uint2(508430u, 1086u),  //  8 S
    uint2(574788u, 10801u), //  9 X
    uint2(476718u, 17966u), // 10 8
    uint2(338922u, 32074u), // 11 #
    uint2(476917u, 23055u), // 12 @
    uint2(465u, 17966u),    // 13 o
};
// Sparse glyphs on bright skin, dense in shadow: ":;t%SX8#@"
static const int SKIN_RAMP[9] = { 4, 5, 6, 7, 8, 9, 10, 11, 12 };
static const int FIN_GLYPHS[5] = { 7, 5, 6, 8, 4 };  // "%;tS:"
static const int RIDGE_GLYPHS[3] = { 12, 10, 7 };    // "@8%"
static const int MARK_GLYPHS[3] = { 11, 7, 12 };     // "#%@"
static const int EDGE_GLYPHS[4] = { 0, 1, 3, 2 };    // ".',`"

static const float3 ACCENTS[7] = {
    float3(0.878, 0.537, 0.173), float3(0.878, 0.227, 0.196), float3(0.706, 0.290, 0.878),
    float3(0.200, 0.784, 0.800), float3(0.235, 0.710, 0.290), float3(0.192, 0.314, 0.910),
    float3(0.851, 0.757, 0.290),
};

// ---- helpers ----

float
hash12(float2 p) {
    float3 p3 = frac(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float
sd_triangle(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                   float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

bool
glyph_bit(int g, int col, int row) { // row 0 is the top row
    uint2 bits = GLYPHS[g];
    if (row < 4) return ((bits.x >> uint((3 - row) * 5 + (4 - col))) & 1u) != 0u;
    return ((bits.y >> uint((6 - row) * 5 + (4 - col))) & 1u) != 0u;
}

// ---- shark anatomy, all in fractions of body length; s runs snout (0) to tail (1) ----

struct Shape {
    float4 pectoral; // leading root, trailing root, tip position, reach
    float4 pelvic;
    float caudal;    // forked tail reach
    float2 dorsal, second_dorsal;
    float eye;       // eye position along the body, 0 when eyes sit on a cephalofoil
    float2 gills;
    float4 head;     // cephalofoil: half-span, sweep, depth, notch; zero span for none
    bool barred;
    float3 tint;
};

Shape
shark_shape(int kind) {
    Shape sh;
    sh.head = float4(0.0);
    sh.barred = false;
    if (kind == 1) { // hammerhead
        sh.pectoral = float4(0.17, 0.4, 0.5, 0.22);
        sh.pelvic = float4(0.56, 0.63, 0.67, 0.075);
        sh.caudal = 0.11;
        sh.dorsal = float2(0.28, 0.44);
        sh.second_dorsal = float2(0.7, 0.74);
        sh.eye = 0.0;
        sh.gills = float2(0.16, 0.26);
        sh.head = float4(0.17, 0.035, 0.09, 0.0);
        sh.tint = float3(0.96, 0.98, 0.9);
    } else if (kind == 2) { // tiger
        sh.pectoral = float4(0.15, 0.42, 0.53, 0.25);
        sh.pelvic = float4(0.57, 0.65, 0.69, 0.085);
        sh.caudal = 0.095;
        sh.dorsal = float2(0.33, 0.46);
        sh.second_dorsal = float2(0.71, 0.75);
        sh.eye = 0.1;
        sh.gills = float2(0.19, 0.28);
        sh.barred = true;
        sh.tint = float3(1.02, 0.95, 0.84);
    } else if (kind == 3) { // mako
        sh.pectoral = float4(0.18, 0.4, 0.5, 0.21);
        sh.pelvic = float4(0.58, 0.64, 0.68, 0.06);
        sh.caudal = 0.13;
        sh.dorsal = float2(0.34, 0.45);
        sh.second_dorsal = float2(0.76, 0.79);
        sh.eye = 0.13;
        sh.gills = float2(0.2, 0.3);
        sh.tint = float3(0.78, 0.9, 1.2);
    } else { // classic
        sh.pectoral = float4(0.15, 0.43, 0.55, 0.26);
        sh.pelvic = float4(0.57, 0.65, 0.69, 0.085);
        sh.caudal = 0.085;
        sh.dorsal = float2(0.33, 0.47);
        sh.second_dorsal = float2(0.71, 0.76);
        sh.eye = 0.12;
        sh.gills = float2(0.19, 0.29);
        sh.tint = float3(0.92, 0.97, 1.05);
    }
    return sh;
}

float
classic_half_width(float s) {
    if (s < 0.13) return 0.09 * pow(sin(s / 0.13 * PI * 0.5), 0.95);
    if (s < 0.3) return 0.09 + 0.016 * smoothstep(0.13, 0.3, s);
    if (s < 0.84) return 0.019 + 0.087 * pow(1.0 - (s - 0.3) / 0.54, 1.25);
    float k = (s - 0.84) / 0.16;
    return 0.019 * (1.0 - k) + 0.012 * sin(k * PI);
}

// Top-down half-width of the body at s, zero outside the body.
float
half_width(int kind, float s) {
    if (s < 0.0 || s > 1.0) return 0.0;
    if (kind == 1) {
        if (s < 0.06) return 0.045;
        if (s < 0.3) return 0.045 + 0.061 * smoothstep(0.06, 0.3, s);
        return classic_half_width(s) * 0.92;
    }
    if (kind == 2) {
        if (s < 0.13) return 0.1 * pow(sin(s / 0.13 * PI * 0.5), 0.45);
        if (s < 0.3) return 0.1 + 0.014 * smoothstep(0.13, 0.3, s);
        if (s < 0.84) return 0.019 + 0.095 * pow(1.0 - (s - 0.3) / 0.54, 1.2);
        float k = (s - 0.84) / 0.16;
        return 0.019 * (1.0 - k) + 0.012 * sin(k * PI);
    }
    if (kind == 3) {
        if (s < 0.17) return 0.088 * pow(sin(s / 0.17 * PI * 0.5), 1.5);
        if (s < 0.32) return 0.088 + 0.012 * smoothstep(0.17, 0.32, s);
        if (s < 0.86) return 0.014 + 0.086 * pow(1.0 - (s - 0.32) / 0.54, 1.45);
        float k = (s - 0.86) / 0.14;
        return 0.014 * (1.0 - k) + 0.01 * sin(k * PI);
    }
    return classic_half_width(s);
}

float
fin_distance(int kind, float4 fin, float s, float ay) {
    float2 root_a = float2(fin.x, half_width(kind, fin.x) * 0.9);
    float2 root_b = float2(fin.y, half_width(kind, fin.y) * 0.9);
    return sd_triangle(float2(s, ay), root_a, root_b, float2(fin.z, fin.w));
}

// Classify the body point (s, y). y is the signed lateral offset; margin is
// roughly half a cell, used for the soft edge band. n receives the lateral
// position across the body in [-1, 1], used for shading.
int
classify(int kind, Shape sh, float s, float y, float margin, out float n) {
    float ay = abs(y);
    float hw = half_width(kind, s);
    n = 0.0;

    if (hw > 0.0 && ay <= hw) {
        n = y / hw;
        if (sh.eye > 0.0 && length(float2(s - sh.eye, ay - hw * 0.6)) < max(0.018, margin * 0.6)) return FLAG_EYE;
        if (s > sh.gills.x && s < sh.gills.y && ay > hw * 0.5 &&
            frac((s - sh.gills.x) / (sh.gills.y - sh.gills.x) * 4.0) < 0.4) return FLAG_GILL;
        if (ay < max(0.014, margin * 0.5) &&
            ((s > sh.dorsal.x && s < sh.dorsal.y) || (s > sh.second_dorsal.x && s < sh.second_dorsal.y))) return FLAG_RIDGE;
        if (sh.barred && s > 0.28 && s < 0.82 && ay < hw * 0.85 && sin(s * 70.0 + ay * 25.0) > 0.55) return FLAG_MARK;
        return FLAG_BODY;
    }

    float d = ay - hw;
    if (s < 0.0) d = length(float2(s, ay));
    if (s > 1.0) d = length(float2(s - 1.0, ay));

    float fin = min(fin_distance(kind, sh.pectoral, s, ay), fin_distance(kind, sh.pelvic, s, ay));
    if (sh.caudal > 0.0) fin = min(fin, sd_triangle(float2(s, ay), float2(0.84, 0.0), float2(1.03, 0.0), float2(1.09, sh.caudal * 1.15)));
    if (fin < 0.0) {
        n = 0.5 * sign(y);
        return FLAG_FIN;
    }
    d = min(d, fin);

    if (sh.head.x > 0.0) { // cephalofoil
        float u = ay / sh.head.x;
        float front = sh.head.y * u * u + sh.head.w * (1.0 - smoothstep(0.0, 0.15, u));
        float back = front + sh.head.z * (1.0 - 0.45 * u * u);
        if (u < 1.0 && s >= front && s <= back) {
            if (u > 0.86 && s < front + sh.head.z * 0.6) return FLAG_EYE;
            n = 0.6 * u * sign(y);
            return FLAG_BODY;
        }
        float hd = max(max(front - s, s - back), (u - 1.0) * sh.head.x);
        d = min(d, hd);
    }

    return d < margin ? FLAG_EDGE : FLAG_NONE;
}

// ---- swimming ----

// Each shark crosses the window in a straight lane with a gentle vertical
// meander. Between crossings it is fully off screen, where it picks a new
// lane and direction. Its horizontal speed never drops to zero, so the
// spine walk below always takes small, even steps.
struct Path {
    float x0, dir, vx;           // head x at tau, swim direction, horizontal speed
    float lane, amp, omega, phase;
};

float
path_y(Path p, float tau) {
    return p.lane + p.amp * (sin(p.omega * tau + p.phase) + 0.3 * sin(3.0 * p.omega * tau + 2.0 * p.phase));
}

float
path_vy(Path p, float tau) {
    return p.amp * p.omega * (cos(p.omega * tau + p.phase) + 0.9 * cos(3.0 * p.omega * tau + 2.0 * p.phase));
}

// Colour and alpha of the pixel px for shark i, in un-premultiplied form.
float4
shark_pixel(int i, float2 px, float2 cell, float2 c, float aspect, float vh, float tau, bool dark) {
    float z = (float(i) + 1.0) / float(NUM_SHARKS); // nearer sharks are bigger and more opaque
    float L = SHARK_LENGTH * lerp(0.55, 1.0, z);
    float alpha = OPACITY * lerp(0.5, 1.0, z);
    int kind = i % 4;

    float4 h = float4(hash12(float2(i, 1.7)), hash12(float2(i, 9.3)), hash12(float2(i, 4.1)), hash12(float2(i, 6.6)));
    float pad = 1.4 * L; // off-screen room, so the whole shark is hidden when it wraps
    float span = aspect + 2.0 * pad;
    Path p;
    p.vx = L * (0.12 + 0.06 * h.z);
    float xu = p.vx * tau + h.x * span;
    float pass = floor(xu / span);
    float m = xu - pass * span;
    p.dir = hash12(float2(pass, float(i) * 7.0 + 0.5)) < 0.5 ? 1.0 : -1.0;
    p.x0 = p.dir > 0.0 ? m - pad : aspect + pad - m;
    p.lane = 0.25 + 0.5 * hash12(float2(pass, float(i) * 3.0 + 1.5));
    p.amp = 0.08 + 0.05 * h.y;
    p.omega = TAU / PERIOD * (20.0 + 7.0 * float(i)); // whole cycles per PERIOD
    p.phase = h.w * TAU;

    float2 head = float2(p.x0, path_y(p, tau));
    if (distance(c, head) > 1.3 * L) return float4(0.0);

    // Build the spine by walking back along the path, one segment length at a time
    float2 q[SPINE + 1];
    float swim = tau * TAU * SWIM_HZ + h.w * TAU;
    float tt = tau;
    float seg = L / float(SPINE);
    [ForceUnroll]
    for (int k = 0; k <= SPINE; k++) {
        float2 v = float2(p.dir * p.vx, path_vy(p, tt));
        float sp = length(v);
        float2 perp = float2(-v.y, v.x) / sp;
        float s = float(k) / float(SPINE);
        float wiggle = 0.045 * L * (0.2 + s * s) * sin(swim - s * TAU * 0.9);
        q[k] = float2(p.x0 - p.dir * p.vx * (tau - tt), path_y(p, tt)) + perp * wiggle;
        tt -= seg / sp;
    }

    // Project the cell centre onto the spine
    float best = 1e9, bs = 0.0, by = 0.0;
    float2 bperp = float2(0.0, 1.0);
    [ForceUnroll]
    for (int k = 0; k < SPINE; k++) {
        float2 a = q[k], ab = q[k + 1] - q[k];
        float len2 = max(dot(ab, ab), 1e-10);
        float lo = k == 0 ? -0.8 : 0.0;           // room for the snout and cephalofoil
        float hi = k == SPINE - 1 ? 2.0 : 1.0;    // room for the tail fin
        float hh = clamp(dot(c - a, ab) / len2, lo, hi);
        float2 delta = c - (a + ab * hh);
        float dd = dot(delta, delta);
        if (dd < best) {
            best = dd;
            bs = (float(k) + hh) / float(SPINE);
            float2 dn = ab * rsqrt(len2);
            by = (dn.x * delta.y - dn.y * delta.x) / L;
            bperp = float2(-dn.y, dn.x);
        }
    }

    float margin = 0.35 * max(CELL_PX.x, CELL_PX.y) / vh / L;
    float n;
    Shape sh = shark_shape(kind);
    int flag = classify(kind, sh, bs, by, margin, n);
    if (flag == FLAG_NONE) return float4(0.0);

    // Shading: a rounded back lit from the upper left
    float lit = dot(bperp, normalize(float2(-0.45, 0.9))) * n;
    float shade = clamp(0.58 + 0.3 * lit + 0.15 * (1.0 - n * n), 0.0, 1.0);
    float cell_seed = hash12(cell + float(i) * 37.0);
    float flick = hash12(cell * 1.31 + floor(tau * 3.0 + cell_seed * 7.0));

    int g = 0;
    bool block = true;
    if (flag == FLAG_BODY) {
        g = SKIN_RAMP[clamp(int((1.0 - shade) * 9.0 + (flick - 0.5) * 2.5), 0, 8)];
    } else if (flag == FLAG_FIN) {
        g = FIN_GLYPHS[min(int(flick * 5.0), 4)];
        shade *= 0.85;
    } else if (flag == FLAG_RIDGE) {
        g = RIDGE_GLYPHS[min(int(flick * 3.0), 2)];
        shade *= 0.7;
    } else if (flag == FLAG_MARK) {
        g = MARK_GLYPHS[min(int(flick * 3.0), 2)];
        shade *= 0.6;
    } else if (flag == FLAG_GILL) {
        g = 4;
        shade *= 0.8;
    } else if (flag == FLAG_EYE) {
        g = 13;
        shade *= 0.35;
    } else { // FLAG_EDGE
        g = EDGE_GLYPHS[min(int(flick * 4.0), 3)];
        block = false;
        alpha *= 0.7;
    }

    float base = dark ? 0.05 + 0.22 * shade : 0.12 + 0.55 * shade; // linear grey
    float3 block_col = sh.tint * base;
    if ((flag == FLAG_BODY || flag == FLAG_FIN) && cell_seed < ACCENT_CHANCE) {
        int ai = int(hash12(cell + floor(tau * 0.5)) * 7.0) % 7;
        block_col = pow(ACCENTS[ai], float3(2.2)) * lerp(0.35, 0.8, shade);
    }
    float3 ink = dark ? block_col * 2.6 + 0.05 : block_col * 0.22;

    // Rasterise the cell: a block with a 1px grid gap and a pixel-font glyph
    float2 lp = px - cell * CELL_PX;
    float ps = max(1.0, floor(min((CELL_PX.x - 4.0) / 5.0, (CELL_PX.y - 6.0) / 7.0)));
    float2 origin = floor((CELL_PX - float2(5.0, 7.0) * ps) * 0.5);
    int col = int(floor((lp.x - origin.x) / ps));
    int row = int(floor((origin.y + 7.0 * ps - lp.y) / ps));
    if (lp.x >= origin.x && lp.y >= origin.y && col < 5 && row >= 0 && row < 7 && glyph_bit(g, col, row)) return float4(ink, alpha);
    if (!block) return float4(0.0);
    if (SHOW_GRID && (lp.x < 1.0 || lp.y < 1.0)) return float4(0.0);
    return float4(block_col, alpha);
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 vsz = max(float2(d.viewport_size_pixels), float2(1.0));
    float2 px = t.pos * vsz;
    float2 cell = floor(px / CELL_PX);
    float2 c = (cell + 0.5) * CELL_PX / vsz.y; // cell centre, in window heights
    float aspect = vsz.x / vsz.y;
    float tau = fmod(d.timestamp * SPEED, PERIOD);
    bool dark = dot(d.background.rgb, float3(0.2126, 0.7152, 0.0722)) < 0.2;

    // Composite far to near
    float3 rgb = float3(0.0);
    float a = 0.0;
    [ForceUnroll]
    for (int i = 0; i < NUM_SHARKS; i++) {
        float4 s = shark_pixel(i, px, cell, c, aspect, vsz.y, tau, dark);
        rgb = rgb * (1.0 - s.a) + s.rgb * s.a;
        a = a * (1.0 - s.a) + s.a;
    }
    if (a <= 0.0) return color;

    if (BEHIND_TEXT) {
        float3 d1 = abs(color.rgb - d.background.rgb);
        float3 d2 = abs(color.rgb - d.active_window_background.rgb);
        float diff = min(max(d1.r, max(d1.g, d1.b)), max(d2.r, max(d2.g, d2.b)));
        if (diff > TEXT_THRESHOLD) return color;
    }
    return float4(color.rgb * (1.0 - a) + rgb, color.a + (1.0 - color.a) * a);
}
