// Timing constraints for Hazard3 example SoC on Tang Nano 9K

// 27 MHz on-board oscillator (period = 1000/27 ≈ 37.037 ns)
create_clock -name clk_osc -period 37.037 -waveform {0 18.518} [get_ports {clk_osc}]

// JTAG TCK (10 MHz maximum)
create_clock -name tck -period 100 [get_ports {tck}]

// CPU / SoC PLL output clock (15 MHz = 27 MHz * 5 / 9)
create_generated_clock -name clk_sys_15m -source [get_ports {clk_osc}] -multiply_by 5 -divide_by 9 [get_pins {sys_pll_u/rpll_inst/CLKOUT}]

// PSRAM PLL output clocks (72 MHz = 27 MHz * 8 / 3)
create_generated_clock -name psram_clk_72m -source [get_ports {clk_osc}] -multiply_by 8 -divide_by 3 [get_pins {psram_pll_u/rpll_inst/CLKOUT}]
create_generated_clock -name psram_clk_p_72m -source [get_ports {clk_osc}] -multiply_by 8 -divide_by 3 [get_pins {psram_pll_u/rpll_inst/CLKOUTP}]

// These domains are asynchronous to each other.
set_clock_groups -asynchronous -group [get_clocks {clk_sys_15m}] -group [get_clocks {tck}] -group [get_clocks {psram_clk_72m psram_clk_p_72m}]

// LCD RGB/control registers update only on pixel_tick (every 8 psram clocks).
// Use frame_live_s0 (the DFF). frame_live* also matches LUTs (frame_live_s2)
// and Gowin TA2003 rejects those as multicycle endpoints.
set_multicycle_path 8 -setup -from [get_cells {lcd_psram_vram_u/h_ctr_* lcd_psram_vram_u/v_ctr_* lcd_psram_vram_u/frame_live_s0}] -to [get_cells {lcd_psram_vram_u/lcd_r_* lcd_psram_vram_u/lcd_g_* lcd_psram_vram_u/lcd_b_* lcd_psram_vram_u/lcd_de* lcd_psram_vram_u/lcd_hsync* lcd_psram_vram_u/lcd_vsync*}]
set_multicycle_path 7 -hold  -from [get_cells {lcd_psram_vram_u/h_ctr_* lcd_psram_vram_u/v_ctr_* lcd_psram_vram_u/frame_live_s0}] -to [get_cells {lcd_psram_vram_u/lcd_r_* lcd_psram_vram_u/lcd_g_* lcd_psram_vram_u/lcd_b_* lcd_psram_vram_u/lcd_de* lcd_psram_vram_u/lcd_hsync* lcd_psram_vram_u/lcd_vsync*}]

// Sprite beam / prep first-stage registers (only change with pixel_tick / line).
// Only name FF cells that exist after synthesis (no combo wildcards; no
// d_strip* — that table may be constant-folded when strips are forced solid).
set_multicycle_path 8 -setup -from [get_cells {lcd_psram_vram_u/h_ctr_* lcd_psram_vram_u/v_ctr_* lcd_psram_vram_u/frame_live_s0}] -to [get_cells {lcd_psram_vram_u/gen_sprite.sprite_u/prep_start_r* lcd_psram_vram_u/gen_sprite.sprite_u/prep_y_r* lcd_psram_vram_u/gen_sprite.sprite_u/ax_s0* lcd_psram_vram_u/gen_sprite.sprite_u/active_s0* lcd_psram_vram_u/gen_sprite.sprite_u/spr_act_s0*}]
set_multicycle_path 7 -hold  -from [get_cells {lcd_psram_vram_u/h_ctr_* lcd_psram_vram_u/v_ctr_* lcd_psram_vram_u/frame_live_s0}] -to [get_cells {lcd_psram_vram_u/gen_sprite.sprite_u/prep_start_r* lcd_psram_vram_u/gen_sprite.sprite_u/prep_y_r* lcd_psram_vram_u/gen_sprite.sprite_u/ax_s0* lcd_psram_vram_u/gen_sprite.sprite_u/active_s0* lcd_psram_vram_u/gen_sprite.sprite_u/spr_act_s0*}]
