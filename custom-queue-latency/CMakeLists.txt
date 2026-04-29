cmake_minimum_required(VERSION 3.20)
project(custom_event_queue LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(CEQ_ENABLE_ASAN "Build with AddressSanitizer" OFF)
option(CEQ_ENABLE_TSAN "Build with ThreadSanitizer" OFF)

if (CEQ_ENABLE_ASAN AND CEQ_ENABLE_TSAN)
  message(FATAL_ERROR "ASan and TSan cannot be enabled together.")
endif()

add_library(custom_event_queue_sanitizers INTERFACE)

if (CEQ_ENABLE_ASAN)
  target_compile_options(custom_event_queue_sanitizers INTERFACE
    -fsanitize=address
    -fno-omit-frame-pointer
  )
  target_link_options(custom_event_queue_sanitizers INTERFACE
    -fsanitize=address
  )
endif()

if (CEQ_ENABLE_TSAN)
  target_compile_options(custom_event_queue_sanitizers INTERFACE
    -fsanitize=thread
    -fno-omit-frame-pointer
  )
  target_link_options(custom_event_queue_sanitizers INTERFACE
    -fsanitize=thread
  )
endif()

add_library(custom_event_queue_queues
  src/queues.cpp
)

target_include_directories(custom_event_queue_queues PUBLIC src)
target_link_libraries(custom_event_queue_queues PUBLIC custom_event_queue_sanitizers)

add_library(custom_event_queue_core
  src/harness.cpp
)

target_include_directories(custom_event_queue_core PUBLIC src)
target_link_libraries(custom_event_queue_core
  PUBLIC custom_event_queue_sanitizers
  PUBLIC custom_event_queue_queues
)

add_library(custom_event_pipeline_core
  src/pipeline.cpp
)

target_include_directories(custom_event_pipeline_core PUBLIC src)
target_link_libraries(custom_event_pipeline_core
  PUBLIC custom_event_queue_sanitizers
  PUBLIC custom_event_queue_queues
)

add_executable(custom_event_queue
  src/main.cpp
)

target_link_libraries(custom_event_queue PRIVATE custom_event_queue_core)

add_executable(custom_event_pipeline
  src/pipeline_main.cpp
)

target_link_libraries(custom_event_pipeline PRIVATE custom_event_pipeline_core)

enable_testing()

add_executable(custom_event_queue_tests
  tests/test_scenario.cpp
)

target_link_libraries(custom_event_queue_tests PRIVATE custom_event_queue_core)

add_test(NAME custom_event_queue_tests COMMAND custom_event_queue_tests)

add_executable(test_queue_strategies
  tests/test_queue_strategies.cpp
)

target_link_libraries(test_queue_strategies PRIVATE custom_event_queue_queues)

add_test(NAME test_queue_strategies COMMAND test_queue_strategies)

add_executable(test_pipeline
  tests/test_pipeline.cpp
)

target_link_libraries(test_pipeline PRIVATE custom_event_pipeline_core)

add_test(NAME test_pipeline COMMAND test_pipeline)
