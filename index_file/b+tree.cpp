#include "BPlusTree.h"
#include "InputParser.h"
#include "Types.h"

#include <exception>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void createIndexFile(const char *fileName, int blockSize) {
    const int initialValue = 0;

    std::ofstream outFile(fileName, std::ios::binary);
    outFile.write(reinterpret_cast<const char *>(&blockSize), UNIT);
    outFile.write(reinterpret_cast<const char *>(&initialValue), UNIT);
    outFile.write(reinterpret_cast<const char *>(&initialValue), UNIT);
}

void insertEntries(const char *indexFile, const char *inputFile) {
    BPlusTree tree;
    tree.getMetadata(indexFile);

    std::ifstream inFile(inputFile);
    std::string line;
    while (std::getline(inFile, line)) {
        if (!line.empty()) {
            tree.insert(parseEntry(line));
        }
    }
}

void searchEntries(const char *indexFile, const char *inputFile, const char *outputFile) {
    BPlusTree tree;
    tree.getMetadata(indexFile);

    std::ifstream inFile(inputFile);
    std::ofstream outFile(outputFile);

    std::string line;
    while (std::getline(inFile, line)) {
        const int key = parseSearchKey(line);
        if (key != 0) {
            outFile << key << "|" << tree.search(key) << "\n";
        }
    }
}

void rangeSearchEntries(const char *indexFile, const char *inputFile, const char *outputFile) {
    BPlusTree tree;
    tree.getMetadata(indexFile);

    std::ifstream inFile(inputFile);
    std::ofstream outFile(outputFile);

    std::string line;
    while (std::getline(inFile, line)) {
        if (line.empty()) {
            continue;
        }

        const auto [first, last] = parseRange(line);
        const std::vector<Entry> entries = tree.rangeSearch(first, last);
        for (const Entry &entry: entries) {
            outFile << entry.key << "|" << entry.value << " ";
        }
        outFile << "\n";
    }
}

void printUsage() {
    std::cerr << "usage: b+tree <command> <index-file> [input-file] [output-file]\n";
}

} // namespace

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printUsage();
        return 1;
    }

    const char command = argv[1][0];
    const char *indexFile = argv[2];

    try {
        switch (command) {
            case 'c':
                if (argc < 4) {
                    throw std::invalid_argument("missing block size");
                }
                createIndexFile(indexFile, std::stoi(argv[3]));
                break;
            case 'i':
                if (argc < 4) {
                    throw std::invalid_argument("missing insertion input file");
                }
                insertEntries(indexFile, argv[3]);
                break;
            case 's':
                if (argc < 5) {
                    throw std::invalid_argument("missing search input or output file");
                }
                searchEntries(indexFile, argv[3], argv[4]);
                break;
            case 'r':
                if (argc < 5) {
                    throw std::invalid_argument("missing range input or output file");
                }
                rangeSearchEntries(indexFile, argv[3], argv[4]);
                break;
            case 'p':
                if (argc < 4) {
                    throw std::invalid_argument("missing print output file");
                }
                {
                    BPlusTree tree;
                    tree.getMetadata(indexFile);
                    tree.print(argv[3]);
                }
                break;
            default:
                throw std::invalid_argument("unknown command");
        }
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }

    return 0;
}
