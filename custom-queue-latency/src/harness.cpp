#include "harness.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <thread>

namespace {

using SteadyClock = std::chrono::steady_clock;

class MetricsCollector {
 public:
  void recordLatencyNs(std::int64_t latency_ns) {
    latencies_ns_.push_back(latency_ns);
  }

  void reset() {
    latencies_ns_.clear();
    latencies_ns_.shrink_to_fit();
  }

  std::vector<std::int64_t>& latenciesNs() { return latencies_ns_; }
  const std::vector<std::int64_t>& latenciesNs() const { return latencies_ns_; }

 private:
  std::vector<std::int64_t> latencies_ns_;
};

struct RunState {
  std::atomic<bool> stop{false};
  std::atomic<std::int64_t> measure_start_ns{-1};
  std::atomic<std::uint64_t> produced{0};
  std::atomic<std::uint64_t> consumed{0};
  std::atomic<std::uint64_t> dropped{0};
};

void validateScenarioConfig(const ScenarioConfig& config, QueueKind queue_kind) {
  if (config.consumers != 1) {
    throw std::runtime_error("현재는 consumers=1만 지원합니다.");
  }
  if (config.producers <= 0) throw std::runtime_error("producers는 1 이상이어야 합니다.");
  if (config.duration.count() <= 0) throw std::runtime_error("duration은 1초 이상이어야 합니다.");
  if (config.warmup.count() < 0) throw std::runtime_error("warmup은 0초 이상이어야 합니다.");
  if (config.rate_per_producer < 0.0) throw std::runtime_error("rate는 0 이상이어야 합니다.");

  if (queue_kind == QueueKind::SpscRing) {
    if (config.producers != 1) {
      throw std::runtime_error("spsc는 producers=1만 지원합니다.");
    }
    if (config.consumers != 1) {
      throw std::runtime_error("spsc는 consumers=1만 지원합니다.");
    }
    if (config.capacity == 0) {
      throw std::runtime_error("spsc는 bounded queue이므로 capacity > 0이 필요합니다.");
    }
  }
}

} // namespace

double percentileLatencyUs(std::vector<std::int64_t>& sorted_latency_ns, double p) {
  if (sorted_latency_ns.empty()) return 0.0;
  if (p <= 0.0) return sorted_latency_ns.front() / 1000.0;
  if (p >= 100.0) return sorted_latency_ns.back() / 1000.0;

  const double rank = (p / 100.0) * static_cast<double>(sorted_latency_ns.size() - 1);
  const std::size_t idx = static_cast<std::size_t>(std::llround(rank));
  return sorted_latency_ns[std::min(idx, sorted_latency_ns.size() - 1)] / 1000.0;
}

ScenarioResult runScenario(const ScenarioConfig& config) {
  ScenarioResult result{};

  const auto queue_kind = parseQueueKind(config.queue_type);
  validateScenarioConfig(config, queue_kind);

  auto queue = makeQueue(queue_kind, config.capacity, QueueOptions{.wait_strategy = config.wait_strategy});
  MetricsCollector metrics;
  RunState state;

  const auto global_start = SteadyClock::now();
  const auto warmup_end = global_start + config.warmup;
  const auto measure_end = warmup_end + config.duration;
  state.measure_start_ns.store(
    std::chrono::duration_cast<std::chrono::nanoseconds>(warmup_end.time_since_epoch()).count(),
    std::memory_order_relaxed);

  std::thread consumer([&] {
    Event ev{};
    while (true) {
      if (!queue->pop(ev, state.stop)) break;
      const auto now = SteadyClock::now();

      const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
      const auto ev_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(ev.created_at.time_since_epoch()).count();
      if (start_ns >= 0 && ev_ns >= start_ns) {
        state.consumed.fetch_add(1, std::memory_order_relaxed);
        const auto latency = std::chrono::duration_cast<std::chrono::nanoseconds>(now - ev.created_at).count();
        metrics.recordLatencyNs(static_cast<std::int64_t>(latency));
      }
    }
  });

  std::vector<std::thread> producers;
  producers.reserve(static_cast<std::size_t>(config.producers));

  const bool rate_limited = config.rate_per_producer > 0.0;
  const auto interval = rate_limited
    ? std::chrono::duration_cast<SteadyClock::duration>(std::chrono::duration<double>(1.0 / config.rate_per_producer))
    : SteadyClock::duration::zero();

  for (int i = 0; i < config.producers; ++i) {
    producers.emplace_back([&, i] {
      auto next_fire = SteadyClock::now();
      std::uint64_t seq = 0;
      while (!state.stop.load(std::memory_order_relaxed)) {
        const auto now = SteadyClock::now();
        if (now >= measure_end) break;

        if (rate_limited) {
          if (now < next_fire) {
            std::this_thread::sleep_until(next_fire);
            continue;
          }
          next_fire += interval;
        }

        const auto created_at = SteadyClock::now();
        const auto created_ns =
          std::chrono::duration_cast<std::chrono::nanoseconds>(created_at.time_since_epoch()).count();

        Event ev{};
        ev.id = (static_cast<std::uint64_t>(i) << 48) | seq++;
        ev.route_key = static_cast<std::uint64_t>(i);
        ev.created_at = created_at;

        const bool ok = queue->push(std::move(ev), config.policy, state.stop);
        if (ok) {
          const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
          if (start_ns >= 0 && created_ns >= start_ns) {
            state.produced.fetch_add(1, std::memory_order_relaxed);
          }
        } else if (config.policy == BackpressurePolicy::Drop) {
          const auto start_ns = state.measure_start_ns.load(std::memory_order_relaxed);
          if (start_ns >= 0 && created_ns >= start_ns) {
            state.dropped.fetch_add(1, std::memory_order_relaxed);
          }
        }
      }
    });
  }

  if (config.warmup.count() > 0) {
    std::this_thread::sleep_until(warmup_end);
  }

  std::this_thread::sleep_until(measure_end);

  state.stop.store(true, std::memory_order_relaxed);
  queue->close();

  for (auto& t : producers) t.join();
  consumer.join();

  result.elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(config.duration);
  result.produced = state.produced.load(std::memory_order_relaxed);
  result.consumed = state.consumed.load(std::memory_order_relaxed);
  result.dropped = state.dropped.load(std::memory_order_relaxed);
  result.queue_stats = snapshotQueueStats(queue->stats());

  auto& samples = metrics.latenciesNs();
  result.samples = samples.size();

  if (!samples.empty()) {
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
