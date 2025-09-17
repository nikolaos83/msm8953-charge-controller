#!/usr/bin/env python3
import curses, time

BATPATH = "/sys/class/power_supply/qcom-battery"

def readfile(name):
    with open(f"{BATPATH}/{name}") as f:
        return f.read().strip()

def main(stdscr):
    curses.curs_set(0)
    while True:
        stdscr.clear()
        V = int(readfile("voltage_now")) / 1e6
        I = int(readfile("current_now")) / 1e3
        C = readfile("capacity")
        S = readfile("status")
        stdscr.addstr(0, 0, f"🔋 Battery Monitor")
        stdscr.addstr(2, 0, f"Voltage: {V:.3f} V")
        stdscr.addstr(3, 0, f"Current: {I:.0f} mA")
        stdscr.addstr(4, 0, f"Status : {S}")
        stdscr.addstr(5, 0, f"Capacity: {C}%")
        stdscr.refresh()
        time.sleep(1)

curses.wrapper(main)
