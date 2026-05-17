#ifndef INDEX_FILE_TYPES_H
#define INDEX_FILE_TYPES_H

#include <vector>

constexpr int UNIT = 4;
constexpr int HEADER_UNITS = 3;
constexpr int HEADER_SIZE = HEADER_UNITS * UNIT;

static_assert(sizeof(int) == UNIT, "This file format expects 4-byte integers.");

struct Path {
    int dest = 0;
    std::vector<int> nodes;
};

struct Entry {
    int key = 0;
    int value = 0;
};

struct LeafNode {
    std::vector<Entry> entries;
    int next = 0;
};

struct InternalNode {
    int firstChild = 0;
    std::vector<Entry> separators; // key -> right child block id
};

#endif // INDEX_FILE_TYPES_H
