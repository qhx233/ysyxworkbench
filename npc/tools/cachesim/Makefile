CXX ?= g++
CXXFLAGS ?= -O2 -Wall -Wextra -std=c++17

all: cachesim

cachesim: cachesim.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

clean:
	rm -f cachesim

.PHONY: all clean
