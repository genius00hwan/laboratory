#include "harness.hpp"

#include <algorithm>
#include <cassert>
#include <condition_variable>
#include <cmath>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace {

using SteadyClock = std::chrono::steady_clock;

struct Event {
  SteadyClock::time_point t0;
};

// 가장 단순한 baseline: std::deque + mutex + condition_variable
// - capacity를 넘기면 policy에 따라 block 또는 drop
// - close()로 consumer/producers를 깨워 종료 가능하게 함
class MutexQueue {
 public:
  explicit MutexQueue(std::size_t capacity) : capacity_(capacity) {}

  MutexQueue(const MutexQueue&) = delete;
  MutexQueue& operator=(const MutexQueue&) = delete;

  // 반환값: push 성공 여부 (Drop 정책에서만 false 가능)
  bool push(Event ev, BackpressurePolicy policy, const std::atomic<bool>& stop_flag) {
    std::unique_lock<std::mutex> lock(mu_);
    if (closed_) return false;

    if (capacity_ != 0) {
      if (policy == BackpressurePolicy::Block) {
        not_full_cv_.wait(lock, [&] {
          return closed_ || stop_flag.load(std::memory_order_relaxed) || queue_.size() < capacity_;
        });
        if (closed_ || stop_flag.load(std::memory_order_relaxed)) return false;
      } else { // Drop
        if (queue_.size() >= capacity_) return false;
      }
    }

    queue_.push_back(std::move(ev));
    not_empty_cv_.notify_one();
    return true;
  }

  // 반환값: pop 성공 여부 (종료/close 시 false)
  bool pop(Event& out, const std::atomic<bool>& stop_flag) {
    std::unique_lock<std::mutex> lock(mu_);
    not_empty_cv_.wait(lock, [&] {
      return closed_ || stop_flag.load(std::memory_order_relaxed) || !queue_.empty();
    });
    if (queue_.empty()) return false;

    out = std::move(queue_.front());
    queue_.pop_front();
    not_full_cv_.notify_one();
    return true;
  }

  void close() {
    std::lock_guard<std::mutex> lock(mu_);
    closed_ = true;
    not_empty_cv_.notify_all();
    not_full_cv_.notify_all();
  }

 private:
  std::mutex mu_;
  std::condition_variable not_empty_cv_;
  std::condition_variable not_full_cv_;
  std::deque<Event> queue_;
  std::size_t capacity_ = 0; // 0이면 unbounded로 취급
  bool closed_ = false;
};

class MetricsCollector {
 public:
  void recordLatencyNs(std::int64_t latency_ns) {
    // 1일차는 "그냥 벡터에 모아서" 종료 후 정렬로 p95/p99 계산한다.
    latencies_ns_.push_back(latency_ns);
  }

  void reset() {
    latencies_ns_.clear();
    latencies_ns_.shrink_to_fit(); // warmup이 길면 메모리가 커질 수 있어 1회 정리
  }

  std::vector<std::int64_t>& latenciesNs() { return latencies_ns_; }
  const std::vector<std::int64_t>& latenciesNs() const { return latencies_ns_; }

 private:
  std::vector<std::int64_t> latencies_ns_;
};

struct RunState {
  std::atomic<bool> stop{false};
  // steady_clock::time_point은 atomic으로 들고가기 애매해서,
  // time_since_epoch()를 나노초 카운트로 변환해 공유한다.
  // -1이면 "아직 측정 시작 안 함"을 의미한다.
  std::atomic<std::int64_t> measure_start_ns{-1};
  std::atomic<std::uint64_t> produced{0};
  std::atomic<std::uint64_t> consumed{0};
  std::atomic<std::uint64_t> dropped{0};
};

} // namespace

double percentileLatencyUs(std::vector<std::int64_t>& sorted_latency_ns, double p) {
  if (sorted_latency_ns.empty()) return 0.0;
  if (p <= 0.0) return sorted_latency_ns.front() / 1000.0;
  if (p >= 100.0) return sorted_latency_ns.back() / 1000.0;

  // "가장 단순한" nearest-rank 방식. 나중에 HDR/히스토그램으로 갈아끼우기 쉬움.
  const double rank = (p / 100.0) * static_cast<double>(sorted_latency_ns.size() - 1);
  const std::size_t idx = static_cast<std::size_t>(std::llround(rank));
  return sorted_latency_ns[std::min(idx, sorted_latency_ns.size() - 1)] / 1000.0;
}

ScenarioResult runScenario(const ScenarioConfig& config) {
  ScenarioResult result{};

  if (config.consumers != 1) {
    // 요구사항상 consumers=1로 고정. 이후 확장 시 여기서 MPMC 소비 구현을 붙이면 됨.
    throw std::runtime_error("현재는 consumers=1만 지원합니다.");
  }
  if (config.producers <= 0) throw std::runtime_error("producers는 1 이상이어야 합니다.");
  if (config.duration.count() <= 0) throw std::runtime_error("duration은 1초 이상이어야 합니다.");
  if (config.warmup.count() < 0) throw std::runtime_error("warmup은 0초 이상이어야 합니다.");
  if (config.rate_per_producer < 0.0) throw std::runtime_error("rate는 0 이상이어야 합니다.");

  if (config.queue_type != "mutex") {
    throw std::runtime_error("queue_type은 현재 'mutex'만 지원합니다.");
  }

  MutexQueue queue(config.capacity);
  MetricsCollector metrics;
  RunState state;

  const auto global_start = SteadyClock::now();
  const auto warmup_end = global_start + config.warmup;
  const auto measure_end = warmup_end + config.duration;
  state.measure_start_ns.store(
    std::chrono::duration_cast<std::chrono::nanoseconds>(warmup_end.time_since_epoch()).count(),
    std::memory_order_relaxed);

  // consumer thread (1개)
  std::thread consumer([&] {
    Event ev{};
    while (true) {
      if (!queue.pop(ev, state.stop)) break;
      const auto now = SteadyClock::now();

      const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
      const auto ev_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(ev.t0.time_since_epoch()).count();
      if (start_ns >= 0 && ev_ns >= start_ns) {
        state.consumed.fetch_add(1, std::memory_order_relaxed);
        const auto latency = std::chrono::duration_cast<std::chrono::nanoseconds>(now - ev.t0).count();
        metrics.recordLatencyNs(static_cast<std::int64_t>(latency));
      }
    }
  });

  // producer threads
  std::vector<std::thread> producers;
  producers.reserve(static_cast<std::size_t>(config.producers));

  const bool rate_limited = config.rate_per_producer > 0.0;
  const auto interval = rate_limited
    ? std::chrono::duration_cast<SteadyClock::duration>(std::chrono::duration<double>(1.0 / config.rate_per_producer))
    : SteadyClock::duration::zero();

  for (int i = 0; i < config.producers; ++i) {
    producers.emplace_back([&, i] {
      (void)i;
      auto next_fire = SteadyClock::now();
      while (!state.stop.load(std::memory_order_relaxed)) {
        const auto now = SteadyClock::now();
        if (now >= measure_end) break;

        if (rate_limited) {
          // 고정 간격으로 "발사 시점"을 누적해 드리프트를 줄인다.
          if (now < next_fire) {
            std::this_thread::sleep_until(next_fire);
            continue;
          }
          next_fire += interval;
        }

        const auto t0 = SteadyClock::now();
        const auto t0_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t0.time_since_epoch()).count();
        Event ev{.t0 = t0};
        const bool ok = queue.push(std::move(ev), config.policy, state.stop);
        if (ok) {
          const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
          if (start_ns >= 0 && t0_ns >= start_ns) {
            state.produced.fetch_add(1, std::memory_order_relaxed);
          }
        } else if (config.policy == BackpressurePolicy::Drop) {
          const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
          if (start_ns >= 0 && t0_ns >= start_ns) {
            state.dropped.fetch_add(1, std::memory_order_relaxed);
          }
        }
      }
    });
  }

  // warmup은 "측정 시작 시점(warmup_end)" 이전에 생성된 이벤트를 샘플에서 제외하는 방식으로 처리한다.
  // (warmup 구간에 생성된 이벤트가 큐에 남아있을 수 있기 때문)
  if (config.warmup.count() > 0) {
    std::this_thread::sleep_until(warmup_end);
  }

  std::this_thread::sleep_until(measure_end);

  // 종료 절차: stop → queue close → join
  state.stop.store(true, std::memory_order_relaxed);
  queue.close();

  for (auto& t : producers) t.join();
  consumer.join();

  result.elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(config.duration);

  result.produced = state.produced.load(std::memory_order_relaxed);
  result.consumed = state.consumed.load(std::memory_order_relaxed);
  result.dropped = state.dropped.load(std::memory_order_relaxed);

  auto& samples = metrics.latenciesNs();
  result.samples = samples.size();

  if (!samples.empty()) {
    // avg
    long double sum = 0;
    for (const auto v : samples) sum += static_cast<long double>(v);
    const long double avg_ns = sum / static_cast<long double>(samples.size());
    result.avg_latency_us = static_cast<double>(avg_ns / 1000.0L);

    std::sort(samples.begin(), samples.end());
    result.p95_latency_us = percentileLatencyUs(samples, 95.0);
    result.p99_latency_us = percentileLatencyUs(samples, 99.0);
  }

  const double measure_s = std::chrono::duration<double>(config.duration).count();
  result.tps = measure_s > 0.0 ? static_cast<double>(result.consumed) / measure_s : 0.0;

  return result;
}
