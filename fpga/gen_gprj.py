#!/usr/bin/env python3
"""Write a Gowin IDE XML .gprj from the Makefile file list.

gw_sh `saveto` dumps Tcl, which the IDE rejects as "Invalid project file".
This emits the XML the IDE actually opens (see TangNano-9K-example .gprj files).
"""

from __future__ import annotations

import argparse
import json
import os
from xml.sax.saxutils import escape


def relpath(path: str, root: str) -> str:
    return os.path.relpath(os.path.abspath(path), os.path.abspath(root)).replace("\\", "/")


def write_gprj(
    out: str,
    root: str,
    device_family: str,
    device_part: str,
    device_id: str,
    srcs: list[str],
    cst: str,
    sdc: str,
) -> None:
    lines = [
        '<?xml version="1" encoding="UTF-8"?>',
        "<!DOCTYPE gowin-fpga-project>",
        "<Project>",
        "    <Template>FPGA</Template>",
        "    <Version>5</Version>",
        f'    <Device name="{escape(device_family)}" pn="{escape(device_part)}">{escape(device_id)}</Device>',
        "    <FileList>",
    ]
    for src in srcs:
        if not src:
            continue
        lines.append(
            f'        <File path="{escape(relpath(src, root))}" type="file.verilog" enable="1"/>'
        )
    lines.append(f'        <File path="{escape(relpath(cst, root))}" type="file.cst" enable="1"/>')
    lines.append(f'        <File path="{escape(relpath(sdc, root))}" type="file.sdc" enable="1"/>')
    lines.extend(
        [
            "    </FileList>",
            "</Project>",
            "",
        ]
    )
    os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def write_process_config(path: str, root: str, top: str, incdirs: list[str]) -> None:
    include = [relpath(d, root) for d in incdirs if d]
    cfg = {
        "Allow_Duplicate_Modules": False,
        "Annotated_Properties_for_Analyst": True,
        "BACKGROUND_PROGRAMMING": "off",
        "COMPRESS": False,
        "CPU": False,
        "CRC_CHECK": True,
        "Clock_Conversion": True,
        "Clock_Route_Order": 0,
        "Correct_Hold_Violation": True,
        "DONE": False,
        "DOWNLOAD_SPEED": "default",
        "Default_Enum_Encoding": "default",
        "Disable_Insert_Pad": False,
        "ENABLE_MERGE_MODE": False,
        "ENCRYPTION_KEY": False,
        "ENCRYPTION_KEY_TEXT": "00000000000000000000000000000000",
        "FORMAT": "binary",
        "FSM Compiler": True,
        "Fanout_Guide": 10000,
        "Frequency": "Auto",
        "GwSyn_Loop_Limit": 2000,
        "HOTBOOT": False,
        "I2C": False,
        "I2C_SLAVE_ADDR": "00",
        "IncludePath": include,
        "Incremental_Compile": "",
        "Initialize_Primitives": False,
        "JTAG": False,
        "MODE_IO": False,
        "MSPI": True,
        "MSPI_JUMP": False,
        "Multi_Boot": True,
        "Multiple_File_Compilation_Unit": True,
        "OUTPUT_BASE_NAME": top,
        "POWER_ON_RESET_MONITOR": True,
        "PRINT_BSRAM_VALUE": True,
        "PROGRAM_DONE_BYPASS": False,
        "Pipelining": True,
        "PlaceInRegToIob": True,
        "PlaceIoRegToIob": True,
        "PlaceOutRegToIob": True,
        "Place_Option": "1",
        "Process_Configuration_Verion": "1.0",
        "Promote_Physical_Constraint_Warning_to_Error": True,
        "Push_Tristates": True,
        "READY": False,
        "RECONFIG_N": False,
        "Ram_RW_Check": True,
        "Replicate_Resources": False,
        "Report_Auto-Placed_Io_Information": False,
        "Resolve_Mixed_Drivers": False,
        "Resource_Sharing": True,
        "Retiming": False,
        "Route_Maxfan": 23,
        "Route_Option": "1",
        "Run_Timing_Driven": True,
        "SECURE_MODE": False,
        "SECURITY_BIT": True,
        "SSPI": True,
        "Show_All_Warnings": True,
        "Synthesize_tool": "GowinSyn",
        "TclPre": "",
        "TopModule": top,
        "USERCODE": "default",
        "Unused_Pin": "As_input_tri_stated_with_pull_up",
        "VCCAUX": 3.3,
        "VCCX": "3.3",
        "VHDL_Standard": "VHDL_Std_1993",
        "Verilog_Standard": "Vlg_Std_Sysv2017",
        "WAKE_UP": "0",
        "Write_Vendor_Constraint_File": True,
        "show_all_warnings": True,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg, f, indent=1)
        f.write("\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", required=True, help="Project directory (fpga/); paths are relative to this")
    p.add_argument("--out", required=True, help="Output .gprj path")
    p.add_argument("--device-family", required=True)
    p.add_argument("--device-part", required=True)
    p.add_argument("--device-id", default="gw1nr9c-004")
    p.add_argument("--top", required=True)
    p.add_argument("--cst", required=True)
    p.add_argument("--sdc", required=True)
    p.add_argument("--incdir", action="append", default=[], help="Verilog include directory (repeatable)")
    p.add_argument("srcs", nargs="*", help="Verilog sources, in compile order")
    args = p.parse_args()

    write_gprj(
        out=args.out,
        root=args.root,
        device_family=args.device_family,
        device_part=args.device_part,
        device_id=args.device_id,
        srcs=args.srcs,
        cst=args.cst,
        sdc=args.sdc,
    )
    impl_cfg = os.path.join(os.path.abspath(args.root), "impl", "project_process_config.json")
    write_process_config(impl_cfg, args.root, args.top, args.incdir)
    print(f"Wrote {args.out}")
    print(f"Wrote {impl_cfg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
