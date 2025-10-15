# Stepcompress: bug, fixes applied, and proposed follow-ups

Date: 2025-10-16

This document explains a recurring "Internal error in stepcompress" / "Invalid sequence" issue, the edits made to mitigate it, how to rebuild and validate the changes, and recommended next steps.

## Problem summary

Symptoms observed in logs:

- Repeated messages like:
  - `stepcompress o=6 i=-9323 c=2 a=31438: Invalid sequence`
  - `Error in syncemitter 'stepper_x' step generation`
  - And the service entering shutdown: `Exception in flush_handler`.

- Diagnostic output (after instrumentation) showed:
  - `last_step_clock` was a large 64-bit value (e.g. 193533319433)
  - The queued step timestamps stored in `sc->queue` are 32-bit values (e.g. 259683029)

Root cause (diagnosed):

- The compressor mixed 32-bit queue entries with a 64-bit `last_step_clock` when computing offsets.
- Unsigned 32-bit subtraction against a large 64-bit `last_step_clock` led to wrap/incorrect offsets. That allowed the compress algorithm to propose invalid (negative or overflowed) `interval` values and triggered check_line() errors.

## Changes applied (low-risk, defensive)

All edits are to `klippy/chelper/stepcompress.c`.

1. Added diagnostic context to `check_line()` (prints `last_step_clock`, `queue_pos`, `queue_next`, and up to 8 queued timestamps near `queue_pos`) to help reproduce and debug compression failures.

2. Fixed accidental stray characters that caused a compilation error during prior edits.

3. Rewrote `minmax_point()` to be robust with 32-bit stored queue entries and 64-bit `last_step_clock`:
   - Reconstructs a 64-bit absolute clock for each queued 32-bit entry by aligning it to the high 32-bit window of `last_step_clock` and correcting for wrap.
   - Computes signed 64-bit offsets (point, prevpoint) relative to `last_step_clock`.
   - If a queued entry reconstructs to an absolute time before `last_step_clock`, clamps `point` and `prevpoint` to zero to avoid negative-interval moves.
   - Clamps min/max results to int32 range before returning.
   - Added `#include <limits.h>` to support INT32_MIN/INT32_MAX.

4. Added a small diagnostic log line inside `minmax_point()` when clamping happens:
   - Logs `stepcompress o=<oid>: clamping queued pos <qval> (recon=<pos64>) < last_step_clock=<lsc>` to indicate when queued entries are in the past.

5. Fallback in `queue_flush()` when `compress_bisect_add()` + `check_line()` fails:
   - Instead of returning an error that propagates to Python, the code now falls back to a safe single-step move (interval = `pt.maxp`, count=1, add=0) for the first queued entry and logs the fallback.
   - Logs `stepcompress o=<oid>: compress_bisect_add failed, falling back to single-step (queue_pos=<idx>)`.

These changes are intentionally conservative: they aim to keep the printer running and produce useful diagnostics while avoiding crashes.

## Why these changes help

- The primary bug came from mixing 32-bit queue entries with 64-bit `last_step_clock`. Reconstructing a 64-bit queued time prevents wrap-misinterpretation and yields correct signed offsets.
- Clamping prevents negative intervals when the queue contains times in the past relative to the `last_step_clock` (likely transient due to scheduling or clock sync lag).
- The fallback ensures the compressor doesn't abort with ERROR_RET; instead it emits a safe single-step command and continues processing.

## How to rebuild and test (typical Raspberry Pi / Linux host)

1. Rebuild klippy so the C code recompiles:

```bash
cd /home/printer/klipper
make
sudo service klipper restart
# or use your project's restart method for klippy
```

2. Reproduce the failure case (run the motion or job that previously triggered the error).

3. Tail logs and watch for messages:

```bash
# follow klippy log if it writes to /tmp/klippy.log
tail -F /tmp/klippy.log | sed -n '/stepcompress o=/,/-/p'
# or follow systemd journal for the klipper service
journalctl -u klipper -f
```

Look for these lines (examples):

- Clamping:
  - `stepcompress o=6: clamping queued pos 2402331470 (recon=470553766734) < last_step_clock=470553787277`

- Fallback:
  - `stepcompress o=6: compress_bisect_add failed, falling back to single-step (queue_pos=1032)`

- Previously-seen Invalid sequence (should be rare or absent after the fix):
  - `stepcompress o=6 i=-108084 c=1 a=0: Invalid sequence`

## How to interpret the diagnostics

- `last_step_clock` is a 64-bit MCU clock value used for absolute timing.
- `sc->queue` entries are stored as 32-bit MCU-clock snapshots; they must be aligned to the 64-bit window for meaningful subtraction.
- If the reconstructed pos64 < last_step_clock, the code clamps it to zero and logs that event. That indicates the compressor is catching up on steps that are effectively in the past.

Conversion formulas:
- ticks -> seconds: seconds = ticks / mcu_freq
- seconds -> ticks: ticks = seconds * mcu_freq

## Proposed follow-ups (recommended)

These are higher-confidence, slightly larger changes that can make the compressor more robust and reduce the need for fallbacks:

- Use 64-bit signed intermediates more broadly inside `compress_bisect_add()` to avoid risk of 32-bit overflow when computing `c = add * factor` and other expressions. Many intermediate variables are currently `int32_t`.
- Modify the fallback to emit a `queue_step` that uses the absolute queued clock as `first_clock` (i.e., call `add_move()` with `first_clock` based on the reconstructed `pos64`). This improves fidelity compared to using `pt.maxp` as the interval.
- Rate-limited logging: if clamping/fallback are frequent, add a counter and only log every Nth event (or expose a debug flag to enable full logs).
- Add a unit-test harness that feeds `compress_bisect_add()` known queue arrays (including boundary/wrap cases) and verifies valid moves are emitted or safe fallbacks are used.
- Optionally add a short startup-time log in `klippy/stepper.py` to print `self._name` and `self._oid` so you can map `oid` numbers to stepper sections in the config quickly.

## Files changed (summary)

- `klippy/chelper/stepcompress.c`
  - Main fixes and diagnostics described above.

If you need a patch file or git diff to review the exact edits, I can produce it.

## If you hit more errors

Collect and paste the following blocks (copy the entire block) and open an issue or paste it here:

1. The full `Invalid sequence` block(s) including the `check_line()` context (queue indices and q[...] values).
2. Any clamping or fallback lines (they help identify how often the fallback is triggered).
3. The exact steps you took when reproducing (command, gcode, or motion sequence), and whether the system was under heavy load.

With that I can propose a targeted permanent fix (for example, the 64-bit intermediate change in `compress_bisect_add()` and a better deterministic fallback).

---

If you want, I can now:

- Produce a patch that implements the proposed stronger fixes (64-bit intermediates + fallback using absolute clock).
- Add frequency-limited logging.
- Add a small unit test harness for the compressor.

Tell me which follow-up you'd like and I'll implement it.