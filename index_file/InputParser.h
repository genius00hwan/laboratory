#ifndef INDEX_FILE_INPUT_PARSER_H
#define INDEX_FILE_INPUT_PARSER_H

#include "Types.h"

#include <fstream>
#include <string>
#include <utility>
#include <vector>

Entry parseEntry(const std::string &line);
int parseSearchKey(const std::string &line);
std::pair<int, int> parseRange(const std::string &line);
void writeCsv(std::ofstream &outFile, const std::vector<int> &values);

#endif // INDEX_FILE_INPUT_PARSER_H
