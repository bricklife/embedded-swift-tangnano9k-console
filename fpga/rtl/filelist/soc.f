# SoC integration file

file ../soc/tangnano9k_soc.v

# CPU + debug components

list $HDL/hazard3.f
list $HDL/debug/dtm/hazard3_jtag_dtm.f
list $HDL/debug/dm/hazard3_dm.f

# RISC-V timer

list ../soc/peri/hazard3_riscv_timer.f

# Generic SoC components from libfpga

file $LIBFPGA/common/reset_sync.v

list $LIBFPGA/peris/uart/uart.f
list $LIBFPGA/peris/spi_03h_xip/spi_03h_xip.f
list $LIBFPGA/mem/ahb_cache.f
list $LIBFPGA/mem/ahb_sync_sram.f

list $LIBFPGA/busfabric/ahbl_crossbar.f
file $LIBFPGA/busfabric/ahbl_to_apb.v
file $LIBFPGA/busfabric/apb_splitter.v
file ../soc/peri/apb_gpio_out.v
file ../soc/peri/apb_gpio_in.v
file ../soc/peri/apb_lcd_ctrl.v
file ../soc/peri/apb_sprite_ctrl.v
file ../soc/peri/apb_pwm_score.v
file ../soc/peri/ahb_sprite_mem.v
file ../soc/peri/ahb_vram_writer.v
