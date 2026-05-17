#include "BPlusTree.h"

#include "InputParser.h"

#include <algorithm>
#include <stdexcept>

namespace {

const Entry NO_SPLIT{-1, -1};

bool isNoSplit(const Entry &entry) {
    return entry.key == NO_SPLIT.key && entry.value == NO_SPLIT.value;
}

void sortEntries(std::vector<Entry> &entries) {
    std::sort(entries.begin(), entries.end(), [](const Entry &lhs, const Entry &rhs) {
        if (lhs.key != rhs.key) {
            return lhs.key < rhs.key;
        }
        return lhs.value < rhs.value;
    });
}

} // namespace

BPlusTree::~BPlusTree() {
    if (binFile_.is_open()) {
        binFile_.close();
    }
}

void BPlusTree::getMetadata(const char *fileName) {
    binFile_.open(fileName, std::ios::binary | std::ios::out | std::ios::in);
    if (!binFile_) {
        throw std::runtime_error("failed to open index file");
    }

    blockSize_ = readInt();
    rootBID_ = readInt();
    depth_ = readInt();

    capacity_ = (blockSize_ - UNIT) / (2 * UNIT);
    if (capacity_ <= 0) {
        throw std::runtime_error("invalid block size");
    }

    binFile_.seekg(0, std::ios::end);
    const std::streamoff fileSize = binFile_.tellg();
    numOfNodes_ = static_cast<int>((fileSize - HEADER_SIZE) / blockSize_);
}

Path BPlusTree::getPath(int key) {
    Path path;
    int current = rootBID_;

    for (int level = 0; level <= depth_; ++level) {
        path.nodes.emplace_back(current);
        if (level == depth_) {
            break;
        }

        const InternalNode node = readInternal(current);
        current = node.firstChild;
        for (const Entry &separator: node.separators) {
            if (separator.key > key) {
                break;
            }
            current = separator.value;
        }
    }

    path.dest = current;
    return path;
}

void BPlusTree::insert(Entry entry) {
    if (numOfNodes_ == 0) {
        insertEmpty(entry);
    } else if (numOfNodes_ == 1) {
        insertIntoOnlyOne(entry);
    } else {
        const Path path = getPath(entry.key);
        Entry promoted = insertLeaf(entry, path.nodes.back());

        for (size_t i = path.nodes.size() - 1; i > 0 && !isNoSplit(promoted); --i) {
            promoted = propagate(promoted, path.nodes[i - 1]);
        }
    }

    writeMetadata();
}

int BPlusTree::search(int key) {
    if (numOfNodes_ == 0) {
        return -1;
    }

    const int leafId = getPath(key).dest;
    const LeafNode leaf = readLeaf(leafId);
    for (const Entry &entry: leaf.entries) {
        if (entry.key == key) {
            return entry.value;
        }
    }

    return -1;
}

std::vector<Entry> BPlusTree::rangeSearch(int first, int last) {
    std::vector<Entry> entries;
    if (numOfNodes_ == 0) {
        return entries;
    }

    int leafId = getPath(first).dest;
    while (leafId != 0) {
        const LeafNode leaf = readLeaf(leafId);
        for (const Entry &entry: leaf.entries) {
            if (entry.key > last) {
                return entries;
            }
            if (entry.key >= first) {
                entries.emplace_back(entry);
            }
        }
        leafId = leaf.next;
    }

    return entries;
}

void BPlusTree::print(const char *fileName) {
    std::ofstream outFile(fileName);
    outFile << "<0>\n\n";

    if (numOfNodes_ == 0) {
        outFile << "\n<1>\n\n";
        return;
    }

    std::vector<int> levelZeroKeys;
    std::vector<int> levelOneKeys;

    if (depth_ == 0) {
        const LeafNode root = readLeaf(rootBID_);
        for (const Entry &entry: root.entries) {
            levelZeroKeys.emplace_back(entry.key);
        }
    } else {
        const InternalNode root = readInternal(rootBID_);
        std::vector<int> children{root.firstChild};
        for (const Entry &separator: root.separators) {
            levelZeroKeys.emplace_back(separator.key);
            children.emplace_back(separator.value);
        }

        for (int childId: children) {
            if (depth_ == 1) {
                const LeafNode leaf = readLeaf(childId);
                for (const Entry &entry: leaf.entries) {
                    levelOneKeys.emplace_back(entry.key);
                }
            } else {
                const InternalNode node = readInternal(childId);
                for (const Entry &separator: node.separators) {
                    levelOneKeys.emplace_back(separator.key);
                }
            }
        }
    }

    writeCsv(outFile, levelZeroKeys);
    outFile << "\n<1>\n\n";
    writeCsv(outFile, levelOneKeys);
}

std::streamoff BPlusTree::blockOffset(int blockId) const {
    return HEADER_SIZE + static_cast<std::streamoff>(blockId - 1) * blockSize_;
}

int BPlusTree::splitIndex() const {
    return (capacity_ - 1) / 2 + 1;
}

int BPlusTree::readInt() {
    int value = 0;
    binFile_.read(reinterpret_cast<char *>(&value), UNIT);
    return value;
}

void BPlusTree::writeInt(int value) {
    binFile_.write(reinterpret_cast<const char *>(&value), UNIT);
}

void BPlusTree::seekRead(std::streamoff offset) {
    binFile_.seekg(offset, std::ios::beg);
}

void BPlusTree::seekWrite(std::streamoff offset) {
    binFile_.seekp(offset, std::ios::beg);
}

LeafNode BPlusTree::readLeaf(int blockId) {
    LeafNode node;
    seekRead(blockOffset(blockId));

    for (int i = 0; i < capacity_; ++i) {
        Entry entry{readInt(), readInt()};
        if (entry.key != 0) {
            node.entries.emplace_back(entry);
        }
    }
    node.next = readInt();

    return node;
}

InternalNode BPlusTree::readInternal(int blockId) {
    InternalNode node;
    seekRead(blockOffset(blockId));
    node.firstChild = readInt();

    for (int i = 0; i < capacity_; ++i) {
        Entry separator{readInt(), readInt()};
        if (separator.key == 0) {
            break;
        }
        node.separators.emplace_back(separator);
    }

    return node;
}

void BPlusTree::writeLeaf(int blockId, const std::vector<Entry> &entries, int next) {
    const int dummy = 0;
    seekWrite(blockOffset(blockId));

    for (const Entry &entry: entries) {
        writeInt(entry.key);
        writeInt(entry.value);
    }
    for (int i = static_cast<int>(entries.size()); i < capacity_; ++i) {
        writeInt(dummy);
        writeInt(dummy);
    }
    writeInt(next);
}

void BPlusTree::writeInternal(int blockId, int firstChild, const std::vector<Entry> &separators) {
    const int dummy = 0;
    seekWrite(blockOffset(blockId));
    writeInt(firstChild);

    for (const Entry &separator: separators) {
        writeInt(separator.key);
        writeInt(separator.value);
    }
    for (int i = static_cast<int>(separators.size()); i < capacity_; ++i) {
        writeInt(dummy);
        writeInt(dummy);
    }
}

void BPlusTree::insertEmpty(Entry entry) {
    numOfNodes_ = 1;
    rootBID_ = 1;
    writeLeaf(rootBID_, {entry}, 0);
}

void BPlusTree::insertIntoOnlyOne(Entry entry) {
    LeafNode root = readLeaf(rootBID_);
    root.entries.emplace_back(entry);
    sortEntries(root.entries);

    if (static_cast<int>(root.entries.size()) <= capacity_) {
        writeLeaf(rootBID_, root.entries, root.next);
        return;
    }

    const int mid = splitIndex();
    const std::vector<Entry> left(root.entries.begin(), root.entries.begin() + mid);
    const std::vector<Entry> right(root.entries.begin() + mid, root.entries.end());

    const int leftId = rootBID_;
    const int rightId = ++numOfNodes_;
    const int newRootId = ++numOfNodes_;

    writeLeaf(leftId, left, rightId);
    writeLeaf(rightId, right, 0);
    writeInternal(newRootId, leftId, {{right.front().key, rightId}});

    rootBID_ = newRootId;
    ++depth_;
}

Entry BPlusTree::insertLeaf(Entry entry, int blockId) {
    LeafNode leaf = readLeaf(blockId);
    leaf.entries.emplace_back(entry);
    sortEntries(leaf.entries);

    if (static_cast<int>(leaf.entries.size()) <= capacity_) {
        writeLeaf(blockId, leaf.entries, leaf.next);
        return NO_SPLIT;
    }

    const int mid = splitIndex();
    const std::vector<Entry> left(leaf.entries.begin(), leaf.entries.begin() + mid);
    const std::vector<Entry> right(leaf.entries.begin() + mid, leaf.entries.end());
    const int newBlockId = ++numOfNodes_;

    writeLeaf(blockId, left, newBlockId);
    writeLeaf(newBlockId, right, leaf.next);

    return {right.front().key, newBlockId};
}

Entry BPlusTree::propagate(Entry entry, int blockId) {
    InternalNode node = readInternal(blockId);
    node.separators.emplace_back(entry);
    sortEntries(node.separators);

    if (static_cast<int>(node.separators.size()) <= capacity_) {
        writeInternal(blockId, node.firstChild, node.separators);
        return NO_SPLIT;
    }

    const int mid = splitIndex();
    const std::vector<Entry> left(node.separators.begin(), node.separators.begin() + mid);
    const std::vector<Entry> right(node.separators.begin() + mid + 1, node.separators.end());

    const int promotedKey = node.separators[mid].key;
    const int rightFirstChild = node.separators[mid].value;
    const int newBlockId = ++numOfNodes_;

    writeInternal(blockId, node.firstChild, left);
    writeInternal(newBlockId, rightFirstChild, right);

    if (blockId == rootBID_) {
        const int oldRootId = blockId;
        const int newRootId = ++numOfNodes_;
        writeInternal(newRootId, oldRootId, {{promotedKey, newBlockId}});

        rootBID_ = newRootId;
        ++depth_;
        return NO_SPLIT;
    }

    return {promotedKey, newBlockId};
}

void BPlusTree::writeMetadata() {
    seekWrite(UNIT);
    writeInt(rootBID_);
    writeInt(depth_);
}
