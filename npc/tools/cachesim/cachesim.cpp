#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#include <string>
#include <vector>

struct Options {
  uint32_t sets = 16;
  uint32_t ways = 1;
  uint32_t bus_bytes = 4;
  uint32_t line_transactions = 4;
  uint32_t line_size = 0;
  double access_time = 1.0;
  double miss_penalty = 0.0;
  double bus_penalty = 0.0;
  bool line_size_set = false;
  bool miss_penalty_set = false;
  std::string cache_region = "sdram";
  std::string repl = "fifo";
  std::string trace_path;
};

struct Line {
  bool valid = false;
  uint32_t tag = 0;
  uint64_t age = 0;
};

struct Stats {
  uint64_t accesses = 0;
  uint64_t cacheable = 0;
  uint64_t uncacheable = 0;
  uint64_t hits = 0;
  uint64_t misses = 0;
};

static bool is_pow2(uint32_t x) {
  return x != 0 && (x & (x - 1)) == 0;
}

static bool cacheable(uint32_t addr, const Options &opt) {
  if (opt.cache_region == "all") {
    return ((addr >> 28) == 0x3) || ((addr >> 29) == 0x4) || ((addr >> 29) == 0x5);
  }
  if (opt.cache_region == "flash") {
    return (addr >> 28) == 0x3;
  }
  if (opt.cache_region == "psram") {
    return (addr >> 29) == 0x4;
  }
  return (addr >> 29) == 0x5;
}

static bool parse_u32(const char *s, uint32_t *out) {
  char *end = nullptr;
  unsigned long v = strtoul(s, &end, 0);
  if (end == s || *end != '\0' || v > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  *out = static_cast<uint32_t>(v);
  return true;
}

static bool parse_double(const char *s, double *out) {
  char *end = nullptr;
  double v = strtod(s, &end);
  if (end == s || *end != '\0' || v < 0.0) {
    return false;
  }
  *out = v;
  return true;
}

static bool parse_pc_from_line(const std::string &line, uint32_t *pc) {
  std::istringstream iss(line);
  std::string tok;
  while (iss >> tok) {
    if (tok.back() == ':' || tok.back() == ',') {
      tok.pop_back();
    }
    uint32_t value = 0;
    if (parse_u32(tok.c_str(), &value)) {
      *pc = value;
      return true;
    }
  }
  return false;
}

static void usage(const char *prog) {
  std::fprintf(stderr,
      "Usage: %s [options] <pc-trace>\n"
      "Options:\n"
      "  --sets N          number of cache sets, default 16\n"
      "  --ways N          associativity, default 1\n"
      "  --bus-bytes N     bus data width in bytes, default 4\n"
      "  --line-transactions N\n"
      "                    independent bus transactions per fill, default 4\n"
      "  --line-size N     cache line bytes, default bus-bytes * line-transactions\n"
      "  --cache-region R  sdram|flash|psram|all, default sdram\n"
      "  --repl POLICY     fifo|lru|random, default fifo\n"
      "  --access-time N   AMAT cache access cycles, default 1\n"
      "  --bus-penalty N   cycles per independent bus transaction, default 0\n"
      "  --miss-penalty N  override total miss penalty cycles\n",
      prog);
}

static bool parse_args(int argc, char **argv, Options *opt) {
  for (int i = 1; i < argc; i++) {
    if (std::strcmp(argv[i], "--sets") == 0 && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opt->sets)) return false;
    } else if (std::strcmp(argv[i], "--ways") == 0 && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opt->ways)) return false;
    } else if (std::strcmp(argv[i], "--bus-bytes") == 0 && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opt->bus_bytes)) return false;
    } else if (std::strcmp(argv[i], "--line-transactions") == 0 && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opt->line_transactions)) return false;
    } else if (std::strcmp(argv[i], "--line-size") == 0 && i + 1 < argc) {
      if (!parse_u32(argv[++i], &opt->line_size)) return false;
      opt->line_size_set = true;
    } else if (std::strcmp(argv[i], "--cache-region") == 0 && i + 1 < argc) {
      opt->cache_region = argv[++i];
    } else if (std::strcmp(argv[i], "--access-time") == 0 && i + 1 < argc) {
      if (!parse_double(argv[++i], &opt->access_time)) return false;
    } else if (std::strcmp(argv[i], "--bus-penalty") == 0 && i + 1 < argc) {
      if (!parse_double(argv[++i], &opt->bus_penalty)) return false;
    } else if (std::strcmp(argv[i], "--miss-penalty") == 0 && i + 1 < argc) {
      if (!parse_double(argv[++i], &opt->miss_penalty)) return false;
      opt->miss_penalty_set = true;
    } else if (std::strcmp(argv[i], "--repl") == 0 && i + 1 < argc) {
      opt->repl = argv[++i];
    } else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      std::exit(0);
    } else if (opt->trace_path.empty()) {
      opt->trace_path = argv[i];
    } else {
      return false;
    }
  }

  if (!opt->line_size_set) {
    opt->line_size = opt->bus_bytes * opt->line_transactions;
  }
  if (!opt->miss_penalty_set) {
    uint32_t fill_transactions = (opt->line_size + opt->bus_bytes - 1) / opt->bus_bytes;
    opt->miss_penalty = (double)fill_transactions * opt->bus_penalty;
  }

  if (opt->trace_path.empty() || opt->sets == 0 || opt->ways == 0 ||
      opt->bus_bytes == 0 || opt->line_transactions == 0 || opt->line_size == 0 ||
      !is_pow2(opt->sets) || !is_pow2(opt->bus_bytes) || !is_pow2(opt->line_size)) {
    return false;
  }
  if (opt->repl != "fifo" && opt->repl != "lru" && opt->repl != "random") {
    return false;
  }
  if (opt->cache_region != "sdram" && opt->cache_region != "flash" &&
      opt->cache_region != "psram" && opt->cache_region != "all") {
    return false;
  }
  return true;
}

static void access_cache(std::vector<std::vector<Line>> &cache,
                         const Options &opt,
                         uint32_t pc,
                         uint64_t now,
                         std::mt19937 &rng,
                         Stats *stats) {
  stats->accesses++;
  if (!cacheable(pc, opt)) {
    stats->uncacheable++;
    stats->misses++;
    return;
  }

  stats->cacheable++;
  const uint32_t block = pc / opt.line_size;
  const uint32_t set = block % opt.sets;
  const uint32_t tag = block / opt.sets;

  for (auto &line : cache[set]) {
    if (line.valid && line.tag == tag) {
      stats->hits++;
      if (opt.repl == "lru") {
        line.age = now;
      }
      return;
    }
  }

  stats->misses++;
  uint32_t victim = 0;
  bool found_invalid = false;
  for (uint32_t way = 0; way < opt.ways; way++) {
    if (!cache[set][way].valid) {
      victim = way;
      found_invalid = true;
      break;
    }
  }

  if (!found_invalid) {
    if (opt.repl == "random") {
      std::uniform_int_distribution<uint32_t> dist(0, opt.ways - 1);
      victim = dist(rng);
    } else {
      uint64_t best_age = cache[set][0].age;
      for (uint32_t way = 1; way < opt.ways; way++) {
        if (cache[set][way].age < best_age) {
          best_age = cache[set][way].age;
          victim = way;
        }
      }
    }
  }

  cache[set][victim].valid = true;
  cache[set][victim].tag = tag;
  cache[set][victim].age = now;
}

int main(int argc, char **argv) {
  Options opt;
  if (!parse_args(argc, argv, &opt)) {
    usage(argv[0]);
    return 1;
  }

  std::ifstream in(opt.trace_path);
  if (!in) {
    std::perror(opt.trace_path.c_str());
    return 1;
  }

  std::vector<std::vector<Line>> cache(opt.sets, std::vector<Line>(opt.ways));
  std::mt19937 rng(0x23060000u);
  Stats stats;
  std::string line;
  uint64_t now = 0;

  while (std::getline(in, line)) {
    uint32_t pc = 0;
    if (!parse_pc_from_line(line, &pc)) {
      continue;
    }
    access_cache(cache, opt, pc, ++now, rng, &stats);
  }

  const double hit_rate = stats.accesses == 0 ? 0.0 : 100.0 * (double)stats.hits / (double)stats.accesses;
  const double miss_rate = stats.accesses == 0 ? 0.0 : (double)stats.misses / (double)stats.accesses;
  const double tmt = (double)stats.misses * opt.miss_penalty;
  const double amat = opt.access_time + miss_rate * opt.miss_penalty;

  std::printf("========== cachesim ==========\n");
  std::printf("sets          : %u\n", opt.sets);
  std::printf("ways          : %u\n", opt.ways);
  std::printf("bus bytes     : %u bytes\n", opt.bus_bytes);
  std::printf("fill txns     : %u\n", (opt.line_size + opt.bus_bytes - 1) / opt.bus_bytes);
  std::printf("line size     : %u bytes\n", opt.line_size);
  std::printf("cache region  : %s\n", opt.cache_region.c_str());
  std::printf("replacement   : %s\n", opt.repl.c_str());
  std::printf("accesses      : %llu\n", (unsigned long long)stats.accesses);
  std::printf("cacheable     : %llu\n", (unsigned long long)stats.cacheable);
  std::printf("uncacheable   : %llu\n", (unsigned long long)stats.uncacheable);
  std::printf("hits          : %llu\n", (unsigned long long)stats.hits);
  std::printf("misses        : %llu\n", (unsigned long long)stats.misses);
  std::printf("hit rate      : %.2f%%\n", hit_rate);
  std::printf("bus penalty   : %.3f cycles/txn\n", opt.bus_penalty);
  std::printf("miss penalty  : %.3f cycles\n", opt.miss_penalty);
  std::printf("TMT estimate  : %.3f cycles\n", tmt);
  std::printf("AMAT estimate : %.3f cycles/access\n", amat);
  return 0;
}
