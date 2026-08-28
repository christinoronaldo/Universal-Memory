"""
Cocotb testbench for tt_um_universal_memory
Project     : Universal Memory Cell Development (Hybrid Persistent-RAM)
Phase       : Day 2, Step 4 - Verification & Testbench Generation

Pin mapping (per RTL):
    ui_in[7:0]   = write data payload
    uio_in[4:0]  = address (5-bit, 0-31)
    uio_in[5]    = WE   (write enable, active-high)
    uio_in[6]    = CE   (chip enable / strobe, active-high)
    uio_in[7]    = PERSIST
    uo_out[7:0]  = registered read data (1-cycle latency after CE+addr)

Timing model implemented by the RTL that this testbench respects:
    - Write:  synchronous, captured on posedge clk when
              ena & CE & WE & (addr match) are all true that cycle.
    - Read:   registered - the combinational mux output (mem[addr])
              is captured into uo_out on the *next* posedge clk after
              CE + address are applied (with ena high). WE does not
              need to be low to read; a simultaneous write to the same
              address returns the OLD value that cycle (standard
              write-first-old-read-data register-file behavior).
    - Reset:  asynchronous, sensitive to negedge rst_n. PERSIST is
              sampled at the instant rst_n drops:
                  !rst_n & !persist -> full array + output register clear
                  !rst_n &  persist -> array and output register HOLD
                  rst_n             -> normal synchronous operation
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

CLK_PERIOD_NS = 10  # 100 MHz


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _pack_uio(addr=0, we=0, ce=0, persist=0):
    """Pack the control/address fields into the uio_in byte layout."""
    return ((persist & 0x1) << 7) | ((ce & 0x1) << 6) | ((we & 0x1) << 5) | (addr & 0x1F)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def apply_reset(dut, persist=0, cycles=2):
    """Synchronous-style startup reset (rst_n low for a few clean cycles).
    Used for bring-up only; the dedicated persistence tests drive rst_n
    directly with Timer() delays to exercise the true asynchronous path.
    """
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = _pack_uio(addr=0, we=0, ce=0, persist=persist)
    dut.rst_n.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def write_byte(dut, addr, data, persist=0):
    """Drive one synchronous write cycle: addr/data/WE/CE set up, then
    captured on the following posedge clk."""
    dut.ui_in.value = data
    dut.uio_in.value = _pack_uio(addr=addr, we=1, ce=1, persist=persist)
    await RisingEdge(dut.clk)
    # De-assert WE/CE so nothing further latches while we settle/inspect.
    dut.uio_in.value = _pack_uio(addr=addr, we=0, ce=0, persist=persist)
    await Timer(1, units="ns")


async def read_byte(dut, addr, persist=0):
    """Drive one registered read cycle: CE+addr applied for one posedge,
    then uo_out is sampled once the NBA update has settled."""
    dut.uio_in.value = _pack_uio(addr=addr, we=0, ce=1, persist=persist)
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")  # let the NBA-updated register settle
    value = int(dut.uo_out.value)
    dut.uio_in.value = _pack_uio(addr=addr, we=0, ce=0, persist=persist)
    return value


async def async_reset_pulse(dut, persist, low_ns=25, high_settle_ns=25):
    """Assert an *asynchronous* reset pulse (not clock-aligned), holding
    PERSIST at the requested level across the entire pulse, matching the
    RTL's negedge-rst_n-sensitive always block."""
    dut.uio_in.value = _pack_uio(addr=0, we=0, ce=0, persist=persist)
    dut.rst_n.value = 0
    await Timer(low_ns, units="ns")
    dut.rst_n.value = 1
    await Timer(high_settle_ns, units="ns")
    # Let the design see a couple of clean clock edges post-reset.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------
# 1. System Initialization
# ---------------------------------------------------------------------

@cocotb.test()
async def test_system_initialization(dut):
    """Assert rst_n, start the clock, enable ena, confirm default output."""
    await start_clock(dut)

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = _pack_uio(addr=0, we=0, ce=0, persist=0)
    dut.rst_n.value = 0

    await Timer(20, units="ns")
    assert dut.uio_oe.value == 0, "uio_oe must be all-input (8'b00000000)"

    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")

    assert int(dut.uo_out.value) == 0x00, (
        f"Expected default uo_out == 0x00 after reset, got "
        f"0x{int(dut.uo_out.value):02X}"
    )
    dut._log.info("Initialization OK: rst_n asserted/released, uo_out defaults to 0x00")


# ---------------------------------------------------------------------
# 2. Single & Sequential Read/Write
# ---------------------------------------------------------------------

@cocotb.test()
async def test_single_and_sequential_read_write(dut):
    """Write distinct bytes to multiple addresses and verify 1-cycle
    registered readback accuracy, both individually and in sequence."""
    await start_clock(dut)
    await apply_reset(dut, persist=0)

    vectors = [
        (0, 0xAA),
        (15, 0x55),
        (31, 0xFF),
    ]

    # --- Single write/read pairs ---
    for addr, data in vectors:
        await write_byte(dut, addr, data)
        readback = await read_byte(dut, addr)
        assert readback == data, (
            f"Addr {addr}: wrote 0x{data:02X}, read back 0x{readback:02X}"
        )
        dut._log.info(f"Single R/W OK: addr={addr} data=0x{data:02X}")

    # --- Sequential: write all three back-to-back, then read all three
    #     back-to-back, confirming no cross-address corruption. ---
    for addr, data in vectors:
        await write_byte(dut, addr, data)

    for addr, expected in vectors:
        readback = await read_byte(dut, addr)
        assert readback == expected, (
            f"Sequential readback mismatch at addr {addr}: "
            f"expected 0x{expected:02X}, got 0x{readback:02X}"
        )
    dut._log.info("Sequential R/W OK across addresses 0, 15, 31")

    # --- Extra coverage: a pseudo-random sweep across all 32 addresses ---
    random.seed(42)
    sweep = {addr: random.randint(0, 255) for addr in range(32)}
    for addr, data in sweep.items():
        await write_byte(dut, addr, data)
    for addr, expected in sweep.items():
        readback = await read_byte(dut, addr)
        assert readback == expected, (
            f"Sweep mismatch at addr {addr}: expected 0x{expected:02X}, "
            f"got 0x{readback:02X}"
        )
    dut._log.info("Full 32-address sweep OK")


# ---------------------------------------------------------------------
# 3. Non-Volatile Persistence Mode Test
# ---------------------------------------------------------------------

@cocotb.test()
async def test_persistence_mode_retains_data(dut):
    """Write to addr 10 with PERSIST=0, then assert PERSIST=1 and pulse
    the async reset; confirm the byte survives the reset."""
    await start_clock(dut)
    await apply_reset(dut, persist=0)

    addr = 10
    payload = 0xC3

    # Write the payload with PERSIST de-asserted (persist only matters
    # at the moment of reset, so this reflects the spec's write step).
    await write_byte(dut, addr, payload, persist=0)

    readback_before = await read_byte(dut, addr, persist=0)
    assert readback_before == payload, (
        f"Pre-reset sanity check failed: expected 0x{payload:02X}, "
        f"got 0x{readback_before:02X}"
    )

    # Now assert PERSIST and pulse the asynchronous reset across it.
    await async_reset_pulse(dut, persist=1)

    readback_after = await read_byte(dut, addr, persist=1)
    assert readback_after == payload, (
        f"Persistence FAILED: expected retained 0x{payload:02X} at "
        f"addr {addr} after PERSIST reset pulse, got 0x{readback_after:02X}"
    )
    dut._log.info(
        f"Persistence OK: addr {addr} retained 0x{payload:02X} across "
        f"async reset with PERSIST=1"
    )


# ---------------------------------------------------------------------
# 4. Volatile Default Clear Test
# ---------------------------------------------------------------------

@cocotb.test()
async def test_volatile_clear_without_persist(dut):
    """With PERSIST=0, pulse rst_n and confirm the array clears back to
    default (0x00) rather than retaining prior contents."""
    await start_clock(dut)
    await apply_reset(dut, persist=0)

    addr = 10
    payload = 0x7E

    await write_byte(dut, addr, payload, persist=0)
    readback_before = await read_byte(dut, addr, persist=0)
    assert readback_before == payload, (
        f"Pre-reset sanity check failed: expected 0x{payload:02X}, "
        f"got 0x{readback_before:02X}"
    )

    # Pulse reset with PERSIST held LOW -> full volatile clear.
    await async_reset_pulse(dut, persist=0)

    readback_after = await read_byte(dut, addr, persist=0)
    assert readback_after == 0x00, (
        f"Volatile clear FAILED: expected 0x00 at addr {addr} after "
        f"PERSIST=0 reset pulse, got 0x{readback_after:02X}"
    )
    dut._log.info(
        f"Volatile clear OK: addr {addr} cleared to 0x00 after async "
        f"reset with PERSIST=0"
    )


# ---------------------------------------------------------------------
# 5. Bonus: chip-enable / ena gating sanity check
# ---------------------------------------------------------------------

@cocotb.test()
async def test_ce_and_ena_gating(dut):
    """Writes must not occur when CE=0 or ena=0, even if WE=1."""
    await start_clock(dut)
    await apply_reset(dut, persist=0)

    addr = 5
    baseline = 0x11
    blocked = 0x99

    await write_byte(dut, addr, baseline)
    assert (await read_byte(dut, addr)) == baseline

    # Attempt a write with CE de-asserted: should be ignored.
    dut.ui_in.value = blocked
    dut.uio_in.value = _pack_uio(addr=addr, we=1, ce=0, persist=0)
    await RisingEdge(dut.clk)
    dut.uio_in.value = _pack_uio(addr=addr, we=0, ce=0, persist=0)
    await Timer(1, units="ns")

    readback = await read_byte(dut, addr)
    assert readback == baseline, (
        f"CE-gating FAILED: write with CE=0 leaked through "
        f"(expected 0x{baseline:02X}, got 0x{readback:02X})"
    )

    # Attempt a write with ena de-asserted: should also be ignored.
    dut.ena.value = 0
    dut.ui_in.value = blocked
    dut.uio_in.value = _pack_uio(addr=addr, we=1, ce=1, persist=0)
    await RisingEdge(dut.clk)
    dut.uio_in.value = _pack_uio(addr=addr, we=0, ce=0, persist=0)
    await Timer(1, units="ns")
    dut.ena.value = 1

    readback = await read_byte(dut, addr)
    assert readback == baseline, (
        f"ena-gating FAILED: write with ena=0 leaked through "
        f"(expected 0x{baseline:02X}, got 0x{readback:02X})"
    )
    dut._log.info("CE/ena write-gating OK")
