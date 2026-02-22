cmake_minimum_required(VERSION 3.20)
project(custom_event_queue LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(custom_event_queue
  src/main.cpp
  src/harness.cpp
)

target_include_directories(custom_event_queue PRIVATE src)

