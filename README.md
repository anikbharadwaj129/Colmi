# Colmi

An Oura-style iOS app for the **Colmi R02** smart ring, built on a reverse-engineered
Bluetooth protocol. It pulls what the ring logs on its own — sleep stages, heart
rate, HRV, stress, SpO₂, skin temperature and steps — and turns it into
Readiness, Sleep and Activity scores, long-term health trends and timely
notifications. Everything runs on the phone: no account, no subscription, no
server.

> Not affiliated with Colmi, Realtek or Oura Health. Not a medical device —
> the scores here are estimates for personal insight, not diagnosis.

---

## Background

The Colmi R02 is an inexpensive smart ring built on a Realtek RT02CR chip. Its
hardware covers much of what pricier rings carry — a PPG sensor for heart rate
and blood oxygen, a skin-temperature sensor and an accelerometer — and its
firmware logs those readings through the day and night on its own. What it
lacks is software that does much with them: the stock QRing app shows the raw
numbers and little else.

This project closes that gap. The ring speaks plain Bluetooth Low Energy with
no pairing keys, and its protocol has been worked out piece by piece by the
open-source community (see [Credits](#credits)). The app uses that to read the
ring directly, then models its presentation and scoring on the Oura app: the
same three tabs, the same kinds of scores and contributors, and the same
definitions where Oura publishes them. Where Oura doesn't — it publishes no
weights or formulas — the app uses documented research and says so in the
code.

## What the app does

**Today**
- Shortcuts for Readiness, Sleep, Activity, Heart rate and Stress, reorderable
  (minimum three).
- A Readiness hero with its weakest contributor, or "ready after you wake"
  until last night's sleep has synced.
- A 24-hour heart-rate graph from the ring's 5-minute log, coloured by context
  (sleep, daytime, sessions, workouts), with an on-demand **Live heart rate**
  reading.
- A **+** menu for unguided (meditation) sessions, tags and workout heart rate,
  and a timeline of the day.
- Symptom Radar and Rest Mode cards when they apply.

**Vitals** — two-up cards grouped by area, a swipeable day strip with a
calendar, and sections you can reorder:
- **Readiness:** score, Symptom Radar
- **Sleep:** score, Body Clock, Sleep Debt, total sleep
- **Activity:** score, steps, active calories, workouts
- **Stress:** Daytime Stress, Resilience
- **Heart health:** Cardiovascular Age, Cardio Capacity (VO₂max), heart rate
- **Core metrics:** resting heart rate, HRV, body temperature, respiratory
  rate, blood oxygen — each with a trend view against your normal range

**My Health** — long-term health areas rated Thriving → Needs Care with 90-day
trend lines (Sleep Health, Stress Management, Heart Health), each with a hub;
Habits & Routines as rolling 30-day averages; and Trends for every metric by
day, week, month and year.

**Notifications** — low battery before bed, inactivity alerts, activity
progress, a bedtime reminder from personal bedtime guidance, and weekly
insights.

**Also:** Apple Health export (sleep, heart rate, HRV, SpO₂, temperature,
mindful minutes), Celsius/Fahrenheit, and a Debug tab with a live packet log
and raw command sender.

## How it works

### Talking to the ring

The ring exposes two GATT services:

| Service | UUID | Used for |
|---|---|---|
| UART (v1) | `6E40FFF0-…` | 16-byte command packets: `[command][14-byte payload][checksum]`, checksum = sum of the first 15 bytes |
| Big data (v2) | `DE5BF728-…` | Larger history replies, framed as `BC <type> <len> <crc> <payload>` and often several messages per reply |

Commands the app uses:

| Command | What it does |
|---|---|
| `0x01` | Set time (local wall-clock, BCD — the ring has no timezone) |
| `0x03` | Battery level and charging state |
| `0x15` | All-day heart-rate log: 288 five-minute slots per day |
| `0x16` | Heart-rate logging on/off and interval (1–255 min) |
| `0x2C` / `0x36` / `0x38` | All-day SpO₂ / stress / HRV logging on/off |
| `0x37` / `0x39` | Stress / HRV history for a given day |
| `0x43` | Steps, calories and distance in 15-minute slots |
| `0x69` / `0x6A` | Start / stop a live stream: heart rate (1), SpO₂ (3), beat-to-beat health check (5), stress (8) |
| Big data `0x27` | Sleep stages per night |
| Big data `0x2A` | SpO₂, 48 half-hour slots per day |
| Big data `0x25` | Skin temperature, 48 half-hour slots per day |

A few details that matter, all learned the hard way and checked against real
captures:

- A sleep record's start and end are minutes from midnight and both wrap, so a
  night that starts at 23:27 begins the evening *before* the day it's filed
  under.
- History replies (`0x37`/`0x39`) count their header in the packet total.
- SpO₂ and temperature replies pack several days back to back as fixed-size
  records.
- Every series dates itself by the day you asked for; the ring keeps no
  absolute clock beyond what it was last set to.

### Syncing and background operation

The app syncs everything the ring has logged — about the last week — whenever
it gets the chance: when the ring connects or reconnects, when you open the
app, and on background refreshes, if the last sync is more than 30 minutes old.

iOS doesn't let apps run timers in the background, so the app is built around
the chances it does get:

- **Bluetooth state restoration** keeps a pending connection alive and has iOS
  relaunch the app when the ring comes back in range. A pending connection is
  held by the Bluetooth chip, so it costs the phone essentially nothing.
- **App measurements** (heart rate & HRV, SpO₂, stress, each every 15 min–4 h
  or off) run on top of the ring's own logging whenever the app is awake.
- **Background App Refresh** is requested around the next due measurement; iOS
  decides when it actually runs.

### From raw data to scores

Raw logs roll up into one row per day. Personal baselines compare a day
against your own recent normal — the two months before it, three for HRV,
28 days for Symptom Radar — never against population averages.

| Score | How it's built |
|---|---|
| **Readiness** | Oura's nine contributors — resting heart rate, HRV balance, body temperature, recovery index, sleep, sleep balance, sleep regularity, previous-day activity and activity balance. "Balance" contributors compare a 14-day weighted average with your long-term average, as Oura describes. Shown only once the night's sleep has synced. |
| **Sleep** | Total sleep, efficiency, restfulness, REM, deep sleep and timing. |
| **Activity** | Steps against a goal, active calories and training frequency. Calories use the MET walking equation (0.0005 × metres × kg, doubled for running). Activity days run 4 AM–4 AM, as in Oura. |
| **Symptom Radar** | Temperature and its 3-night trend, resting heart rate, HRV, respiratory rate and inactive time, each scored against your normal. It needs several signals together to flag anything, and two nights in a row for "major" — approach from UCSF's TemPredict study and Stanford's NightSignal. |
| **Respiratory rate** | Estimated from beat-to-beat intervals: breathing modulates heart rate, so the interval series oscillates at the breathing rate, which spectral analysis picks out. |
| **Cardiovascular age** | Built from resting heart rate, HRV and SpO₂ over 30 nights. Oura uses pulse wave velocity, which needs the raw PPG waveform this ring doesn't share — so this is a different route to a similar question. |

Also included: Sleep Debt, Body Clock, chronotype, Resilience, Cumulative
Stress and Cardio Capacity (VO₂max).

### Days

Like Oura, the app keeps three kinds of day:

- **Calendar day:** midnight to midnight.
- **Activity day:** 4 AM to 4 AM, so a 3 AM dance floor counts toward the day
  before.
- **Sleep day:** 6 PM to 6 PM. The longest sleep in it is that day's night.

## Project layout

```
RingApp/
  RingProtocol.swift      Packet framing and parsers for every command above
  RingConnection.swift    CoreBluetooth connection, restoration, live streams
  RingStore.swift         Persistence, daily roll-up, sync, Apple Health export
  Metrics.swift           Scores, baselines, respiratory rate, Symptom Radar
  HealthAreas.swift       My Health ratings, chronotype, cumulative stress, trends
  NotificationRules.swift When each notification should fire; bedtime guidance
  Monitor.swift           App services, scheduled measurements, background refresh
  Notifications.swift     Scheduling notifications
  ContentView.swift       App entry, Today tab, detail screens, settings, Debug
  Vitals.swift            Vitals tab and its detail screens
  MyHealth.swift          My Health tab, hubs and Trends
  Sessions.swift          Heart-rate card, timeline, unguided sessions, workouts
  SymptomRadarView.swift  Symptom Radar screen and Rest Mode
  DesignSystem.swift      Colours, cards, gauges, charts
```

## Building and running

**Requirements:**
- Xcode 26 and an iPhone on iOS 26.5 or later. The Simulator runs the app but
  has no Bluetooth, so it can't reach a ring.
- A Colmi R02 (the R06 and R10 are reported to use the same protocol).

**Steps:**
1. Open `RingApp.xcodeproj` and set your development team under Signing &
   Capabilities. The bundle ID may need changing to one your team can sign.
2. Close QRing, or at least disconnect it — the ring talks to one app at a time.
3. Run on your iPhone and allow Bluetooth, Health and notifications. The app
   finds the ring, connects, and syncs.
4. In Settings, check the four **Ring monitoring** switches read back as on,
   set your birth year and weight, and choose your **App measurements**
   intervals.
5. Make sure **Background App Refresh** is on for the app, and avoid swiping it
   away in the app switcher — that stops background activity until it's
   opened again.

## Limitations

- **Formulas are the app's own.** Oura names its contributors and some
  reference points but publishes no weights or formulas, so the scoring here
  is the app's own, informed by Oura's documentation and published research.
  Expect different numbers from an Oura ring.
- **Fixed firmware cadences.** The ring decides how often it logs SpO₂, stress
  and HRV (about every 30–60 minutes), and that can't be changed. App
  measurements add readings only when iOS gives the app time.
- **Step counts vary.** They can differ substantially from a phone or watch
  for the same day.
- **Beat-to-beat data is unverified.** Reading beat intervals from the live
  stream hasn't been independently validated, so HRV from captures and
  respiratory rate should be treated as experimental.

## Credits

This app stands on the reverse-engineering work of others:

- **[tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client)** —
  the open-source Python client and protocol documentation for the Colmi R02.
  It established the 16-byte UART framing, live readings, the heart-rate log,
  steps, time-setting and much of the command set this app is built on. (MIT)
- **[ngeorge15/smart-ring](https://github.com/ngeorge15/smart-ring)** — a
  thorough Colmi R02 data pipeline whose protocol notes and captured packets
  pinned down the details that matter: the big-data service and its
  multi-message framing, the temperature command (`0x25`) and its scale, the
  SpO₂ and temperature record layouts, sleep records that cross midnight, the
  stress and HRV history format, step distance units, and which live readings
  actually work. This app's parsers were checked against its reference
  output on real ring data.

Scoring and presentation draw on Oura's public help articles and blog, and on
published research, including:

- UCSF's TemPredict study (Smarr et al., 2020; Mason et al., 2022)
- Stanford's wearable illness-detection work (Mishra et al., 2020; Alavi et
  al., 2022)
- Fitbit's (Natarajan et al., 2020) and WHOOP's (Miller et al., 2020)
  respiratory-rate studies

Oura is a trademark of Oura Health Oy; it's referenced here only to describe
the features this app models.

## License

[Apache 2.0](LICENSE).
