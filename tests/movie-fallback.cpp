// The runner inserts the actual patched function, cvars, and atomic globals.
// Only the clock, cvar registration, and logging are replaced. No GPU needed.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace rex::cvar {
enum class Lifecycle { kHotReload };
}
struct Metadata {
  int32_t min = 0, max = 0;
  Metadata range(int32_t lo, int32_t hi) const { return {lo, hi}; }
  Metadata lifecycle(rex::cvar::Lifecycle) const { return *this; }
};
#define REXCVAR_DECLARE(type, name) extern type name
#define REXCVAR_DEFINE_BOOL(name, initial, ...) \
  bool name = initial; const auto name##_metadata = Metadata{}
#define REXCVAR_DEFINE_INT32(name, initial, ...) \
  int32_t name = initial; const auto name##_metadata = Metadata{}
#define REXCVAR_GET(name) (name)
static int info_logs = 0, warning_logs = 0;
#define REXLOG_INFO(...) (++info_logs)
#define REXLOG_WARN(...) (++warning_logs)
struct PerfClock {
  static inline int64_t now_ns = 0;
  static auto now() {
    return std::chrono::time_point<std::chrono::steady_clock,
                                   std::chrono::nanoseconds>(
        std::chrono::nanoseconds(now_ns));
  }
};
#include "movie-fallback-extracted.inc"

static void expect(bool condition, const char* description) {
  if (!condition) {
    std::cerr << "FAIL: " << description << '\n';
    std::exit(1);
  }
}
static int64_t ns(int64_t ms) { return ms * 1'000'000; }
static void clock_at(int64_t ms) { PerfClock::now_ns = ns(ms); }
static void decode(int64_t ms) { g_movie_decode_last_ns = ns(ms); }
static void quad(int64_t ms) { g_movie_quad_last_ns = ns(ms); }
static void frame(int64_t ms) { clock_at(ms); decode(ms); quad(ms); }
static void begin_latch() {
  frame(0);
  expect(!YieldForMovie(), "entry has a grace period");
  frame(400);
  expect(YieldForMovie(), "fallback enters at 400 ms");
}

int main(int argc, char** argv) {
  expect(argc == 2, "one scenario argument required");
  const std::string scenario = argv[1];
  if (scenario == "defaults") {
    expect(skate3_native_render_scene_fmv_yield, "fallback defaults on");
    expect(skate3_native_render_scene_fmv_yield_max_ms ==
               (REX_PLATFORM_ANDROID ? 6000 : 0),
           "Android timeout 6000; Linux/other timeout disabled");
    expect(skate3_native_render_scene_fmv_yield_max_ms_metadata.min == 0 &&
               skate3_native_render_scene_fmv_yield_max_ms_metadata.max == 120000,
           "upstream timeout range retained");
  } else {
    skate3_native_render_scene_fmv_yield_max_ms = 0;
    if (scenario == "disabled") {
      clock_at(1000);
      expect(!YieldForMovie(), "no decoder heartbeat does not yield");
      skate3_native_render_scene_fmv_yield = false;
      frame(1000);
      expect(!YieldForMovie(), "disabled fallback does not yield");
      frame(2000);
      expect(!YieldForMovie(), "disabled fallback stays off");
    } else if (scenario == "heartbeat-gap") {
      frame(0);
      expect(!YieldForMovie(), "first heartbeat starts grace");
      clock_at(399); quad(399);
      expect(!YieldForMovie(), "399 ms still in grace");
      clock_at(600); quad(600);
      expect(YieldForMovie(), "600 ms callback gap must not reset grace");
      clock_at(1499);
      expect(YieldForMovie(), "1499 ms callback gap remains active");
      clock_at(1500);
      expect(!YieldForMovie(), "1500 ms callback gap ends session");
    } else if (scenario == "quad-latch") {
      begin_latch();
      // RenderScene returns before 2D replay while yielded: no quad updates.
      for (int64_t ms : {900, 1800, 3000, 4400}) {
        clock_at(ms); decode(ms);
        expect(YieldForMovie(), "stale quad must not cancel active fallback");
      }
      expect(info_logs == 1, "one entry log; no output oscillation");
    } else if (scenario == "end-next-session") {
      begin_latch();
      clock_at(1899);
      expect(YieldForMovie(), "last heartbeat held for 1499 ms");
      clock_at(1900);
      expect(!YieldForMovie(), "genuine heartbeat end resumes native");
      expect(info_logs == 2, "entry and end each log once");
      clock_at(2000);
      expect(!YieldForMovie(), "ended session stays native");
      frame(2500);
      expect(!YieldForMovie(), "next session has fresh grace period");
      frame(2899);
      expect(!YieldForMovie(), "next session grace lasts 400 ms");
      frame(2900);
      expect(YieldForMovie(), "next session can latch again");
    } else if (scenario == "entry-guards") {
      clock_at(0); decode(0);
      expect(!YieldForMovie(), "initial grace without quad");
      clock_at(400); decode(400);
      expect(!YieldForMovie(), "heartbeat alone cannot start fallback");
      clock_at(600); decode(600); quad(100);
      expect(!YieldForMovie(), "500 ms old quad is not fresh for entry");
      clock_at(601); decode(601); quad(102);
      expect(YieldForMovie(), "499 ms old quad allows entry");
    } else if (scenario == "native-served") {
      frame(0); g_movie_native_last_ns = ns(0);
      expect(!YieldForMovie(), "native movie starts without fallback");
      frame(400);
      expect(!YieldForMovie(), "recent native substitution blocks entry");
      frame(1000);
      expect(!YieldForMovie(), "native staleness threshold is strict");
      frame(1001);
      expect(YieldForMovie(), "unserved decoder advances beyond one second");
    } else if (scenario == "timeout-next-session") {
      skate3_native_render_scene_fmv_yield_max_ms = 6000;
      begin_latch();
      for (int64_t ms = 1000; ms <= 6000; ms += 1000) {
        clock_at(ms); decode(ms);
        expect(YieldForMovie(), "active fallback before hard timeout");
      }
      clock_at(6399); decode(6399);
      expect(YieldForMovie(), "timeout starts at latch, not first heartbeat");
      clock_at(6400); decode(6400);
      expect(!YieldForMovie(), "exact 6000 ms latch timeout resumes native");
      expect(warning_logs == 1, "timeout warns once");
      frame(7000);
      expect(!YieldForMovie(), "fresh quad cannot rearm timed-out session");
      expect(warning_logs == 1, "timed-out session does not repeat warning");
      clock_at(8500);
      expect(!YieldForMovie(), "heartbeat expiry clears timeout lockout");
      frame(9000);
      expect(!YieldForMovie(), "new session restarts grace after timeout");
      frame(9400);
      expect(YieldForMovie(), "new session can latch after timeout");
      for (int64_t ms = 10400; ms <= 14400; ms += 1000) {
        clock_at(ms); decode(ms);
        expect(YieldForMovie(), "new session has its own timeout budget");
      }
      clock_at(15400); decode(15400);
      expect(!YieldForMovie(), "new session timeout also works");
      expect(warning_logs == 2, "one warning per timed-out session");
    } else if (scenario == "unbounded") {
      begin_latch();
      for (int64_t ms = 1100; ms < 131000; ms += 700) {
        clock_at(ms); decode(ms);
        expect(YieldForMovie(), "zero timeout remains latched beyond 120 s");
      }
      expect(warning_logs == 0, "unbounded fallback never warns of timeout");
    } else {
      expect(false, "unknown scenario");
    }
  }
  std::cout << "PASS " << scenario << '\n';
}
