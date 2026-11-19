// lib/core/build_flags.dart
//
// Compile-time switches for the redesign's reserved slots. Each one guards a
// feature the boards show but the app does not have yet (or that waits for
// an owner decision). A slot whose flag is false is left out of the widget
// tree; nothing is drawn in its place. All flags stay false until the
// feature behind them is built and approved.
//
// The landscape recording flag (kLandscapeRecording) belongs to the
// landscape engine branch and is deliberately not defined here.

/// The yellow "NOT WRITING" state band for a stalled recording.
const bool kShowStalled = false;

/// "Writing, last 0.4 s ago" under the REC band.
const bool kShowWriteAge = false;

/// The 8 s Undo button after LOCK (needs an unlock API mid-ride).
const bool kLockUndo = false;

/// A tone played when LOCK is pressed.
const bool kLockTone = false;

/// The orientation chip ("Taken at START") on the recording screen.
const bool kOrientationChip = false;

/// A LOCK action on the recording notification (Kotlin has a matching
/// BuildConfig boolean).
const bool kNotificationLock = false;

/// A trip report after STOP.
const bool kTripReport = false;

/// "Check a received export" on the Rides screen.
const bool kCheckReceivedExport = false;

/// The Controls row in Settings (buttons and key learning).
const bool kControlsRow = false;

/// The Backup row in Settings.
const bool kBackupRow = false;

/// "Keep" on the recovery card of an incomplete ride.
const bool kRideKeep = false;

/// "Recover last clip" on the recovery card of an incomplete ride.
const bool kRecoverLastClip = false;

/// "Open folder" after an export finishes.
const bool kOpenExportFolder = false;

/// Unlock from the Playback screen (it stays in the Rides list menu).
const bool kPlaybackUnlock = false;

/// Resolution chips on the recording screen.
const bool kResolutionChips = false;

/// Press-and-hold (1 s) to STOP; waits for the owner's decision.
const bool kHoldToStop = false;
