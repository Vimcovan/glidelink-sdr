"""Generate the slot part of the PL shell for one image (docs/phase4_plan.md G7).

An image (hw/images/<name>.yaml) lists the modules in the slots, each with its clock
(200 = processing clock, 250, 100 MHz) and RTL parameters. This writes, into <out_dir>:

    glidelink_image.vh   `define GL_N_SLOTS, GL_IMAGE (included by glidelink_shell.v)
    glidelink_slots.v    a glidelink_slot wrapper and the module for every slot
    image_sources.tcl    the modules' RTL files and Xilinx IP (.xci) for the Vivado project
    image.json           the image as resolved (slot -> module, clock, switch ports)

Module "passthrough" is the shell's own; any other name is hw/modules/<name>, described by
its module.yaml: top, parameters, optional ip (list of .xci files), ip_files (per IP, the
parameters that name a file in the module directory, e.g. a FIR coefficient file) and uses
(source libraries under hw/modules, e.g. phy_common, added once). The .xci files are imported
from copies in <out_dir>/ip with the ip_files parameters rewritten to absolute paths (the path
stored in an .xci is relative to wherever it came from, and Vivado loads such a file as soon as
it imports the IP). A module's or library's .v, .sv and .mem files
are added to the project.

    python gen_image.py <image.yaml> <out_dir>
"""
import glob
import json
import os
import re
import sys

import yaml

HW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CLOCKS = {200: None, 250: "clk_250", 100: "clk_100"}   # None: the processing clock


def slot_port(k):
    """switch sink / source index of slot k (0 RF, 1 host 0, 2 slot 0, 3 host 1, then slots 1..)"""
    return 2 if k == 0 else 3 + k


def sources(d):
    return sorted(sum((glob.glob(os.path.join(d, e)) for e in ("*.v", "*.sv", "*.mem")), []))


def module_info(name):
    if name == "passthrough":
        return {"top": "glidelink_passthrough", "dir": None, "rtl": [], "ip": []}
    d = os.path.join(HW, "modules", name)
    desc = yaml.safe_load(open(os.path.join(d, "module.yaml")))
    rtl = []
    for lib in desc.get("uses", []) or []:
        rtl += sources(os.path.join(HW, "modules", lib))
    rtl += sources(d)
    ip = [os.path.join(d, x) for x in desc.get("ip", []) or []]
    ip_files = {name: {p: os.path.join(d, f) for p, f in params.items()}
                for name, params in (desc.get("ip_files", {}) or {}).items()}
    return {"top": desc["top"], "dir": d, "rtl": rtl, "ip": ip, "ip_files": ip_files, "desc": desc}


def patch_ips(info, out):
    """copies of the module's .xci in <out>, ip_files parameters set to absolute paths; returns them"""
    os.makedirs(out, exist_ok=True)
    copies = []
    for xci in info["ip"]:
        name = os.path.splitext(os.path.basename(xci))[0]
        text = open(xci, encoding="utf8").read()
        # the output directory remembered from the original project: next to the copy
        text = re.sub(r'"gen_directory": "[^"]*"', '"gen_directory": "."', text)
        text = re.sub(r'"OUTPUTDIR": \[ \{ "value": "[^"]*" \} \]', '"OUTPUTDIR": [ { "value": "." } ]', text)
        for p, f in info.get("ip_files", {}).get(name, {}).items():
            path = f.replace(os.sep, "/")
            text, n = re.subn(r'("%s": \[ \{ "value": ")[^"]*(")' % re.escape(p), lambda m: m.group(1) + path + m.group(2), text)
            if n == 0:
                raise SystemExit(f"{xci}: no parameter {p}")
        dst = os.path.join(out, os.path.basename(xci))
        open(dst, "w", encoding="utf8", newline="\n").write(text)
        copies.append(dst)
    return copies


def verilog_param(v):
    return str(v) if isinstance(v, int) else f'"{v}"'


def generate(image_path, out):
    img = yaml.safe_load(open(image_path))
    name = img["name"]
    slots = img["slots"]
    n = len(slots)
    assert 1 <= n <= 11, "1 to 11 slots (4-bit routes)"
    os.makedirs(out, exist_ok=True)

    resolved, rtl, ip = [], [], []
    body = []
    for k, sl in enumerate(slots):
        info = module_info(sl["module"])
        clock = int(sl.get("clock", 200))
        if clock not in CLOCKS:
            raise SystemExit(f"slot {k}: clock {clock} MHz not available (200, 250, 100)")
        params = dict(info.get("desc", {}).get("parameters", {}) or {})
        params.update(sl.get("params", {}) or {})
        rtl += [p for p in info["rtl"] if p not in rtl]
        ip += [p for p in patch_ips(info, os.path.join(out, "ip")) if p not in ip]
        resolved.append({"slot": k, "module": sl["module"], "top": info["top"], "clock_mhz": clock,
                         "port": slot_port(k), "params": params})
        a12, a32, d = f"{k} * 12 +: 12", f"{k} * 32 +: 32", f"{k} * 105 +: 105"
        pstr = (" #(" + ", ".join(f".{p}({verilog_param(v)})" for p, v in params.items()) + ")") if params else ""
        clk = CLOCKS[clock]
        body.append(f"""
  // slot {k}: {sl['module']} ({clock} MHz), switch port {slot_port(k)}
  wire        m{k}_clk, m{k}_rstn, m{k}_flush, m{k}_awvalid, m{k}_awready, m{k}_wvalid, m{k}_wready;
  wire        m{k}_bvalid, m{k}_bready, m{k}_arvalid, m{k}_arready, m{k}_rvalid, m{k}_rready;
  wire [11:0] m{k}_awaddr, m{k}_araddr;
  wire [31:0] m{k}_wdata, m{k}_rdata;
  wire        i{k}_valid, i{k}_ready, o{k}_valid, o{k}_ready;
  wire [104:0] i{k}_data, o{k}_data;

  glidelink_slot #(.ASYNC({0 if clk is None else 1})) i_slot{k} (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_awvalid(s_awvalid[{k}]), .s_awready(s_awready[{k}]), .s_awaddr(s_awaddr[{a12}]),
    .s_wvalid(s_wvalid[{k}]), .s_wready(s_wready[{k}]), .s_wdata(s_wdata[{a32}]),
    .s_bvalid(s_bvalid[{k}]), .s_bready(s_bready[{k}]),
    .s_arvalid(s_arvalid[{k}]), .s_arready(s_arready[{k}]), .s_araddr(s_araddr[{a12}]),
    .s_rvalid(s_rvalid[{k}]), .s_rready(s_rready[{k}]), .s_rdata(s_rdata[{a32}]),
    .clk(clk), .rstn(rstn), .flush(flush[{k}]),
    .snk_valid(snk_valid[{k}]), .snk_ready(snk_ready[{k}]), .snk_data(snk_data[{d}]),
    .src_valid(src_valid[{k}]), .src_ready(src_ready[{k}]), .src_data(src_data[{d}]),
    .slot_clk({clk or "clk"}), .m_clk(m{k}_clk), .m_rstn(m{k}_rstn), .m_flush(m{k}_flush),
    .m_awvalid(m{k}_awvalid), .m_awready(m{k}_awready), .m_awaddr(m{k}_awaddr),
    .m_wvalid(m{k}_wvalid), .m_wready(m{k}_wready), .m_wdata(m{k}_wdata),
    .m_bvalid(m{k}_bvalid), .m_bready(m{k}_bready),
    .m_arvalid(m{k}_arvalid), .m_arready(m{k}_arready), .m_araddr(m{k}_araddr),
    .m_rvalid(m{k}_rvalid), .m_rready(m{k}_rready), .m_rdata(m{k}_rdata),
    .mod_in_valid(i{k}_valid), .mod_in_ready(i{k}_ready), .mod_in_data(i{k}_data),
    .mod_out_valid(o{k}_valid), .mod_out_ready(o{k}_ready), .mod_out_data(o{k}_data));

  {info['top']}{pstr} i_mod{k} (
    .clk(m{k}_clk), .rstn(m{k}_rstn), .flush(m{k}_flush),
    .s_axil_awvalid(m{k}_awvalid), .s_axil_awready(m{k}_awready), .s_axil_awaddr(m{k}_awaddr),
    .s_axil_wvalid(m{k}_wvalid), .s_axil_wready(m{k}_wready), .s_axil_wdata(m{k}_wdata),
    .s_axil_bvalid(m{k}_bvalid), .s_axil_bready(m{k}_bready),
    .s_axil_arvalid(m{k}_arvalid), .s_axil_arready(m{k}_arready), .s_axil_araddr(m{k}_araddr),
    .s_axil_rvalid(m{k}_rvalid), .s_axil_rready(m{k}_rready), .s_axil_rdata(m{k}_rdata),
    .s_axis_tvalid(i{k}_valid), .s_axis_tready(i{k}_ready), .s_axis_tdata(i{k}_data[31:0]),
    .s_axis_tuser(i{k}_data[103:32]), .s_axis_tlast(i{k}_data[104]),
    .m_axis_tvalid(o{k}_valid), .m_axis_tready(o{k}_ready), .m_axis_tdata(o{k}_data[31:0]),
    .m_axis_tuser(o{k}_data[103:32]), .m_axis_tlast(o{k}_data[104]));
""")

    open(os.path.join(out, "glidelink_image.vh"), "w", newline="\n").write(
        f"// generated by hw/scripts/gen_image.py from {os.path.basename(image_path)}: do not edit\n"
        f"`define GL_N_SLOTS {n}\n`define GL_IMAGE \"{name}\"\n")

    head = f"""// generated by hw/scripts/gen_image.py from {os.path.basename(image_path)}: do not edit
// image "{name}": {", ".join(f"slot {r['slot']} {r['module']} ({r['clock_mhz']} MHz)" for r in resolved)}

`timescale 1ns/100ps

module glidelink_slots #(
  parameter N = {n}
) (
  input              s_axi_aclk,
  input              s_axi_aresetn,
  input  [N-1:0]     s_awvalid,
  output [N-1:0]     s_awready,
  input  [N*12-1:0]  s_awaddr,
  input  [N-1:0]     s_wvalid,
  output [N-1:0]     s_wready,
  input  [N*32-1:0]  s_wdata,
  output [N-1:0]     s_bvalid,
  input  [N-1:0]     s_bready,
  input  [N-1:0]     s_arvalid,
  output [N-1:0]     s_arready,
  input  [N*12-1:0]  s_araddr,
  output [N-1:0]     s_rvalid,
  input  [N-1:0]     s_rready,
  output [N*32-1:0]  s_rdata,

  input              clk,
  input              rstn,
  input              clk_100,
  input              clk_250,
  input  [N-1:0]     flush,
  input  [N-1:0]     snk_valid,
  output [N-1:0]     snk_ready,
  input  [N*105-1:0] snk_data,
  output [N-1:0]     src_valid,
  input  [N-1:0]     src_ready,
  output [N*105-1:0] src_data
);
"""
    open(os.path.join(out, "glidelink_slots.v"), "w", newline="\n").write(head + "".join(body) + "\nendmodule\n")

    tcl = ["# generated by hw/scripts/gen_image.py: the modules of image " + name]
    tcl += [f"add_files -norecurse {{{p.replace(os.sep, '/')}}}" for p in rtl]
    tcl += [f"import_ip {{{p.replace(os.sep, '/')}}}" for p in ip]
    open(os.path.join(out, "image_sources.tcl"), "w", newline="\n").write("\n".join(tcl) + "\n")
    json.dump({"name": name, "slots": resolved}, open(os.path.join(out, "image.json"), "w"), indent=2)
    return resolved


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    for r in generate(sys.argv[1], sys.argv[2]):
        print(f"slot {r['slot']}: {r['module']} ({r['top']}), {r['clock_mhz']} MHz, switch port {r['port']}")
