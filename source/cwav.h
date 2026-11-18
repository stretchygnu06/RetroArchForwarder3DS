#pragma once
#include <stddef.h>
#include <stdint.h>

// The sound a banner plays when its icon is selected on the HOME menu.
//
// Banners carry it as a CWAV. This turns a plain WAV (PCM, 8 or 16 bit, mono
// or stereo) into a PCM16 CWAV laid out the way bannertool writes them, and
// swaps it into a banner. Free of 3DS dependencies, tested on a PC.

// The HOME menu stops banner sounds after about three seconds.
#define CWAV_MAX_SECONDS 3.0

// Builds the CWAV in a malloc'd buffer. Returns its size, or 0 with *err set.
size_t cwavFromWav(const uint8_t* wav, size_t len, uint8_t** out, const char** err);

// Writes into out the banner with its sound replaced, artwork untouched.
// Returns the new size, or 0 when it does not fit or bnr is not a banner.
size_t bannerSetSound(const uint8_t* bnr, size_t bnr_len,
                      const uint8_t* cwav, size_t cwav_len,
                      uint8_t* out, size_t out_cap);
