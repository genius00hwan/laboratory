#ifndef INDEX_FILE_B_PLUS_TREE_H
#define INDEX_FILE_B_PLUS_TREE_H

#include "Types.h"

#include <fstream>
#include <ios>
#include <vector>

class BPlusTree {
public:
    BPlusTree() = default;
    ~BPlusTree();

    void getMetadata(const char *fileName);
    Path getPath(int key);
    void insert(Entry entry);
    int search(int key);
    std::vector<Entry> rangeSearch(int first, int last);
    void print(const char *fileName);

private:
    int blockSize_ = 0;
    int rootBID_ = 0;
    int depth_ = 0;
    int capacity_ = 0;
    int numOfNodes_ = 0;

    std::fstream binFile_;

    std::streamoff blockOffset(int blockId) const;
    int splitIndex() const;

    int readInt();
    void writeInt(int value);
    void seekRead(std::streamoff offset);
    void seekWrite(std::streamoff offset);

    LeafNode readLeaf(int blockId);
    InternalNode readInternal(int blockId);
    void writeLeaf(int blockId, const std::vector<Entry> &entries, int next);
    void writeInternal(int blockId, int firstChild, const std::vector<Entry> &separators);

    void insertEmpty(Entry entry);
    void insertIntoOnlyOne(Entry entry);
    Entry insertLeaf(Entry entry, int blockId);
    Entry propagate(Entry entry, int blockId);
    void writeMetadata();
};

#endif // INDEX_FILE_B_PLUS_TREE_H
