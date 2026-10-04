// The raccoon: a sprite in a small click-through window, walked around the
// focused window by a timer. See misc/raccoon.h.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#include "misc/raccoon.h"

bool g_raccoon_on = false;
int g_raccoon_eats = RACCOON_EATS_LAP;
bool g_raccoon_follow = false;
const char* g_raccoon_eats_names[] = { "off", "lap", "nibble", "stay", "sometimes" };

static const CGFloat kSize = 64;         // sprite box, points
static const float kSpeed = 230.f;       // points per second
static const float kFade = 50.f;         // distance over which it fades in/out
static const NSTimeInterval kStop = 1.7; // one stop to munch or wiggle
static const NSTimeInterval kPeek = 2.2;   // peeking over the edge before a visit
static const NSTimeInterval kStartle = 0.7; // frozen, staring, once it notices the pointer
static const CGFloat kNotice = 80;          // how near the pointer gets before it does
static const float kFlee = 260.f;           // how far it bolts before it is gone
static const NSTimeInterval kDig = 2.6;    // nibbling down through the band, bite by bite
static const NSTimeInterval kNibble = kDig + 1.5;   // ...then bursting back out of the hole
static const CGFloat kPad = 48;            // room around the sprite for crumbs to fly
static const CGFloat kHead = kSize * 0.5;  // room above it to leap when it bursts out
enum { kCrumbs = 40 };
static const NSTimeInterval kCrumbLife = 0.9;

// One bit of yarn knocked loose, in screen coordinates (y grows downward).
struct crumb { CGFloat x, y, vx, vy; CFAbsoluteTime born; };
// raccoon.png, when it has them all: a run cycle, then two little loops for
// when it stops. Munching, it sits facing you and looks down at its yarn.
enum { kRunFrames = 6, kMunchFrame = 6, kMunchFrames = 6, kWiggleFrame = 12, kAllFrames = 15 };

// A maximised window's sweater is off the display, and the raccoon would be
// too. Pull its lap in to the edge of the screen the window is mostly on.
// Null when the window is on no display at all: some apps park windows far
// off-screen, and there is nobody there to run for.
static CGRect raccoon_keep_onscreen(CGRect track) {
  // WindowServer's y grows downward from the top of the primary display.
  CGFloat top = NSScreen.screens.firstObject.frame.size.height, best = 0;
  CGRect kept = CGRectNull;
  for (NSScreen* screen in NSScreen.screens) {
    NSRect f = screen.frame;
    CGRect display = CGRectMake(f.origin.x, top - NSMaxY(f), f.size.width, f.size.height);
    CGRect seen = CGRectIntersection(track, display);
    if (CGRectIsNull(seen) || seen.size.width * seen.size.height <= best) continue;
    best = seen.size.width * seen.size.height;
    kept = CGRectIntersection(track, CGRectInset(display, kSize * 0.4, kSize * 0.4));
  }
  return kept;
}

// Where a point on the pulled-in lap sits on the band itself.
static CGPoint raccoon_onto_band(CGRect track, CGRect band, CGPoint p) {
  return CGPointMake(
      band.origin.x + (p.x - track.origin.x) * band.size.width / fmax(track.size.width, 1),
      band.origin.y + (p.y - track.origin.y) * band.size.height / fmax(track.size.height, 1));
}

@interface KnitRaccoon : NSObject
@property(strong) NSWindow* window;
@property(strong) CALayer* sprite;
@property(strong) CALayer* clip;         // what it sinks out of: its far edge rests on the band
@property(strong) NSArray<CALayer*>* crumbLayers;
@property(strong) CATextLayer* bang;     // the "!" over a startled raccoon
@property(strong) NSArray* frames;       // CGImageRef, facing right
@property(strong) NSTimer* tick;
@property(strong) NSTimer* next;
@end

@implementation KnitRaccoon {
  uint32_t _wid;          // window being visited; 0 when idle
  uint32_t _eatenWid;     // "stay": the window left bare by the last visit
  int _mode;              // this visit's appetite, resolved from g_raccoon_eats
  bool _reknit;           // knit the sweater back when the visit ends
  float _start, _dist, _bitten, _nibbleAt;
  int _nibbles;           // bites taken so far during this stop
  CFAbsoluteTime _last, _stopUntil, _stopLength;
  CFAbsoluteTime _peekUntil;   // 0 when this visit has no peek (no front-view frames)
  CFAbsoluteTime _caughtAt;    // when the pointer startled it; 0 until then
  float _fleeEnd;              // the distance at which a bolting raccoon is gone
  uint32_t _yarn;              // the sweater's colour, for crumbs
  bool _burst;                 // this stop's leap out of the hole has thrown its crumbs
  struct crumb _crumbs[kCrumbs];
  int _nextCrumb;
}

// `raccoon.png` in the bundle is a horizontal strip of square frames, facing
// right. Without it the system emoji stands in. A strip without the stopped
// loops is one run cycle.
- (void)loadFrames {
  NSMutableArray* frames = [NSMutableArray array];
  NSString* path = [NSBundle.mainBundle pathForResource:@"raccoon" ofType:@"png"];
  NSImage* sheet = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
  CGImageRef image = [sheet CGImageForProposedRect:NULL context:nil hints:nil];
  if (image && CGImageGetHeight(image) > 0) {
    size_t side = CGImageGetHeight(image), count = CGImageGetWidth(image) / side;
    for (size_t i = 0; i < count; i++) {
      CGImageRef frame = CGImageCreateWithImageInRect(image, CGRectMake(i * side, 0, side, side));
      if (frame) [frames addObject:CFBridgingRelease(frame)];
    }
  }
  if (!frames.count) {
    NSImage* emoji = [NSImage imageWithSize:NSMakeSize(kSize, kSize) flipped:NO
                             drawingHandler:^BOOL(NSRect rect) {
      // the emoji faces left
      NSAffineTransform* mirror = [NSAffineTransform transform];
      [mirror translateXBy:rect.size.width yBy:0];
      [mirror scaleXBy:-1 yBy:1];
      [mirror concat];
      NSDictionary* attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:kSize * 0.72] };
      NSSize size = [@"🦝" sizeWithAttributes:attributes];
      [@"🦝" drawAtPoint:NSMakePoint((rect.size.width - size.width) / 2,
                                     (rect.size.height - size.height) / 2)
          withAttributes:attributes];
      return YES;
    }];
    NSRect box = NSMakeRect(0, 0, kSize * 2, kSize * 2);   // rendered at 2x
    CGImageRef frame = [emoji CGImageForProposedRect:&box context:nil hints:nil];
    if (frame) [frames addObject:(__bridge id)frame];
  }
  self.frames = frames;
}

- (void)makeWindow {
  NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kSize + 2 * kPad, kSize + 2 * kPad)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
  window.opaque = NO;
  window.backgroundColor = NSColor.clearColor;
  window.hasShadow = NO;
  window.ignoresMouseEvents = YES;
  window.level = NSFloatingWindowLevel;
  window.releasedWhenClosed = NO;
  window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                            | NSWindowCollectionBehaviorStationary
                            | NSWindowCollectionBehaviorIgnoresCycle
                            | NSWindowCollectionBehaviorFullScreenAuxiliary;
  window.contentView.wantsLayer = YES;
  // The clip turns with the raccoon. Its lower edge is where the sprite's box
  // ends at its feet, so a sprite pushed down sinks out of sight there; above
  // the box there is headroom to leap into.
  CALayer* clip = [CALayer layer];
  clip.bounds = CGRectMake(0, 0, kSize, kSize + kHead);
  clip.anchorPoint = CGPointMake(0.5, kSize / 2 / (kSize + kHead));
  clip.position = CGPointMake(kPad + kSize / 2, kPad + kSize / 2);
  clip.masksToBounds = YES;
  [window.contentView.layer addSublayer:clip];
  CALayer* sprite = [CALayer layer];
  sprite.bounds = CGRectMake(0, 0, kSize, kSize);
  sprite.anchorPoint = CGPointMake(0.5, 0.3);   // its feet: it squashes and leans from there
  sprite.position = CGPointMake(kSize / 2, kSize * 0.3);
  sprite.contentsGravity = kCAGravityResizeAspect;
  [clip addSublayer:sprite];
  NSMutableArray* crumbs = [NSMutableArray array];
  for (int i = 0; i < kCrumbs; i++) {
    CALayer* crumb = [CALayer layer];
    crumb.bounds = CGRectMake(0, 0, 4.5, 4.5);
    crumb.cornerRadius = 1.5;
    crumb.hidden = YES;
    [window.contentView.layer addSublayer:crumb];
    [crumbs addObject:crumb];
  }
  self.clip = clip;
  self.crumbLayers = crumbs;
  CATextLayer* bang = [CATextLayer layer];
  bang.string = @"!";
  bang.font = (__bridge CFTypeRef)[NSFont boldSystemFontOfSize:24];
  bang.fontSize = 24;
  bang.foregroundColor = NSColor.systemPinkColor.CGColor;
  bang.shadowOpacity = 0.7;
  bang.shadowRadius = 1.5;
  bang.shadowOffset = CGSizeZero;
  bang.contentsScale = 2;
  bang.frame = CGRectMake(kPad + kSize - 16, kPad + kSize - 28, 14, 28);
  bang.hidden = YES;
  [window.contentView.layer addSublayer:bang];
  self.window = window;
  self.sprite = sprite;
  self.bang = bang;
}

- (void)scheduleNext {
  [self.next invalidate];
  self.next = nil;
  if (!g_raccoon_on) return;
  NSTimeInterval wait = 120 + arc4random_uniform(181);   // 2-5 minutes
  self.next = [NSTimer timerWithTimeInterval:wait target:self selector:@selector(visit)
                                    userInfo:nil repeats:NO];
  [NSRunLoop.mainRunLoop addTimer:self.next forMode:NSRunLoopCommonModes];
}

- (void)visit {
  if (_wid) return;   // already out
  uint32_t wid; CGRect bounds; float band;
  if (!knit_raccoon_target(&wid, &bounds, &band, &_yarn)) knit_raccoon_refocus();
  bool found = knit_raccoon_target(&wid, &bounds, &band, &_yarn);
  if (!found) {
    // Focus tracking can lose the thread (no Accessibility permission, a
    // Space of its own). The frontmost window on screen wearing a sweater is
    // the one being looked at.
    NSArray* onscreen = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary* info in onscreen) {
      if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
      wid = [info[(id)kCGWindowNumber] unsignedIntValue];
      if ((found = knit_raccoon_window(wid, &bounds, &band, &_yarn))) break;
    }
  }
  if (!found || CGRectIsNull(raccoon_keep_onscreen(bounds))) {
    char why[320];
    knit_raccoon_describe(why, sizeof why);
    os_log(OS_LOG_DEFAULT, "raccoon: no focused window wearing a sweater on a display; no visit. %{public}s", why);
    [self scheduleNext];
    return;
  }
  if (!self.frames) [self loadFrames];
  if (!self.frames.count) return;
  if (!self.window) [self makeWindow];

  _mode = g_raccoon_eats;
  if (_mode == RACCOON_EATS_SOMETIMES)
    _mode = arc4random_uniform(3) == 0 ? RACCOON_EATS_LAP : RACCOON_EATS_OFF;
  _reknit = _mode == RACCOON_EATS_LAP || _mode == RACCOON_EATS_NIBBLE;
  if (_mode == RACCOON_EATS_STAY && _eatenWid == wid) {
    // It ate this one last time: this lap brings the sweater back.
    _mode = RACCOON_EATS_OFF;
    _reknit = true;
  }
  _wid = wid;
  float lap = 2.f * (float)(bounds.size.width + bounds.size.height);
  _start = arc4random_uniform((uint32_t)lap);
  _dist = _bitten = 0.f;
  _nibbleAt = lap * 0.15f;
  _stopUntil = 0;
  _last = CFAbsoluteTimeGetCurrent();
  _peekUntil = self.frames.count >= kAllFrames ? _last + kPeek : 0;
  _caughtAt = 0;
  _fleeEnd = 0.f;
  memset(_crumbs, 0, sizeof _crumbs);
  self.window.alphaValue = 0;
  [self.window orderFrontRegardless];
  self.tick = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(step)
                                    userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.tick forMode:NSRunLoopCommonModes];
}

// Done with the window it was on: mend it, or remember it was left bare.
- (void)settle {
  if (_reknit) knit_raccoon_reknit(_wid);
  if (_mode == RACCOON_EATS_STAY) _eatenWid = _wid;
  else if (_eatenWid == _wid) _eatenWid = 0;
}

// Every visit ends here, and says why in the log.
- (void)leave:(const char*)why {
  os_log(OS_LOG_DEFAULT, "raccoon: left after %{public}.0f points: %{public}s", _dist, why);
  [self.tick invalidate];
  self.tick = nil;
  [self.window orderOut:nil];
  [self settle];
  _wid = 0;
  [self scheduleNext];
}

// Bits of yarn fly off toward (ux, uy) and then fall down the screen.
- (void)crumbs:(int)count at:(CGPoint)at towardX:(CGFloat)ux y:(CGFloat)uy speed:(CGFloat)speed {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  for (int i = 0; i < count; i++) {
    CGFloat out = speed * (0.6 + arc4random_uniform(80) / 100.0);
    CGFloat along = speed * (arc4random_uniform(200) / 100.0 - 1.0) * 0.8;
    _crumbs[_nextCrumb] = (struct crumb){ at.x, at.y, ux * out - uy * along, uy * out + ux * along, now };
    _nextCrumb = (_nextCrumb + 1) % kCrumbs;
  }
}

- (void)shoo {
  if (_wid) [self leave:"shooed away"];
}

- (void)step {
  uint32_t wid; CGRect bounds; float band;
  // Focus moved to another sweater: follow it or leave. Otherwise stay with
  // this window for as long as its sweater shows, whatever focus tracking says.
  bool elsewhere = knit_raccoon_target(&wid, &bounds, &band, &_yarn) && wid != _wid;
  if (!elsewhere && !knit_raccoon_window(_wid, &bounds, &band, &_yarn)) {
    [self leave:"its window closed or its sweater is hidden"];
    return;
  }
  if (elsewhere) {
    if (!g_raccoon_follow) { [self leave:"focus moved to another window"]; return; }
    // Start a lap of the newly focused window from where it stands. The old
    // window's distance means nothing on a perimeter of a different length.
    [self settle];
    _wid = wid;
    _start += _dist;
    _dist = _bitten = 0.f;
    _nibbleAt = 150.f;
    _stopUntil = 0;
  }

  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  // Before the lap it peeks over the edge. If the pointer comes near once it
  // is out, it freezes and stares, then bolts and is gone.
  bool peeking = now < _peekUntil;
  if (!_caughtAt && !peeking && self.window.alphaValue > 0.9) {
    NSPoint pointer = NSEvent.mouseLocation;
    NSRect here = self.window.frame;
    if (hypot(pointer.x - NSMidX(here), pointer.y - NSMidY(here)) < kNotice) {
      _caughtAt = now;
      _stopUntil = 0;
    }
  }
  bool startled = _caughtAt && now < _caughtAt + kStartle;
  bool fleeing = _caughtAt && !startled;
  if (fleeing && _fleeEnd == 0.f) _fleeEnd = _dist + kFlee;
  bool pausing = now < _stopUntil;                    // munching or wiggling
  bool stopped = peeking || startled || pausing;
  CGFloat dt = fmin(now - _last, 0.1);
  if (!stopped) _dist += kSpeed * (fleeing ? 3.f : 1.f) * (float)dt;
  _last = now;

  CGRect band_middle = CGRectInset(bounds, -band * 0.5f, -band * 0.5f);
  CGRect track = raccoon_keep_onscreen(band_middle);
  if (CGRectIsNull(track)) { [self leave:"its window is on no display"]; return; }
  float lap = 2.f * (float)(track.size.width + track.size.height);
  float end = _fleeEnd > 0.f ? fminf(_fleeEnd, lap) : lap;
  if (_dist >= end) { [self leave:_fleeEnd > 0.f ? "the pointer startled it" : "lap finished"]; return; }

  int side;
  CGPoint p = raccoon_point(track, _start + _dist, &side);
  float bite = band * 0.5f + 3.f;   // covers the band and its soft edge
  CGPoint mouth = raccoon_onto_band(track, band_middle, p);
  if (_mode == RACCOON_EATS_LAP || _mode == RACCOON_EATS_STAY) {
    // Overlapping bites all the way from the last one: a late frame must not
    // leave a tuft of sweater behind.
    // A lap pulled in from the screen edge is shorter than the band it maps
    // onto, so its steps are stretched there: step that much finer.
    float stretch = (float)fmax(band_middle.size.width / fmax(track.size.width, 1),
                                band_middle.size.height / fmax(track.size.height, 1));
    int at;
    for (; _bitten < _dist; _bitten += bite * 0.5f / stretch)
      knit_raccoon_bite(_wid, raccoon_onto_band(track, band_middle,
                            raccoon_point(track, _start + _bitten, &at)), bite);
    knit_raccoon_bite(_wid, mouth, bite);
  }
  // Every so often it stops: to munch if it is eating, or to wiggle its tail.
  if (!stopped && !_caughtAt && _dist >= _nibbleAt) {
    _stopLength = _mode == RACCOON_EATS_NIBBLE ? kNibble : kStop;
    _stopUntil = now + _stopLength;
    _nibbles = 0;
    _burst = false;
    _nibbleAt = _dist + lap * (0.15f + arc4random_uniform(20) / 100.f);
    stopped = pausing = true;
  }

  // Feet toward the window on every side, with a hop away from it. Where the
  // lap was pulled in from the screen edge it runs along the inside instead,
  // feet toward that edge.
  static const CGFloat normal[4][2] = { {0, -1}, {1, 0}, {0, 1}, {-1, 0} };
  const CGFloat pulled[4] = { CGRectGetMinY(track) - CGRectGetMinY(band_middle),
                              CGRectGetMaxX(band_middle) - CGRectGetMaxX(track),
                              CGRectGetMaxY(band_middle) - CGRectGetMaxY(track),
                              CGRectGetMinX(track) - CGRectGetMinX(band_middle) };
  CGFloat inside = pulled[side] > 0.5 ? -1 : 1;

  // Seven beats a second while stopped. The munch and wiggle loops step on
  // them, and a nibbling raccoon takes one small bite every other beat: a row
  // along the top of the band, then the row beneath, then the last one, so it
  // digs down through the band.
  int beat = pausing ? (int)((_stopLength - (_stopUntil - now)) * 7) : 0;
  if (pausing && _mode == RACCOON_EATS_NIBBLE) {
    static const float nibble[][2] = {   // { along the band, across it }
      { 0, 1 }, { -1, 1 }, { 1, 1 }, { 0, 0 }, { -1, 0 }, { 1, 0 }, { 0, -1 }, { -1, -1 }, { 1, -1 },
    };
    float scallop = band * 0.3f + 1.f;
    for (; _nibbles <= beat / 2 && _nibbles < (int)(sizeof nibble / sizeof nibble[0]); _nibbles++) {
      CGFloat along = nibble[_nibbles][0] * scallop * 1.4;
      CGFloat across = nibble[_nibbles][1] * band * 0.33 * inside;
      CGPoint at = CGPointMake(mouth.x - normal[side][1] * along + normal[side][0] * across,
                               mouth.y + normal[side][0] * along + normal[side][1] * across);
      knit_raccoon_bite(_wid, at, scallop);
      [self crumbs:3 at:at towardX:normal[side][0] * inside y:normal[side][1] * inside speed:95];
    }
  }
  // One bound per run cycle: it is in the air for the leaping frames.
  NSUInteger count = self.frames.count, run = count >= kAllFrames ? kRunFrames : count;
  float bound = count > 1 ? 80.f : 28.f;
  float cycle = fmodf(_dist, bound) / bound;
  CGFloat stride = M_PI * _dist / bound, air = stopped ? 0 : fabs(sin(stride));
  CGFloat hop = air * 6 * inside;
  // Munching, it sits back off the band so the hole it is making shows at its feet.
  if (pausing && _mode != RACCOON_EATS_OFF) hop = kSize * 0.3 * inside;
  if (startled) hop = sin(fmin(1, (now - _caughtAt) / 0.15) * M_PI) * 9 * inside;   // a jump of fright
  CGFloat x = p.x + normal[side][0] * hop, y = p.y + normal[side][1] * hop;
  // Digging, its box rests with one edge on the far side of the band and it
  // sinks past that edge bite by bite, so it disappears into the hole it eats.
  CGFloat sink = 0, wide = 1, tall = 1, tilt = 0;
  bool looking = false, grin = false;
  if (peeking || (pausing && _mode == RACCOON_EATS_NIBBLE)) {
    CGFloat out = (kSize - band) / 2 * inside;
    x = mouth.x + normal[side][0] * out;
    y = mouth.y + normal[side][1] * out;
  }
  if (pausing && _mode == RACCOON_EATS_NIBBLE) {
    // Then the cartoon: its ears quiver at the rim, it bursts out stretched
    // tall in a spray of yarn, hangs, lands in a squash, and shakes itself off.
    CGFloat t = _stopLength - (_stopUntil - now), rim = kSize * 0.76, peak = -kSize * 0.3;
    CGFloat u = t - kDig;
    grin = u >= 0;
    if (u < 0)          sink = fmin(1, t / (kDig - 0.2)) * kSize * 0.95;
    else if (u < 0.50)  sink = rim + sin(now * 60) * 1.6;
    else if (u < 0.66) {
      CGFloat k = (u - 0.50) / 0.16;
      sink = rim + (peak - rim) * (1 - (1 - k) * (1 - k));
      tall = 1.3; wide = 0.8;
      if (!_burst) {
        _burst = true;
        [self crumbs:12 at:mouth towardX:normal[side][0] * inside y:normal[side][1] * inside speed:170];
      }
    }
    else if (u < 0.82) { sink = peak; tall = 1.3 - 0.3 * (u - 0.66) / 0.16; wide = 0.8 + 0.2 * (u - 0.66) / 0.16; }
    else if (u < 0.96) { CGFloat k = (u - 0.82) / 0.14; sink = peak * (1 - k * k); }
    else if (u < 1.14) { CGFloat k = (u - 0.96) / 0.18; tall = 0.74 + 0.26 * k; wide = 1.22 - 0.22 * k; }
    else               tilt = sin((u - 1.14) * 40) * 0.14 * fmax(0, 1 - (u - 1.14) / 0.36);
  }
  if (peeking) {
    // Ears first, then eyes, a look each way, and up it hops.
    CGFloat t = kPeek - (_peekUntil - now);
    CGFloat ears = kSize * 0.72, eyes = kSize * 0.52, rise;
    if (t < 0.4)      rise = kSize * 0.95 + (ears - kSize * 0.95) * (t / 0.4);
    else if (t < 1.0) rise = ears;
    else if (t < 1.3) rise = ears + (eyes - ears) * ((t - 1.0) / 0.3);
    else if (t < 1.9) rise = eyes;
    else              rise = eyes * (1 - (t - 1.9) / 0.3);
    sink = fmax(0, rise);
    looking = t > 1.45 && t < 1.7;
  }
  // WindowServer's y grows downward from the top of the primary display.
  CGFloat top = NSScreen.screens.firstObject.frame.size.height;
  CGFloat half = kSize / 2 + kPad;
  [self.window setFrameOrigin:NSMakePoint(x - half, top - y - half)];
  // It peeks in, so only a visit without a peek has to fade in.
  self.window.alphaValue = fmin(1, fmin(_peekUntil ? kFade : _dist, end - _dist) / kFade);
  self.bang.hidden = !startled;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  NSUInteger frame = (NSUInteger)(cycle * run) % run;
  if ((peeking || grin) && count >= kAllFrames) frame = kMunchFrame + 4;   // looking straight at you
  else if (startled && count >= kAllFrames) frame = kWiggleFrame;
  else if (pausing && count >= kAllFrames) {
    static const int wag[4] = { 0, 1, 2, 1 };
    frame = _mode == RACCOON_EATS_OFF ? kWiggleFrame + wag[beat & 3]
                                      : kMunchFrame + beat % kMunchFrames;
  }
  self.sprite.contents = self.frames[frame];
  if (looking) wide = -1;
  else if (stopped && count < kAllFrames) {
    wide = 1 + 0.08 * sin(now * 28);
    tall = 2 - wide;
  } else if (count == 1) {
    // A single picture has no run cycle, so gallop it: nose up on the way up,
    // down on the way down, squashed where it lands and stretched in the air.
    tilt = 0.24 * cos(stride) * (sin(stride) < 0 ? -1 : 1);
    wide = 1.10 - 0.14 * air;
    tall = 0.88 + 0.18 * air;
  }
  self.clip.affineTransform = CGAffineTransformScale(
      CGAffineTransformMakeRotation(-side * M_PI_2), 1, inside);
  self.sprite.affineTransform = CGAffineTransformTranslate(CGAffineTransformRotate(
      CGAffineTransformMakeScale(wide, tall), tilt), 0, -sink);

  // Crumbs live in screen coordinates, so they fall where they were knocked
  // loose even when the raccoon moves on.
  CGColorRef wool = CGColorCreateSRGB(((_yarn >> 16) & 255) / 255.0, ((_yarn >> 8) & 255) / 255.0,
                                      (_yarn & 255) / 255.0, 1);
  for (int i = 0; i < kCrumbs; i++) {
    struct crumb* crumb = &_crumbs[i];
    CALayer* layer = self.crumbLayers[i];
    CGFloat age = now - crumb->born;
    layer.hidden = crumb->born == 0 || age > kCrumbLife;
    if (layer.hidden) continue;
    crumb->vy += 520 * dt;
    crumb->x += crumb->vx * dt;
    crumb->y += crumb->vy * dt;
    layer.position = CGPointMake(half + crumb->x - x, half - (crumb->y - y));
    layer.opacity = 1 - age / kCrumbLife;
    layer.backgroundColor = i % 2 ? wool : [NSColor colorWithSRGBRed:0.96 green:0.94 blue:0.87 alpha:1].CGColor;
  }
  CGColorRelease(wool);
  [CATransaction commit];
}
@end

static KnitRaccoon* raccoon(void) {
  static KnitRaccoon* instance;
  if (!instance) instance = [[KnitRaccoon alloc] init];
  return instance;
}

void raccoon_set_on(bool on) {
  g_raccoon_on = on;
  [raccoon() scheduleNext];
}

void raccoon_why(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    char why[320];
    knit_raccoon_describe(why, sizeof why);
    os_log(OS_LOG_DEFAULT, "raccoon: %{public}s", why);
  });
}

void raccoon_shoo(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ [raccoon() shoo]; });
}

void raccoon_summon(void) {
  // The sender may be mid-way through applying a batch of settings.
  dispatch_async(dispatch_get_main_queue(), ^{ [raccoon() visit]; });
}
