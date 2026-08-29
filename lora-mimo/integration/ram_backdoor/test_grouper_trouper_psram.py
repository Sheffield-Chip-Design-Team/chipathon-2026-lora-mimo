"""Real Grouper-SRAM-backdoor to Trouper-PSRAM debug-path integration test."""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

HCLK_NS = 62.5
IQCLK_NS = 31.25
SPI_HALF_NS = 50                 # 10 MHz Mode-0 host SPI
RAM_SOURCE_WORD = 0xF00 // 4
RAM_RESULT_WORD = 0xFF0 // 4
SOURCE = [0x47, 0x52, 0x50, 0x2D, 0x52, 0x41, 0x4D, 0x21]
RESULT_PASS = 0x5053524D


def lanes(dut):
    ram = dut.u_grouper.u_grouper_soc_dig_ss.u_ram_ss
    return [ram.gen_macro_ram.gen_sram[i].u_wrapper.u_sram_macro.mem for i in range(4)]


async def write_word(lane_mem, index, value):
    for byte_lane in range(4):
        lane_mem[byte_lane][index].value = (value >> (8 * byte_lane)) & 0xff


async def read_word(lane_mem, index):
    return sum(int(lane_mem[i][index].value) << (8 * i) for i in range(4))


async def measure_uart_bit_ns(dut):
    """Measure eight live uart_clk_en ticks (one UART bit) from the DUT."""
    tick = dut.u_grouper.u_grouper_soc_dig_ss.u_periph_ss.u_uart.u_uart.uart_clk_en
    times = []
    while len(times) < 9:
        await RisingEdge(tick)
        times.append(cocotb.utils.get_sim_time(unit="ns"))
    return sum(times[i + 1] - times[i] for i in range(8)) / 8.0 * 8.0


async def uart_byte(dut, value, bit_ns):
    dut.UART_RX.value = 0
    await Timer(bit_ns, unit="ns")
    for bit in range(8):
        dut.UART_RX.value = (value >> bit) & 1
        await Timer(bit_ns, unit="ns")
    dut.UART_RX.value = 1
    await Timer(bit_ns, unit="ns")


async def spi_byte(dut, value):
    """Shift one Mode-0, MSB-first byte and return MISO's received byte."""
    received = 0
    for bit in range(7, -1, -1):
        dut.spi_mosi.value = (value >> bit) & 1
        await Timer(SPI_HALF_NS, unit="ns")
        dut.spi_sck.value = 1
        await Timer(SPI_HALF_NS, unit="ns")
        received = (received << 1) | int(dut.spi_miso.value)
        dut.spi_sck.value = 0
    return received


async def spi_write(dut, address, value):
    dut.host_cs.value = 0
    await Timer(SPI_HALF_NS, unit="ns")
    await spi_byte(dut, address & 0x7f)
    await spi_byte(dut, value)
    await Timer(SPI_HALF_NS, unit="ns")
    dut.host_cs.value = 1
    await Timer(SPI_HALF_NS, unit="ns")


async def spi_read(dut, address):
    dut.host_cs.value = 0
    await Timer(SPI_HALF_NS, unit="ns")
    await spi_byte(dut, 0x80 | (address & 0x7f))
    value = await spi_byte(dut, 0)
    await Timer(SPI_HALF_NS, unit="ns")
    dut.host_cs.value = 1
    await Timer(SPI_HALF_NS, unit="ns")
    return value
    for bit in range(8):
        dut.UART_RX.value = (value >> bit) & 1
        await Timer(bit_ns, unit="ns")
    dut.UART_RX.value = 1
    await Timer(bit_ns, unit="ns")


async def measure_training_irq_to_commit(dut, stamps):
    """Timestamp the TRAINING_DONE IRQ assertion and its W_COMMIT response."""
    previous_irq = 0
    while "commit_ns" not in stamps:
        await RisingEdge(dut.IQ_CLK)
        await ReadOnly()
        irq = int(dut.irq_grouper.value)
        status = int(dut.u_trouper.u_rb.irq_status.value)
        now_ns = cocotb.utils.get_sim_time(unit="ns")
        if irq and not previous_irq and (status & 0x02):
            stamps.setdefault("irq_ns", now_ns)
        if "irq_ns" in stamps and int(dut.u_trouper.rb_w_commit_pulse.value):
            stamps["commit_ns"] = now_ns
        previous_irq = irq


async def overlap_host_spi_write(dut, stamps):
    """Launch a host write in the live TRAINING_DONE ISR window.

    COMB_CFG is deliberately unrelated to the firmware's Z reads and W-shadow
    writes.  Its readback is therefore an unambiguous proof that a completed
    SPI write survived Grouper's higher-priority traffic.
    """
    previous_irq = 0
    while True:
        await RisingEdge(dut.IQ_CLK)
        await ReadOnly()
        irq = int(dut.irq_grouper.value)
        status = int(dut.u_trouper.u_rb.irq_status.value)
        if irq and not previous_irq and (status & 0x02):
            stamps["spi_start_ns"] = cocotb.utils.get_sim_time(unit="ns")
            await Timer(1, unit="ps")
            await spi_write(dut, 0x0f, 0x13)
            stamps["spi_done_ns"] = cocotb.utils.get_sim_time(unit="ns")
            return
        previous_irq = irq


async def monitor_boot_uart(dut, stamps):
    """Record completed RX bytes and framing errors during ROM boot."""
    # ahb_uart.u_uart is the UART wrapper; its RX pulses are exported through
    # the surrounding Grouper digital subsystem.
    rx = dut.u_grouper.u_grouper_soc_dig_ss.u_periph_ss.u_uart.u_uart
    while "boot_uart_done" not in stamps:
        await RisingEdge(dut.HCLK)
        await ReadOnly()
        if int(rx.received.value):
            byte = int(rx.u_uart_rx.fifo_wdata.value)
            stamps.setdefault("boot_rx", []).append(byte)
            stamps["boot_uart_done"] = True
            dut._log.info("UART RX completed byte 0x%02x", byte)
        if int(rx.rx_frame_error.value):
            stamps["boot_frame_errors"] = stamps.get("boot_frame_errors", 0) + 1
            dut._log.warning("UART RX frame error at %.3f us",
                             cocotb.utils.get_sim_time(unit="ns") / 1000)


@cocotb.test()
async def test_grouper_ram_backdoor_to_psram(dut):
    stamps = {}
    cocotb.start_soon(Clock(dut.HCLK, HCLK_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.IQ_CLK, IQCLK_NS, unit="ns").start())
    cocotb.start_soon(measure_training_irq_to_commit(dut, stamps))
    cocotb.start_soon(overlap_host_spi_write(dut, stamps))
    cocotb.start_soon(monitor_boot_uart(dut, stamps))
    dut.UART_RX.value = 1
    dut.host_cs.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    # Match Grouper's established reset sequence: an initial asserted-to-
    # deasserted edge exercises the asynchronous-reset release synchronizer.
    dut.RESETB.value = 1
    await Timer(1, unit="ns")
    dut.RESETB.value = 0
    await Timer(123, unit="ns")
    await RisingEdge(dut.HCLK)
    dut.RESETB.value = 1
    await RisingEdge(dut.HCLK)

    # Exactly the macro-array backdoor used by Grouper's boot_preload test.
    # firmware.bin is the RAM-linked image built by this core's pre-build hook.
    lane_mem = lanes(dut)
    image = Path("firmware.bin").read_bytes()
    image += b"\0" * ((-len(image)) % 4)
    for word_index in range(len(image) // 4):
        await write_word(lane_mem, word_index,
                         int.from_bytes(image[4 * word_index:4 * word_index + 4], "little"))
    for byte_index, value in enumerate(SOURCE):
        word = await read_word(lane_mem, RAM_SOURCE_WORD + byte_index // 4)
        shift = 8 * (byte_index % 4)
        word = (word & ~(0xff << shift)) | (value << shift)
        await write_word(lane_mem, RAM_SOURCE_WORD + byte_index // 4, word)
    await write_word(lane_mem, RAM_RESULT_WORD, 0)
    await ClockCycles(dut.HCLK, 2)

    # The resident ROM bootloader owns the bank switch. Synchronize to its
    # first greeting-byte start bit instead of assuming a fixed boot latency,
    # then wait until the complete "hi\n" greeting has drained.
    await FallingEdge(dut.UART_TX)
    await Timer(2, unit="ms")
    bit_ns = await measure_uart_bit_ns(dut)
    dut._log.info("Measured UART bit period %.3f us", bit_ns / 1000)
    await uart_byte(dut, ord("B"), bit_ns)
    await Timer(200, unit="us")
    dut._log.info("UART boot diagnostics: %s", stamps)

    # Poll infrequently in simulation time: firmware only updates this word at
    # completion, and per-HCLK cocotb wakeups make a 50 ms timeout needlessly
    # slow under Verilator.
    for _ in range(50):
        if await read_word(lane_mem, RAM_RESULT_WORD) == RESULT_PASS:
            assert "irq_ns" in stamps and "commit_ns" in stamps, \
                f"missing latency endpoints: {stamps}"
            latency_ns = stamps["commit_ns"] - stamps["irq_ns"]
            assert latency_ns < 3_000_000, (
                f"IRQ_GROUPER -> W_COMMIT exceeded the 3 ms replay margin: "
                f"{latency_ns / 1000:.3f} us"
            )
            dut._log.info(
                "PASS: TRAINING_DONE IRQ_GROUPER -> W_COMMIT = %.3f us "
                "(%d IQ_CLK cycles)", latency_ns / 1000,
                round(latency_ns / IQCLK_NS)
            )
            assert "spi_done_ns" in stamps, (
                f"host SPI write did not overlap TRAINING_DONE service: {stamps}"
            )
            assert await spi_read(dut, 0x0f) == 0x13, (
                "completed host-SPI COMB_CFG write was lost during Grouper IRQ service"
            )
            assert stamps["spi_start_ns"] < stamps["commit_ns"], (
                f"host SPI did not start before W_COMMIT: {stamps}"
            )
            dut._log.info(
                "PASS: host-SPI write overlapped Grouper IRQ service and read back"
            )
            return
        await Timer(200, unit="us")
    result = await read_word(lane_mem, RAM_RESULT_WORD)
    bank_switch = int(dut.u_grouper.u_grouper_soc_dig_ss.u_cpu_ss.bank_switch.value)
    irq_status = int(dut.u_trouper.u_rb.irq_status.value)
    sc_lock = int(dut.u_trouper.sc_lock.value)
    training_done = int(dut.u_trouper.training_done.value)
    bus_error = int(dut.u_grouper.u_grouper_soc_dig_ss.u_cpu_ss.bus_error.value)
    bridge_state = int(dut.u_bridge.src_state.value)
    htrans = int(dut.htrans.value)
    haddr = int(dut.haddr.value)
    hready = int(dut.hready.value)
    assert False, (
        "firmware did not report IRQ service success "
        f"(result=0x{result:08X}, bank_switch={bank_switch}, "
        f"irq_status=0x{irq_status:02X}, sc_lock={sc_lock}, "
        f"training_done={training_done}, bus_error={bus_error}, "
        f"bridge_state={bridge_state}, htrans={htrans}, haddr=0x{haddr:02X}, hready={hready})"
    )
