#ifndef PCFE_BODY_KIND_H
#define PCFE_BODY_KIND_H

/* Shared by the CPU draw list and shaders/World.metal.
   The fragment shader switches on these integers. Keep the two in step. */

#define BODY_SKY 0
#define BODY_PLANET 1
#define BODY_MOON 2
#define BODY_METAL 3
#define BODY_PANEL 4
#define BODY_DISH 5
#define BODY_BEACON 6
#define BODY_BEACON_HALO 7
#define BODY_ATMOSPHERE 8
#define BODY_ORBIT_MOON 9
#define BODY_ORBIT_SAT 10
#define BODY_HORN 11

#endif
