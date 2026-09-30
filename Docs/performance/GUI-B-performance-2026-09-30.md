# GUI B performance measurement — 2026-09-30

## Scope and conditions

- Current local Debug build of `LingXiMacAppB`, with the built-in static background and translucent containers.
- Apple M5 MacBook Air, 32 GiB RAM; display 1920 × 1243 logical / 3840 × 2486 physical pixels, 60 Hz; application window 1460 × 900 points.
- Idle application and an existing six-message conversation; no model request or tool execution. Scroll workload: 20 alternating page-up/page-down operations, approximately 9.4 seconds.
- Measurements did not modify product code. No new dependency was installed.

## Method

CPU and physical footprint were sampled once per second through `proc_pid_rusage`. CPU 100% denotes one fully used CPU core. The Apple Silicon CPU-time conversion was calibrated with a short busy loop. Physical footprint is used here rather than RSS.

GPU percentages were instantaneous AGX accelerator registry readings for the entire machine. They cannot identify GPU usage attributable to B. GUI inspection/window sharing demonstrably affected these readings, so observed and unobserved runs are reported separately.

Animation Hitches was recorded using the installed Xcode Instruments tooling. Hitch rows were filtered to the target B process. The profiler launched B with a minimal environment; environment values are not retained in this report. Profiling overhead remains part of the measured conditions.

## Results

| Workload | Valid samples | GUI CPU mean / peak | GUI physical footprint | Core physical footprint | Whole-machine GPU mean |
| --- | --- | --- | --- | --- | --- |
| Idle, without GUI observation | 25 seconds | 0.083% / 1.711% | Mean 67.34 MiB | Mean 146.76 MiB | 4.96% |
| Second idle run, without GUI observation | 20 seconds | 0.101% / 1.956% | Mean 55.22 MiB | Mean 135.43 MiB | 0.00% |
| Same process after GUI observation starts | 12 seconds | 0.031% / 0.324% | Mean 51.15 MiB | Mean 135.43 MiB | 45.42% |
| Active scrolling, with GUI observation | 10 one-second samples | 11.941% / 16.006% | End 85.20 MiB | End 90.38 MiB | Not attributable to B |

The complete scroll sampling window lasted 25 seconds. Its whole-machine GPU mean was 56.56%, with GUI observation active. GUI CPU fell to 0.007% in the last sample after scrolling stopped. Physical footprint showed no sustained growth during this short scroll workload; this is not a memory-leak test. Core footprints differ across launches and conversation states, so the idle-versus-scroll memory values are not a paired growth comparison.

In the paired observation test, the application process and empty page were unchanged. Whole-machine GPU mean rose from 0.00% before observation to 45.42% after observation. This implicates the observation/window-sharing path in the measured GPU load. It does not establish the cause of the user's earlier 20% reading, nor prove that B has zero GPU cost.

## Frame hitches

The complete 143.135-second recording included launch, conversation selection, scrolling, idle time, and GUI observation. Instruments attributed 293 hitch events to B, totaling 5183.13 ms. These are hitch intervals, not frame times or an FPS measurement.

- The two longest events occurred during the first five seconds: 216.66 ms at 0.839 s and 100.00 ms at 3.589 s. Both were marked as potentially expensive app updates.
- After the first five seconds, 289 events totaled 4833.14 ms; the maximum was 33.33 ms. Most were approximately one 60 Hz refresh interval.
- GUI observation was active during much of the recording. No precisely synchronized, uncontaminated scroll-only hitch rate was obtained. These events cannot establish user-visible scrolling performance without the observer.

## Assessment and limits

Idle CPU is low, and the new static-background B does not reproduce sustained high whole-machine GPU load in the unobserved samples. Short-conversation scrolling uses about 12% of one CPU core, with a 16% sampled peak. Launch contains measurable long hitches. GPU attribution and reliable application FPS remain unverified.

Not run: A-versus-B paired comparison, Release build, long conversation, live token streaming, image-heavy content, long-duration memory test, and per-application GPU attribution. No percentage improvement over the previous transparent version can be claimed from these measurements.

Raw traces and temporary probes were removed after extracting these results.

## References

- [Apple: Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple XNU: libproc declarations](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h)
