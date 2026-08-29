"""Boot and exercise production NW-MRC firmware through Grouper and Trouper."""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

HCLK_NS = 62.5
IQCLK_NS = 31.25
RAM_RESULT_WORD = 0xFF0 // 4
RESULT_PASS = 0x4E574D52


def lanes(dut):
    ram = dut.u_grouper.u_grouper_soc_dig_ss.u_ram_ss
    return [ram.gen_macro_ram.gen_sram[i].u_wrapper.u_sram_macro.mem for i in range(4)]


async def write_word(lane_mem, index, value):
    for byte_lane in range(4):
        lane_mem[byte_lane][index].value = (value >> (8 * byte_lane)) & 0xFF


async def read_word(lane_mem, index):
    return sum(int(lane_mem[i][index].value) << (8 * i) for i in range(4))


async def uart_byte(dut, value, bit_ns):
    dut.UART_RX.value = 0
    await Timer(bit_ns, unit="ns")
    for bit in range(8):
        dut.UART_RX.value = (value >> bit) & 1
        await Timer(bit_ns, unit="ns")
    dut.UART_RX.value = 1
    await Timer(bit_ns, unit="ns")


async def measure_uart_bit_ns(dut):
    tick = dut.u_grouper.u_grouper_soc_dig_ss.u_periph_ss.u_uart.u_uart.uart_clk_en
    times = []
    while len(times) < 9:
        await RisingEdge(tick)
        times.append(cocotb.utils.get_sim_time(unit="ns"))
    return sum(times[i + 1] - times[i] for i in range(8))


@cocotb.test()
async def test_grouper_trouper_nwmrc_e2e(dut):
    """Noise window -> real C EMA/SNRW -> packet Z -> active MRC combine."""
    cocotb.start_soon(Clock(dut.HCLK, HCLK_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.IQ_CLK, IQCLK_NS, unit="ns").start())
    dut.UART_RX.value = 1
    dut.host_cs.value = 1
    dut.spi_sck.value = 0
    dut.spi_mosi.value = 0
    dut.RESETB.value = 1
    await Timer(1, unit="ns")
    dut.RESETB.value = 0
    await Timer(123, unit="ns")
    await RisingEdge(dut.HCLK)
    dut.RESETB.value = 1
    await RisingEdge(dut.HCLK)

    lane_mem = lanes(dut)
    image = Path("firmware.bin").read_bytes()
    image += b"\0" * ((-len(image)) % 4)
    for word_index in range(len(image) // 4):
        await write_word(lane_mem, word_index,
                         int.from_bytes(image[4 * word_index:4 * word_index + 4], "little"))
    await write_word(lane_mem, RAM_RESULT_WORD, 0)
    await ClockCycles(dut.HCLK, 2)

    await FallingEdge(dut.UART_TX)
    await Timer(2, unit="ms")
    await uart_byte(dut, ord("B"), await measure_uart_bit_ns(dut))

    # A successful result means the actual firmware observed NOISE_READY,
    # accepted its sigma2 EMA, handled the subsequent TRAINING_DONE, and the
    # packet controller promoted W shadow to active W_VALID.
    for _ in range(80):
        result = await read_word(lane_mem, RAM_RESULT_WORD)
        if result == RESULT_PASS:
            break
        await Timer(200, unit="us")
    assert result == RESULT_PASS, f"NW-MRC firmware failed: result=0x{result:08X}"

    assert int(dut.u_trouper.W_valid.value), "firmware committed no active weights"
    assert any(int(getattr(dut.u_trouper.u_comb, name).value) != 0
               for name in ("W_re0", "W_re1", "W_re2", "W_re3")), \
        "NW-MRC committed an all-zero combiner vector"

    # Combiner must consume the committed vector on live IQ, not merely leave
    # W_VALID high.  Wait for one completed MAC burst after the commit.
    for _ in range(4096):
        await RisingEdge(dut.IQ_CLK)
        if int(dut.u_trouper.u_comb.y_valid.value):
            assert int(dut.u_trouper.u_comb.use_mrc_r.value), \
                "combiner produced bypass output instead of active NW-MRC"
            dut._log.info("PASS: production NW-MRC firmware drove active combiner output")
            return
    assert False, "no MRC combiner output after NW-MRC W_COMMIT"
