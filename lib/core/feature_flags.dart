// Compile-time switches for features that are fully built but temporarily
// hidden. Flip a flag to true to turn that feature back on. No database
// change is needed.

// Beep Your Coach — the Help, Spot and Done buttons a client sees during a
// live session, the coach's alert overlay and sounds, beep push handling,
// and the Customize Platform "alert sounds" section.
//
// The feature is pinned off for 1.1.6 so it can come back later. All of
// the code, providers, models and migrations stay in the tree. Set this
// to `true` to switch it back on.
const bool kBeepYourCoachEnabled = false;
