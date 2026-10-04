#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

// A little raccoon that runs a lap around the focused window every few
// minutes and, depending on its appetite, eats the sweater as it goes.
//
// It lives in its own small click-through window (src/raccoon.m): the sweater's
// window is only a band wide, and would clip it. Eating clears stitches in
// the sweater's existing surface, so any ordinary redraw knits them back.

enum raccoon_eats {
  RACCOON_EATS_OFF = 0,    // just runs by
  RACCOON_EATS_LAP,        // eats the whole lap; re-knit when it leaves
  RACCOON_EATS_NIBBLE,     // stops for a few bites; re-knit when it leaves
  RACCOON_EATS_STAY,       // eats the lap and leaves it bare; the next visit
                           // to that window knits it back
  RACCOON_EATS_SOMETIMES,  // one visit in three eats a lap
  RACCOON_EATS_COUNT
};

extern bool g_raccoon_on;        // visits every few minutes
extern int g_raccoon_eats;       // enum raccoon_eats
extern bool g_raccoon_follow;    // mid-lap, hop to whichever window takes focus
extern const char* g_raccoon_eats_names[];

void raccoon_set_on(bool on);
void raccoon_summon(void);       // one visit now, whether or not visits are on
void raccoon_shoo(void);         // end the visit under way, mending as it would have

// Provided by main.c. The raccoon holds a window id, never a border pointer:
// the window may close mid-lap.
// `yarn` is the sweater's base colour (ARGB), for the crumbs.
bool knit_raccoon_target(uint32_t* wid, CGRect* bounds, float* band, uint32_t* yarn);
void knit_raccoon_refocus(void);   // re-read which window is frontmost
void knit_raccoon_bite(uint32_t wid, CGPoint centre, float radius);
void knit_raccoon_reknit(uint32_t wid);

// The point `dist` along the rect's edge, clockwise on screen from its
// top-left corner (y grows downward). `side` is 0 top, 1 right, 2 bottom,
// 3 left.
// ponytail: corners are square; the raccoon cuts across a rounded window's
// arc. Follow the radius if that ever shows.
static inline CGPoint raccoon_point(CGRect r, float dist, int* side) {
  float w = r.size.width, h = r.size.height;
  dist = fmodf(dist, 2.f * (w + h));
  if (dist < 0.f) dist += 2.f * (w + h);
  if (dist < w) { *side = 0; return (CGPoint){ r.origin.x + dist, r.origin.y }; }
  dist -= w;
  if (dist < h) { *side = 1; return (CGPoint){ r.origin.x + w, r.origin.y + dist }; }
  dist -= h;
  if (dist < w) { *side = 2; return (CGPoint){ r.origin.x + w - dist, r.origin.y + h }; }
  dist -= w;
  *side = 3;
  return (CGPoint){ r.origin.x, r.origin.y + h - dist };
}
