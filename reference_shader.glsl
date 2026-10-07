// GLSL-like REFERENCE ONLY. Port the same math to Metal (iOS) or AGSL (Android 13+).
// One fragment shader + one RGB mask texture.

uniform sampler2D uMasks;          // R/G/B = blurred background masks A/B/C
uniform vec2      uResolutionPx;   // real render target size
uniform float     uTimeSec;        // monotonically increasing seconds

const vec2  DESIGN = vec2(2160.0, 3840.0);
const float MASTER_LOOP = 24.0;
const float TAU = 6.28318530718;

const vec3 BG_COLOR    = vec3(20.0, 21.0, 20.0) / 255.0; // #141514
const vec3 SHAPE_COLOR = vec3(45.0, 48.0, 47.0) / 255.0; // #2D302F

const float BG_SPEED = 2.0;
const float BG_SCALE = 2.0;
const float DOT_OPACITY_CTRL = 0.2;
const float TD_AMOUNT = 20.0;
const float TD_SIZE = 6.0;
const float TD_STRETCH = 4.0;
const float EDGE_FADE_PX = 180.0;

float saturate1(float x) { return clamp(x, 0.0, 1.0); }
float smooth01(float x) { x = saturate1(x); return x*x*(3.0-2.0*x); }
float fract1(float x) { return x - floor(x); }

vec2 toDesignPx(vec2 fragPx) {
    float s = max(uResolutionPx.x / DESIGN.x, uResolutionPx.y / DESIGN.y);
    vec2 visibleDesign = uResolutionPx / s;
    vec2 crop = (DESIGN - visibleDesign) * 0.5;
    return fragPx / s + crop;
}

vec2 inverseTransformPx(vec2 p, vec2 pivot, vec2 translatePx, vec2 scaleXY, float radians) {
    p -= pivot + translatePx;
    float c = cos(-radians), s = sin(-radians);
    p = mat2(c, -s, s, c) * p;
    p /= scaleXY;
    return p + pivot;
}

float hash21(vec2 p) {
    return fract1(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f*f*(3.0-2.0*f);
    float a = hash21(i);
    float b = hash21(i + vec2(1,0));
    float c = hash21(i + vec2(0,1));
    float d = hash21(i + vec2(1,1));
    return mix(mix(a,b,u.x), mix(c,d,u.x), u.y) * 2.0 - 1.0;
}

float fbm2(vec2 p) {
    float n = 0.0;
    n += 0.67 * valueNoise(p);
    n += 0.33 * valueNoise(p * 2.0 + 7.13);
    return n;
}

vec3 turbulence(vec2 nUV, float tdPhase) {
    float baseFreq = 0.65 / max(0.15, TD_SIZE);
    vec2 loopOffset = vec2(cos(tdPhase), sin(tdPhase)) * 0.42;
    vec2 q = nUV * baseFreq * 7.0;
    float nx = fbm2(q + loopOffset);
    float ny = fbm2(q + vec2(13.7, 9.2) + loopOffset * 0.8);
    float ns = fbm2(q + vec2(-6.5, 4.1) + loopOffset * 1.15);
    return vec3(nx, ny, ns);
}

float frameEdgeFade(vec2 p) {
    float d = min(min(p.x, DESIGN.x-p.x), min(p.y, DESIGN.y-p.y));
    return smooth01(d / EDGE_FADE_PX);
}

float dotLayer(vec2 p, float tdPhase) {
    const float Y0 = 2328.0;
    const float H = 1512.0;
    if (p.y < Y0 || p.y > DESIGN.y) return 0.0;

    vec2 local = vec2(p.x, p.y - Y0);
    vec2 cell = floor(vec2((local.x - 24.0) / 48.0 + 0.5,
                           (local.y - 10.0) / 48.0 + 0.5));
    cell.x = clamp(cell.x, 0.0, 44.0);
    cell.y = clamp(cell.y, 0.0, 31.0);

    vec2 center = vec2(24.0 + cell.x * 48.0,
                       10.0 + cell.y * 48.0);

    vec2 nUV = center / vec2(2160.0, 1512.0);
    vec3 n = turbulence(nUV, tdPhase);

    float depth = cell.y / 31.0;
    float fade = frameEdgeFade(vec2(center.x, Y0 + center.y));
    float amount = TD_AMOUNT * mix(0.22, 1.0, depth) * fade;

    center += vec2(n.x * 10.0, n.y * 13.0) * amount;

    // No per-dot rotation. Only proportional bulge + small X/Y stretch.
    float bulge = 1.0 + abs(n.z) * 0.20 * TD_STRETCH * fade;
    float sx = bulge * (1.0 + abs(n.x) * 0.18 * TD_STRETCH * fade);
    float sy = bulge * (1.0 + abs(n.y) * 0.18 * TD_STRETCH * fade);
    sx = clamp(sx, 0.84, 1.65);
    sy = clamp(sy, 0.84, 1.65);

    vec2 d = (local - center) / vec2(sx, sy);
    float aa = 1.25;
    float dot = 1.0 - smoothstep(9.0-aa, 9.0+aa, length(d));

    float verticalMask = saturate1(local.y / H);
    return dot * verticalMask * 0.15 * DOT_OPACITY_CTRL;
}

float sampleMaskChannel(vec2 designPx, int channel, vec2 pivot, vec2 tr, vec2 sc, float rot) {
    vec2 srcPx = inverseTransformPx(designPx, pivot, tr, sc, rot);
    vec2 uv = srcPx / DESIGN;
    if (any(lessThan(uv, vec2(0))) || any(greaterThan(uv, vec2(1)))) return 0.0;
    vec3 m = texture(uMasks, uv).rgb;
    return channel == 0 ? m.r : (channel == 1 ? m.g : m.b);
}

vec4 renderBackground(vec2 fragPx) {
    vec2 p = toDesignPx(fragPx);

    float master = fract1(uTimeSec / MASTER_LOOP);
    float bgPhase = master * TAU * 4.0;
    float tdPhase = master * TAU;

    float s = BG_SCALE;

    vec2 aTr = vec2(sin(bgPhase)*34.0*s, cos(bgPhase*2.0)*26.0*s);
    vec2 aSc = vec2(1.0 + sin(bgPhase*2.0+0.4)*0.020*s,
                    1.0 + cos(bgPhase+1.1)*0.028*s);
    float aRot = radians(sin(bgPhase+0.2)*0.55*s);

    vec2 bTr = vec2(cos(bgPhase+0.8)*26.0*s, sin(bgPhase*2.0+1.3)*20.0*s);
    vec2 bSc = vec2(1.0 + sin(bgPhase+1.7)*0.024*s,
                    1.0 + cos(bgPhase*2.0+0.3)*0.018*s);
    float bRot = radians(cos(bgPhase+1.0)*0.42*s);

    vec2 cTr = vec2(sin(bgPhase+2.2)*28.0*s, cos(bgPhase*2.0+2.7)*22.0*s);
    vec2 cSc = vec2(1.0 + cos(bgPhase+2.4)*0.018*s,
                    1.0 + sin(bgPhase*2.0+1.0)*0.026*s);
    float cRot = radians(sin(bgPhase+2.3)*0.50*s);

    float ma = sampleMaskChannel(p, 0, vec2(1442.2636,1232.4895), aTr, aSc, aRot);
    float mb = sampleMaskChannel(p, 1, vec2(962.2995,647.3960),   bTr, bSc, bRot);
    float mc = sampleMaskChannel(p, 2, vec2(1143.5431,2594.9563),cTr, cSc, cRot);

    float shapeAlpha = 1.0 - (1.0-ma)*(1.0-mb)*(1.0-mc);
    vec3 color = mix(BG_COLOR, SHAPE_COLOR, shapeAlpha);

    float dots = dotLayer(p, tdPhase);
    color = mix(color, vec3(1.0), dots);

    float dither = hash21(floor(fragPx)) - 0.5;
    color += dither * (1.0 / 255.0) * 1.2;

    return vec4(color, 1.0);
}

// Platform entry point should call renderBackground(fragCoord).
