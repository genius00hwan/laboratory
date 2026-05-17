CXX := g++
CXXFLAGS := -std=c++17 -Wall -Wextra -pedantic
TARGET := bptree
SRCS := b+tree.cpp BPlusTree.cpp InputParser.cpp

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CXX) $(CXXFLAGS) $(SRCS) -o $(TARGET)

clean:
	rm -f $(TARGET)
