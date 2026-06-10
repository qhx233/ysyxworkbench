/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <memory/host.h>
#include <memory/paddr.h>
#include <device/mmio.h>
#include <isa.h>

#if   defined(CONFIG_PMEM_MALLOC)
static uint8_t *pmem = NULL;
#else // CONFIG_PMEM_GARRAY
static uint8_t pmem[CONFIG_MSIZE] PG_ALIGN = {};
#endif

#define MROM_BASE 0x20000000u
#define MROM_SIZE 0x1000u
#define SRAM_BASE 0x0f000000u
#define SRAM_SIZE 0x2000u

static uint8_t mrom[MROM_SIZE] PG_ALIGN = {};
static uint8_t sram[SRAM_SIZE] PG_ALIGN = {};

static inline bool in_range(paddr_t addr, paddr_t base, paddr_t size) {
  return addr - base < size;
}

static inline bool in_mrom(paddr_t addr) {
  return in_range(addr, MROM_BASE, MROM_SIZE);
}

static inline bool in_sram(paddr_t addr) {
  return in_range(addr, SRAM_BASE, SRAM_SIZE);
}

uint8_t* guest_to_host(paddr_t paddr) {
  if (likely(in_pmem(paddr))) return pmem + paddr - CONFIG_MBASE;
  if (in_mrom(paddr)) return mrom + paddr - MROM_BASE;
  if (in_sram(paddr)) return sram + paddr - SRAM_BASE;
  panic("address = " FMT_PADDR " can not be converted to host address", paddr);
}

paddr_t host_to_guest(uint8_t *haddr) {
  if (haddr >= pmem && haddr < pmem + CONFIG_MSIZE) return haddr - pmem + CONFIG_MBASE;
  if (haddr >= mrom && haddr < mrom + MROM_SIZE) return haddr - mrom + MROM_BASE;
  if (haddr >= sram && haddr < sram + SRAM_SIZE) return haddr - sram + SRAM_BASE;
  panic("host address %p can not be converted to guest address", haddr);
}

static word_t pmem_read(paddr_t addr, int len) {
  word_t ret = host_read(guest_to_host(addr), len);
  return ret;
}

static void pmem_write(paddr_t addr, int len, word_t data) {
  host_write(guest_to_host(addr), len, data);
}

static void out_of_bound(paddr_t addr) {
  panic("address = " FMT_PADDR " is out of bound of pmem [" FMT_PADDR ", " FMT_PADDR "] at pc = " FMT_WORD,
      addr, PMEM_LEFT, PMEM_RIGHT, cpu.pc);
}

void init_mem() {
#if   defined(CONFIG_PMEM_MALLOC)
  pmem = malloc(CONFIG_MSIZE);
  assert(pmem);
#endif
  IFDEF(CONFIG_MEM_RANDOM, memset(pmem, rand(), CONFIG_MSIZE));
  Log("physical memory area [" FMT_PADDR ", " FMT_PADDR "]", PMEM_LEFT, PMEM_RIGHT);
  Log("mrom area [0x%08x, 0x%08x]", MROM_BASE, MROM_BASE + MROM_SIZE - 1);
  Log("sram area [0x%08x, 0x%08x]", SRAM_BASE, SRAM_BASE + SRAM_SIZE - 1);
}

word_t paddr_read(paddr_t addr, int len) {
  if (likely(in_pmem(addr)) || in_mrom(addr) || in_sram(addr)) {
    word_t data = pmem_read(addr, len);
  #ifdef CONFIG_MTRACE
    if (addr >= CONFIG_MTRACE_START_ADDR && addr <= CONFIG_MTRACE_END_ADDR) {
      Log("Read  | addr: " FMT_PADDR " | len: %d | data: " FMT_WORD, addr, len, data);
    }
  #endif
    return data;
  }
  IFDEF(CONFIG_DEVICE, return mmio_read(addr, len));
  out_of_bound(addr);
  return 0;
}

void paddr_write(paddr_t addr, int len, word_t data) {
 /*if (unlikely(in_mrom(addr))) {
    panic("NEMU Assertion failed: CPU trying to write to MROM at " FMT_PADDR " at pc = " FMT_WORD, addr, cpu.pc);
  }*/

  if (likely(in_pmem(addr)) || in_sram(addr)) { 
    pmem_write(addr, len, data); 
#ifdef CONFIG_MTRACE
    if (addr >= CONFIG_MTRACE_START_ADDR && addr <= CONFIG_MTRACE_END_ADDR) {
      Log("Write | addr: " FMT_PADDR " | len: %d | data: " FMT_WORD, addr, len, data);
    }
#endif
    return; 
  }
  IFDEF(CONFIG_DEVICE, mmio_write(addr, len, data); return);
  out_of_bound(addr);
}
