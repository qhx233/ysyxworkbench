#include <am.h>

#define RTC_ADDR 0x0200bff8u

void __am_timer_init() {
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  uint32_t hi1, hi2, lo;
  do {
    hi1 = *(volatile uint32_t *)(RTC_ADDR + 4);
    lo  = *(volatile uint32_t *)(RTC_ADDR);
    hi2 = *(volatile uint32_t *)(RTC_ADDR + 4);
  } while (hi1 != hi2);
  uptime->us = ((uint64_t)hi1 << 32) | lo;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour   = 0;
  rtc->day    = 0;
  rtc->month  = 0;
  rtc->year   = 1900;
}
