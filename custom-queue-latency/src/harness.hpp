#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// 큐 구현을 갈아끼울 수 있도록 시나리오 설정과 결과 구조체 정의

enum class BackpressurePolicy {
  Block,
  Drop,
};

struct ScenarioConfig {
  int producers = 1;
  int consumers = 1; // 현재는 1만 지원(요구사항), 구조체만 열어둠
  std::chrono::seconds duration{10};
  std::chrono::seconds warmup{0};
  std::size_t capacity = 1024;
  double rate_per_producer = 0.0; // 0이면 가능한 한 빠르게
  BackpressurePolicy policy = BackpressurePolicy::Block;
  std::string queue_type = "mutex";
};

struct ScenarioResult {
  double tps = 0.0;
  double avg_latency_us = 0.0;
  double p95_latency_us = 0.0;
  double p99_latency_us = 0.0;

  std::uint64_t produced = 0;
  std::uint64_t consumed = 0;
  std::uint64_t dropped = 0;

  std::chrono::nanoseconds elapsed{0};
  std::size_t samples = 0;
};

ScenarioResult runScenario(const ScenarioConfig& config);

// --- 유틸: 단순 퍼센타일 계산 ---
// 입력은 "나노초" 샘플 벡터. 결과는 "마이크로초" 단위로 반환.
double percentileLatencyUs(std::vector<std::int64_t>& sorted_latency_ns, double p);

