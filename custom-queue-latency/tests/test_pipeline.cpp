#include "pipeline.hpp"

#include <chrono>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

void expectThrows(const std::function<void()>& fn, const std::string& message) {
  try {
    fn();
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error(message);
}

PipelineConfig makeBaseConfig(PipelineTopology topology) {
  PipelineConfig config{};
  config.topology = topology;
  config.duration = std::chrono::milliseconds(300);
  config.warmup = std::chrono::milliseconds(0);
  config.ingress_threads = 4;
  config.worker_threads = 4;
  config.ingress_queue_capacity = 64;
  config.worker_queue_capacity = 16;
  config.rate_per_ingress = 10000.0;
  config.policy = BackpressurePolicy::Block;
  config.service_ns = 10'000;
  config.jitter_ns = 0;
  config.shared_queue_kind = QueueKind::SplitLockLinked;
  config.dispatch_queue_kind = QueueKind::SplitLockLinked;
  return config;
}

void testSharedMpmcRingBlock() {
  auto config = makeBaseConfig(PipelineTopology::SharedQueue);
  config.shared_queue_kind = QueueKind::MpmcRing;

  const auto result = runPipelineScenario(config);

  expect(result.completed > 0, "shared mpmc ring block: completed should be > 0");
  expect(result.dropped == 0, "shared mpmc ring block: dropped should be 0");
  expect(result.accepted == result.completed, "shared mpmc ring block: accepted should drain to completed");
  expect(result.samples == result.completed, "shared mpmc ring block: samples should equal completed");
  expect(result.worker_completed_max >= result.worker_completed_min,
         "shared mpmc ring block: worker max should be >= min");
}

void testSharedSplitLockDrop() {
  auto config = makeBaseConfig(PipelineTopology::SharedQueue);
  config.shared_queue_kind = QueueKind::SplitLockLinked;
  config.policy = BackpressurePolicy::Drop;
  config.ingress_queue_capacity = 8;
  config.rate_per_ingress = 0.0;
  config.service_ns = 200'000;

  const auto result = runPipelineScenario(config);

  expect(result.completed > 0, "shared split lock drop: completed should be > 0");
  expect(result.dropped > 0, "shared split lock drop: drop should occur under overload");
  expect(result.accepted == result.completed, "shared split lock drop: accepted should drain to completed");
  expect(result.samples == result.completed, "shared split lock drop: samples should equal completed");
  expect(result.worker_completed_max >= result.worker_completed_min,
         "shared split lock drop: worker max should be >= min");
}

void testDispatchLocalSpscBlock() {
  auto config = makeBaseConfig(PipelineTopology::DispatchLocalSpsc);
  config.dispatch_queue_kind = QueueKind::SplitLockLinked;
  config.worker_queue_capacity = 32;

  const auto result = runPipelineScenario(config);

  expect(result.completed > 0, "dispatch local spsc block: completed should be > 0");
  expect(result.dropped == 0, "dispatch local spsc block: dropped should be 0");
  expect(result.accepted == result.completed, "dispatch local spsc block: accepted should drain to completed");
  expect(result.samples == result.completed, "dispatch local spsc block: samples should equal completed");
  expect(result.worker_completed_max >= result.worker_completed_min,
         "dispatch local spsc block: worker max should be >= min");
}

void testDispatchLocalSpscDrop() {
  auto config = makeBaseConfig(PipelineTopology::DispatchLocalSpsc);
  config.policy = BackpressurePolicy::Drop;
  config.ingress_queue_capacity = 32;
  config.worker_queue_capacity = 4;
  config.rate_per_ingress = 0.0;
  config.service_ns = 250'000;

  const auto result = runPipelineScenario(config);

  expect(result.completed > 0, "dispatch local spsc drop: completed should be > 0");
  expect(result.dropped > 0, "dispatch local spsc drop: drop should occur under overload");
  expect(result.accepted == result.completed + result.dropped_dispatch,
         "dispatch local spsc drop: accepted events should either complete or drop at worker queues");
  expect(result.samples == result.completed, "dispatch local spsc drop: samples should equal completed");
  expect(result.worker_completed_max >= result.worker_completed_min,
         "dispatch local spsc drop: worker max should be >= min");
}

void testDirectLocalSpscBlock() {
  auto config = makeBaseConfig(PipelineTopology::DirectLocalSpsc);
  config.ingress_threads = 4;
  config.worker_threads = 4;
  config.worker_queue_capacity = 32;

  const auto result = runPipelineScenario(config);

  expect(result.completed > 0, "direct local spsc block: completed should be > 0");
  expect(result.dropped == 0, "direct local spsc block: dropped should be 0");
  expect(result.accepted == result.completed, "direct local spsc block: accepted should drain to completed");
  expect(result.samples == result.completed, "direct local spsc block: samples should equal completed");
}

void testDirectLocalSpscInvalidConfig() {
  expectThrows([] {
    auto config = makeBaseConfig(PipelineTopology::DirectLocalSpsc);
    config.ingress_threads = 5;
    config.worker_threads = 4;
    (void)runPipelineScenario(config);
  }, "direct topology should reject ingress_threads > worker_threads");
}

void testInvalidConfigs() {
  expectThrows([] {
    auto config = makeBaseConfig(PipelineTopology::SharedQueue);
    config.shared_queue_kind = QueueKind::SpscRing;
    (void)runPipelineScenario(config);
  }, "shared topology should reject spsc shared queue");

  expectThrows([] {
    auto config = makeBaseConfig(PipelineTopology::DispatchLocalSpsc);
    config.dispatch_queue_kind = QueueKind::SpscRing;
    (void)runPipelineScenario(config);
  }, "dispatch topology should reject spsc dispatch queue");

  expectThrows([] {
    auto config = makeBaseConfig(PipelineTopology::DispatchLocalSpsc);
    config.worker_queue_capacity = 0;
    (void)runPipelineScenario(config);
  }, "dispatch topology should reject worker_queue_capacity=0");
}

} // namespace

int main() {
  try {
    testSharedMpmcRingBlock();
    testSharedSplitLockDrop();
    testDispatchLocalSpscBlock();
    testDispatchLocalSpscDrop();
    testDirectLocalSpscBlock();
    testDirectLocalSpscInvalidConfig();
    testInvalidConfigs();
    std::cout << "all pipeline tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << "\n";
    return 1;
  }
}
