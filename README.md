# LidFold

Close a MacBook lid and the screen content blurs inward from both edges; open it and the
blur retreats. The progress is **bound directly to the real hinge angle** — stop halfway
and it stops, reverse and it rewinds. No canned timeline.

macOS only, and only on MacBooks that have a lid-angle sensor.

---

## Requirements

- **macOS 14 or later**
- **A MacBook with the lid-angle sensor.** Only the 2019 16" MacBook Pro and later have it.
  Check with `hidutil list | grep -i 8104` — if anything comes back, you have it.
  (Verified on a MacBook Air M4 / Mac16,12 / macOS 27.0.1.)
- Not portable to Windows or Linux laptops: a normal laptop only has a magnetic open/closed
  switch, with no angle to read.

This is a personal tool. It is **not notarized and not distributed** — build it yourself.

## Install

```sh
git clone https://github.com/e93xk7/lidfold.git
cd lidfold

scripts/make_cert.sh      # one-time: create a local self-signed signing certificate
scripts/build_app.sh      # builds build/LidFold.app
open build/LidFold.app
```

On first launch macOS will ask for **Screen Recording** permission — the animation needs a
snapshot of what is currently on screen. Grant it, then relaunch the app. It then lives in
the menu bar and triggers on its own whenever you close the lid.

`make_cert.sh` is not optional busywork: macOS ties TCC permissions to the code signature,
and an ad-hoc signature changes on every build, so the permission would be revoked each
time you rebuild. A stable self-signed certificate keeps it.

## How it works

```
HID sensor @10 Hz  →  smoothing + angular velocity  →  state machine  →  θ → p ∈ [0,1]  →  overlay window
                                                       closing/opening/closed              snapshot + gradient masks
```

- **Sensor** — `IOHIDDeviceRegisterInputReportCallback`; the sensor pushes, we never poll.
- **Signal** — one-pole low-pass, two-point difference for angular velocity, plus a spike guard.
- **Mapping** — `p = (θ_open − θ) / (θ_open − θ_off)`, where `θ_open` is the resting angle
  from just before this close began.
- **Render** — a borderless window covering the screen, holding three copies of the same
  snapshot (sharp, blurred 10px, blurred 28px). Each has a `CAGradientLayer` mask, and the
  masks' leading edges are staggered. `p` drives the masks, producing a continuous
  sharp → half-blurred → fully-blurred gradient that sweeps in from both sides.

## What I learned building this

All measured on real hardware. Written down for whoever pokes at this sensor next.

**The sensor only runs at 10 Hz.** One update every 100 ms. Polling at 130 Hz gives you
nothing extra, and registering an input-report callback delivers at exactly the same rate —
it is a hardware limit. A normal lid close takes 1.6 s, so the entire animation is driven by
about 16 samples; a fast close (0.76 s) gives you 8, each jumping 16–19°. Rendering at
60 fps means interpolating the gaps yourself.

**Interpolate by extrapolation, not by damped following.** The first version had the output
chase a target with critical damping. Smooth, but it lagged 8.5° mid-motion — a critically
damped follower has an inherent 2τ steady-state error against a ramp input. Switching to
"constant-velocity extrapolation plus exponential decay of the error" dropped the median
error to 0.24–2.5°.

**There are two angle reports.** Every reference implementation reads report 1 (9-bit, 1°
resolution). But the HID report descriptor also exposes **report 7**: 32-bit, logical max
36000, unit exponent 10⁻² — the same angle at **0.01° resolution**, with only 0.05°
peak-to-peak noise at rest. Both come from the same sensor and update at the same rate.

**The screen turns off much later than you would guess.** The magnetic switch fires at
**0–6°** (median 2°), not the commonly cited 10–20°. That leaves an animation window of
over 110°, far more room than expected.

**The screen is already on while you open the lid.** The original assumption was that
opening isn't worth animating because the panel is still asleep. Measured: the panel lights
up **45 ms** after opening is detected, with the lid at just 9.4° — essentially the whole
opening motion is visible. But **do not take a fresh snapshot when opening begins**: at that
instant the capture comes back pure black. Reuse the one taken when the lid closed.

**Pinning content in space does not work on a single flat screen.** The first approach was a
perspective projection that made the content appear fixed in mid-air while the machine
rotated around it. The geometry was exactly right (self-check drift: 0.00000 cm), but as the
lid closes, the screen sees a progressively smaller slice of that virtual plane, so the image
necessarily magnifies — nearly 3× at 70° of closure. It doesn't read as "the content stayed
still", it reads as "the screen got stretched". That path is still there under
`--mode projection` for comparison.

**Idle power is entirely about whether you poll.** Polling at 120 Hz to chase a 10 Hz sensor
burned 1.0% CPU while doing nothing. Switching to push, and only reading the fine-resolution
report when the coarse value actually changed (so: zero IPC while stationary), brought it to
**0.2%**.

## Options

```sh
build/LidFold.app/Contents/MacOS/LidFold --demo       # sweep through the animation without touching the lid
                                         --debug      # overlay θ and p on screen
                                         --from sides|hinge|top   # where the blur sweeps in from
                                         --mode gradient|projection
```

Every tunable lives in [`Sources/LidFoldCore/Tuning.swift`](Sources/LidFoldCore/Tuning.swift),
each annotated with the measurement that set it.

## Development

```sh
swift build
.build/debug/lidfold-cli                      # live θ / ω / state / p
scripts/record.sh my_take                     # record one lid close to CSV
.build/debug/lidfold-replay data/takes/*.csv  # replay recorded closes through the state machine
.build/debug/lidfold-replay --sweep           # self-check the mask math
.build/debug/lidfold-replay --geometry        # self-check the perspective projection
```

`data/takes/` holds real recorded closes — slow, fast, normal, and one that stops halfway and
resumes. `lidfold-replay` uses them as regression tests: change the state machine, run it
once, and you know whether you broke anything.

The plotting scripts need `python3 -m venv .venv && .venv/bin/pip install matplotlib numpy`.

**Kill the running app before rebuilding** (`build_app.sh` does this for you). Replacing the
contents of a `.app` while its process is alive makes macOS decide the code identity changed
and revoke Screen Recording on the spot (`SCStreamError -3801`).

Source comments and commit messages are in Chinese.

## Known limitations

- The overlay works on a normal desktop. Full-screen apps and other Spaces are untested.
- Pausing mid-close for more than 2.5 s tears the overlay down; resuming takes a fresh snapshot.
- The first ~100 ms of motion is undetectable — a hard limit of the 10 Hz sensor. On a fast
  close that is about 13% of the animation.

## Credits

How to read this sensor was learned from:

- [`samhenrigold/LidAngleSensor`](https://github.com/samhenrigold/LidAngleSensor) (Swift/ObjC)
- [`wangfu91/lid-angle-rs`](https://github.com/wangfu91/lid-angle-rs) (Rust — clearest writeup of the VID/PID/usage)
- [`tcsenpai/pybooklid`](https://github.com/tcsenpai/pybooklid) (Python — the shortest implementation)

The animation is inspired by the iPhone Duo's fold transition.
