#include "queues.hpp"

#include <chrono>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

void expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

Event makeEvent(std::uint64_t id) {
  Event ev{};
  ev.id = id;
  ev.route_key = id;
  ev.created_at = EventClock::now();
  return ev;
}

void testFactoryAliases() {
  expect(parseQueueKind("global_lock") == QueueKind::GlobalLock, "global_lock alias parse failed");
  expect(parseQueueKind("mutex") == QueueKind::GlobalLock, "mutex alias parse failed");
  expect(parseQueueKind("split_lock") == QueueKind::SplitLockLinked, "split_lock alias parse failed");
  expect(parseQueueKind("twolock") == QueueKind::SplitLockLinked, "twolock alias parse failed");
  expect(parseQueueKind("mpmc_ring") == QueueKind::MpmcRing, "mpmc_ring alias parse failed");
  expect(parseQueueKind("spsc") == QueueKind::SpscRing, "spsc alias parse failed");
  expect(parseWaitStrategy("default") == WaitStrategy::QueueDefault, "default wait alias parse failed");
  expect(parseWaitStrategy("cv") == WaitStrategy::ConditionVariable, "cv wait alias parse failed");
  expect(parseWaitStrategy("spin_yield") == WaitStrategy::SpinYield, "spin_yield wait alias parse failed");
}

void testSequentialDropWhenFull(QueueKind kind) {
  std::atomic<bool> stop{false};
  auto queue = makeQueue(kind, 2);

  expect(queue->push(makeEvent(1), BackpressurePolicy::Drop, stop), "first push should succeed");
  expect(queue->push(makeEvent(2), BackpressurePolicy::Drop, stop), "second push should succeed");
  expect(!queue->push(makeEvent(3), BackpressurePolicy::Drop, stop), "third push should drop when queue is full");

  Event first{};
  Event second{};
  expect(queue->pop(first, stop), "first pop should succeed");
  expect(queue->pop(second, stop), "second pop should succeed");
  expect(first.id == 1, "FIFO order broken for first item");
  expect(second.id == 2, "FIFO order broken for second item");

  const auto stats = snapshotQueueStats(queue->stats());
  expect(stats.push_attempts == 3, "push attempts should track all offers");
  expect(stats.push_success == 2, "push success should track accepted offers");
  expect(stats.push_fail == 1, "push fail should track dropped offers");
  expect(stats.pop_success == 2, "pop success should track consumed items");
  expect(stats.full_hits >= 1, "full hit should be recorded on drop-full");
  expect(stats.max_observed_depth >= 2, "max observed depth should track queue occupancy");

  queue->close();
}

void testCloseUnblocksPop(QueueKind kind) {
  std::atomic<bool> stop{false};
  auto queue = makeQueue(kind, 8);

  bool pop_result = true;
  std::thread consumer([&] {
    Event ev{};
    pop_result = queue->pop(ev, stop);
  });

  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  queue->close();
  consumer.join();

  expect(!pop_result, "close() should unblock an empty pop");
}

void testBlockRoundTrip(QueueKind kind, std::size_t capacity, int item_count) {
  std::atomic<bool> stop{false};
  auto queue = makeQueue(kind, capacity);

  std::vector<std::uint64_t> consumed_ids;
  consumed_ids.reserve(static_cast<std::size_t>(item_count));
  std::exception_ptr thread_error;

  std::thread producer([&] {
    try {
      for (int i = 0; i < item_count; ++i) {
        const bool ok = queue->push(makeEvent(static_cast<std::uint64_t>(i)), BackpressurePolicy::Block, stop);
        expect(ok, "block push should not fail before close");
      }
    } catch (...) {
      thread_error = std::current_exception();
      stop.store(true, std::memory_order_relaxed);
      queue->close();
    }
  });

  std::thread consumer([&] {
    try {
      for (int i = 0; i < item_count; ++i) {
        Event ev{};
        const bool ok = queue->pop(ev, stop);
        expect(ok, "block pop should not fail before close");
        consumed_ids.push_back(ev.id);
      }
    } catch (...) {
      thread_error = std::current_exception();
      stop.store(true, std::memory_order_relaxed);
      queue->close();
    }
  });

  producer.join();
  consumer.join();
  queue->close();

  if (thread_error) {
    std::rethrow_exception(thread_error);
  }

  expect(static_cast<int>(consumed_ids.size()) == item_count, "all pushed items should be consumed");
  for (int i = 0; i < item_count; ++i) {
    expect(consumed_ids[static_cast<std::size_t>(i)] == static_cast<std::uint64_t>(i), "FIFO order broken in block run");
  }
}

void testSpscCapacityValidation() {
  try {
    (void)makeQueue(QueueKind::SpscRing, 0);
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error("spsc capacity=0 should throw");
}

} // namespace

int main() {
  try {
    testFactoryAliases();

    testSequentialDropWhenFull(QueueKind::GlobalLock);
    testSequentialDropWhenFull(QueueKind::SplitLockLinked);
    testSequentialDropWhenFull(QueueKind::MpmcRing);
    testSequentialDropWhenFull(QueueKind::SpscRing);

    testCloseUnblocksPop(QueueKind::GlobalLock);
    testCloseUnblocksPop(QueueKind::SplitLockLinked);
    testCloseUnblocksPop(QueueKind::MpmcRing);
    testCloseUnblocksPop(QueueKind::SpscRing);

    testBlockRoundTrip(QueueKind::GlobalLock, 8, 256);
    testBlockRoundTrip(QueueKind::SplitLockLinked, 8, 256);
    testBlockRoundTrip(QueueKind::MpmcRing, 8, 256);
    testBlockRoundTrip(QueueKind::SpscRing, 4, 4096);

    testSpscCapacityValidation();

    std::cout << "all queue strategy tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << "\n";
    return 1;
  }
}
