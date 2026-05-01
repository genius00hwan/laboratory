#include "harness.hpp"

#include <iostream>
#include <functional>
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

ScenarioConfig makeBaseConfig(const std::string& queue_type) {
  ScenarioConfig config{};
  config.queue_type = queue_type;
  config.duration = std::chrono::seconds(1);
  config.warmup = std::chrono::seconds(0);
  config.producers = 1;
  config.consumers = 1;
  config.capacity = 128;
  config.rate_per_producer = 1000.0;
  config.policy = BackpressurePolicy::Block;
  return config;
}

void testBlockScenario(const std::string& queue_type) {
  auto config = makeBaseConfig(queue_type);
  const auto result = runScenario(config);

  expect(result.consumed > 0, queue_type + ": block 시나리오에서 소비가 발생해야 합니다.");
  expect(result.dropped == 0, queue_type + ": block 시나리오에서 drop이 없어야 합니다.");
  expect(result.produced == result.consumed, queue_type + ": block 시나리오에서 produced == consumed 여야 합니다.");
  expect(result.samples == result.consumed, queue_type + ": samples는 consumed와 같아야 합니다.");
}

void testSharedQueueDropScenario(const std::string& queue_type) {
  auto config = makeBaseConfig(queue_type);
  config.producers = 4;
  config.capacity = 8;
  config.rate_per_producer = 0.0;
  config.policy = BackpressurePolicy::Drop;

  const auto result = runScenario(config);

  expect(result.consumed > 0, queue_type + ": drop 시나리오에서도 일부 소비는 발생해야 합니다.");
  expect(result.dropped > 0, queue_type + ": 과부하 drop 시나리오에서는 drop이 발생해야 합니다.");
  expect(result.produced == result.consumed, queue_type + ": 종료 시점에 큐가 비워져 produced == consumed 여야 합니다.");
  expect(result.samples == result.consumed, queue_type + ": samples는 consumed와 같아야 합니다.");
}

void testSpscDropScenario() {
  auto config = makeBaseConfig("spsc");
  config.capacity = 8;
  config.rate_per_producer = 0.0;
  config.policy = BackpressurePolicy::Drop;

  const auto result = runScenario(config);

  expect(result.consumed > 0, "spsc: drop 시나리오에서도 일부 소비는 발생해야 합니다.");
  expect(result.dropped > 0, "spsc: 과부하 drop 시나리오에서는 drop이 발생해야 합니다.");
  expect(result.produced == result.consumed, "spsc: 종료 시점에 큐가 비워져 produced == consumed 여야 합니다.");
  expect(result.samples == result.consumed, "spsc: samples는 consumed와 같아야 합니다.");
}

void testSpscWrapAroundScenario() {
  auto config = makeBaseConfig("spsc");
  config.capacity = 4;
  config.rate_per_producer = 0.0;
  config.policy = BackpressurePolicy::Block;

  const auto result = runScenario(config);

  expect(result.consumed > 1000, "spsc: 작은 capacity에서도 wrap-around가 충분히 발생해야 합니다.");
  expect(result.dropped == 0, "spsc: block wrap-around 시나리오에서는 drop이 없어야 합니다.");
  expect(result.produced == result.consumed, "spsc: wrap-around 후에도 produced == consumed 여야 합니다.");
  expect(result.samples == result.consumed, "spsc: wrap-around 후에도 samples는 consumed와 같아야 합니다.");
}

void testSpscInvalidConfig() {
  expectThrows([] {
    auto config = makeBaseConfig("spsc");
    config.producers = 2;
    (void)runScenario(config);
  }, "spsc: producers != 1은 거절되어야 합니다.");

  expectThrows([] {
    auto config = makeBaseConfig("spsc");
    config.consumers = 2;
    (void)runScenario(config);
  }, "spsc: consumers != 1은 거절되어야 합니다.");

  expectThrows([] {
    auto config = makeBaseConfig("spsc");
    config.capacity = 0;
    (void)runScenario(config);
  }, "spsc: capacity == 0은 거절되어야 합니다.");
}

} // namespace

int main() {
  try {
    testBlockScenario("mutex");
    testBlockScenario("twolock");
    testBlockScenario("spsc");
    testSharedQueueDropScenario("mutex");
    testSharedQueueDropScenario("twolock");
    testSpscDropScenario();
    testSpscWrapAroundScenario();
    testSpscInvalidConfig();
    std::cout << "all scenario tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << "\n";
    return 1;
  }
}
