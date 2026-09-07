# project.tcl -- Gowin EDA project script for Tang Nano 9K
#
# Usage (called from fpga/Makefile):
#   gw_sh project.tcl <device_family> <device_part> <project_name> \
#                     <cst_abs> <sdc_abs> <filelist_abs> [save-only]
#
# The Makefile generates <filelist_abs> containing:
#   set SRCS    { ... absolute Verilog source paths ... }
#   set INCDIRS { ... absolute include directory paths ... }
#
# Optional 7th argument "save-only": write fpga_tangnano9k.gprj (for Gowin EDA GUI)
# instead of running synthesis.

set device_family [lindex $argv 0]   ;# e.g. GW1NR-9C
set device_part   [lindex $argv 1]   ;# e.g. GW1NR-LV9QN88PC6/I5
set project_name  [lindex $argv 2]   ;# e.g. fpga_tangnano9k
set cst_file      [lindex $argv 3]   ;# absolute path to .cst
set sdc_file      [lindex $argv 4]   ;# absolute path to .sdc
set filelist      [lindex $argv 5]   ;# absolute path to filelist.tcl
set mode          [lindex $argv 6]   ;# optional: "save-only"

source $filelist   ;# defines $SRCS and $INCDIRS

set_option -output_base_name ${project_name}
set_device -name ${device_family} ${device_part}

set_option -verilog_std sysv2017
set_option -print_all_synthesis_warning 1
# place_option 2: 1 unrouted net at ~100% CLS.
# Thin FRAME: place 1 + route 1 is best for clk_sys (16.84 MHz). PSRAM is unmet.
set_option -place_option 1
set_option -route_option 1

set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1

foreach d $INCDIRS {
    if {$d ne ""} { set_option -include_path $d }
}

foreach f $SRCS {
    if {$f ne ""} { add_file -type verilog $f }
}

add_file -type cst $cst_file
add_file -type sdc $sdc_file

set_option -top_module ${project_name}

if {$mode eq "save-only"} {
    # Write a GUI project next to this script (fpga/fpga_tangnano9k.gprj).
    set gprj [file join [file dirname [info script]] ${project_name}.gprj]
    saveto $gprj
} else {
    run all
}
