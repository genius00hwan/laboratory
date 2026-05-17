#include "InputParser.h"

#include <stdexcept>

Entry parseEntry(const std::string &line) {
    const size_t delimiter = line.find('|');
    if (delimiter == std::string::npos) {
        throw std::invalid_argument("invalid key/value input: " + line);
    }

    return {std::stoi(line.substr(0, delimiter)), std::stoi(line.substr(delimiter + 1))};
}

int parseSearchKey(const std::string &line) {
    if (line.empty()) {
        return 0;
    }
    return std::stoi(line);
}

std::pair<int, int> parseRange(const std::string &line) {
    const size_t delimiter = line.find('-');
    if (delimiter == std::string::npos) {
        throw std::invalid_argument("invalid range input: " + line);
    }

    return {std::stoi(line.substr(0, delimiter)), std::stoi(line.substr(delimiter + 1))};
}

void writeCsv(std::ofstream &outFile, const std::vector<int> &values) {
    for (size_t i = 0; i < values.size(); ++i) {
        if (i > 0) {
            outFile << ",";
        }
        outFile << values[i];
    }
    outFile << "\n";
}
