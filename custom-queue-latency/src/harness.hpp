#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "queues.hpp"

struct ScenarioConfig {
  int producers = 1;
  int consumers = 1; // 현재는 1만 지원(요구사항), 구조체만 열어둠
  std::chrono::seconds duration{10};
  std::chrono::seconds warmup{0};
  std::size_t capacity = 1024;
  double rate_per_producer = 0.0; // 0이면 가능한 한 빠르게
  BackpressurePolicy policy = BackpressurePolicy::Block;
  std::string queue_type = "global_lock";
  WaitStrategy wait_strategy = WaitStrategy::QueueDefault;
};

struct ScenarioResult {
  double tps = 0.0;
  double avg_latency_us = 0.0;
  double p95_latency_us = 0.0;
  double p99_latency_us = 0.0;

  std::uint64_t produced = 0;
  std::uint64_t consumed = 0;
  std::uint64_t dropped = 0;
  QueueStatsSnapshot queue_stats{};

  std::chrono::nanoseconds elapsed{0};
  std::size_t samples = 0;
};

ScenarioResult runScenario(const ScenarioConfig& config);

// --- 유틸: 단순 퍼센타일 계산 ---
// 입력은 "나노초" 샘플 벡터. 결과는 "마이크로초" 단위로 반환.
double percentileLatencyUs(std::vector<std::int64_t>& sorted_latency_ns, double p);
