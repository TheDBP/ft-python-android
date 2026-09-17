# Use cases - ideas to run with

This repo makes one specific thing possible: a **genuinely parallel** scientific Python
stack (numpy, scipy, a real BLAS) running **on a cheap Android phone, offline**, with the
GIL disabled so numpy/scipy workloads scale across the phone's cores.

That combination - not any one part of it - is what opens doors:

> **cheap + everywhere + battery-powered + covered in sensors + works offline + now
> actually multi-core in Python.**

The free-threading is the hinge. Before it, a phone running numpy was stuck on one core for
the Python orchestration around the math, so real-time or multi-channel work either
serialised or forced a rewrite into C/NDK/Java. Free-threaded turns "prototype it in Python
on-device" from a dead end into a starting point - `pip install` instead of a cross-compile.

This page is a **prompt list, not a roadmap or a set of endorsements.** Some of these are
weekend projects; some are research programmes; a few (medicine especially) are serious
validation-and-regulation stories where the compute is the easy part. Read the
[Honest limits](#honest-limits) section before you get excited, then go build something.

---

## Where it bites hardest

### 1. Dense sensor networks - because cheap-and-many is the point

A single expensive instrument is one data point. A thousand cheap phones is a *network*, and
each node doing its own DSP means you ship detections, not raw firehoses.

- **Seismology / earthquake early warning.** Phones already carry accelerometers, and
  crowd-sourced seismic networks exist. On-device STA/LTA triggering, spectral picking and
  P-wave discrimination let each node decide for itself. Cost is the enabler - you want
  density, not precision, and you want it in places that can't afford a seismometer.
- **Structural & machinery health monitoring.** Modal analysis of bridges, buildings and
  rotating machinery; bearing-fault envelope spectra; motor-current signature analysis.
  Multi-channel FFT across cores is the exact free-threading win. Strong predictive-
  maintenance and civil-infrastructure story.
- **Bioacoustic & environmental monitoring.** Birds, bats, whales, insects, gunshot
  detection, chainsaw/poaching alerts. Spectrograms + matched filtering + a small on-device
  classifier, in places with no connectivity where streaming raw audio is impossible.
  (This is the DSP the project was born from, pointed at a new signal.)

### 2. Offline field science - because there is no cloud out there

When the work happens where there is no network - a disaster zone, a rainforest, a clinic
with no lab - "send it to a server" isn't an option. On-device *is* the architecture.

- **Disaster & humanitarian response.** Post-quake structural triage, acoustic search-and-
  rescue, field seismology when the grid is down. The offline + portable + cheap trifecta
  is the entire value proposition.
- **Global-health point-of-care.** PPG/ECG from a phone camera or a low-cost sensor (heart
  rate, HRV, arrhythmia screening); low-cost ultrasound beamforming and reconstruction;
  colorimetric assay readout from the camera. Real linear algebra and filtering, run where
  there is no lab and no bandwidth. **Screening and monitoring, not diagnosis** - see the
  limits section.
- **Citizen astronomy.** Image stacking, plate-solving, photometry, occultation timing -
  and pair a phone with a cheap RTL-SDR dongle for **radio astronomy**, where wideband FFT
  is embarrassingly parallel. Not research-grade; citizen-science-grade at scale.

### 3. Privacy-preserving on-device - because the data can't leave

If the signal is sensitive, the cleanest privacy story is that it never travels. On-device
compute makes that the default rather than a promise.

- **Medical & biosignals generally.** Keeping the waveform on the phone turns a hard
  data-governance problem (HIPAA/GDPR) into a much simpler one.
- **Assistive technology.** Real-time hearing augmentation, speech processing, sensory
  substitution - where latency *and* privacy both forbid a round trip to a server.
- **Sports science & biomechanics.** IMU-based gait and motion analysis with real-time
  feedback; a phone as the coach's instrument.

### 4. The "easy parallel CPU" niche - because rewriting in C++ is the wall

Some workloads are just FFTs and linear algebra that want more cores. On a phone, the GPU/
NPU could sometimes do it faster - but those are hard to program. Free-threaded numpy is the
*fast-to-build, good-enough, all-Python* path, which is often what unblocks a field entirely.

- **SDR / RF spectrum sensing.** Interference hunting, spectrum surveys, ham radio, signal
  classification with a cheap dongle. FFT-bound and core-hungry. (Keep it on the legitimate
  monitoring/research side.)
- **Raw GNSS science.** Android exposes raw GNSS measurements; precise positioning and
  ionospheric studies are Kalman-filter and least-squares heavy.
- **Agriculture & environmental sensing.** Camera-based spectral proxies for crop and water
  health, plus cheap external sensors - field-deployed, offline, at the price point a farm
  co-op or a school can actually afford.

---

## Cross-cutting patterns worth stealing

Independent of the field, these shapes recur - if your idea fits one, it probably fits here:

| pattern | why this stack suits it |
|---|---|
| **Cheap-and-many** | density beats precision; $100 nodes make networks that instruments can't |
| **Mandatory-offline** | the work is where the network isn't; on-device is the only architecture |
| **Privacy-by-location** | the data physically never leaves the device |
| **Edge triage** | ship detections/features, not raw data - saves bandwidth, battery and backhaul |
| **Democratised instruments** | a phone is a lab a student or a field team in a low-resource setting already owns |

---

## Honest limits

Read this before you promise anyone anything.

- **Thermal and battery** cap *sustained* full-core load. This shines for bursty or
  duty-cycled real-time work, not 24/7 pegged CPU. Budget for throttling.
- **The GPU/NPU/DSP block may be faster** for some workloads - but they're far harder to
  program. This stack is the "good enough, ships this week, stays in Python" option. Know
  which one your problem needs.
- **Memory** on the cheapest phones is the real ceiling for imaging and large arrays.
- **Precision.** Consumer sensors are consumer-grade. This is a screening / field /
  citizen-science tier by default, not a calibrated-instrument replacement.
- **Medicine is a validation and regulatory story**, not a compute one. "It runs on a
  phone" is the easy 10%. Clinical validation, and clearance where it applies, is the rest -
  and nothing here is a medical device.

None of these are reasons not to build. They're the difference between a demo that impresses
and a deployment that survives contact with the real world.

---

## Have one we missed - or built one?

The whole point of publishing this is to find out what people do with it.

- **Open an issue** describing the use case, especially if you got it working - we'll happily
  link real projects from here.
- If you're using it in a field not listed above, that's the most interesting kind of report:
  it tells everyone else the stack reaches further than we knew.

Nothing here is a claim that *we* built these - it's a map of doors the tool opens. Go find
out which ones lead somewhere.
