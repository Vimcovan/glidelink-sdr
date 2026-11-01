"""Generated parts of a GlideLink user module, from its module.yaml (hw/modules/module_desc.py).

Register file (modules with bus: generated, the default): <top>_slot.v, the module as the
shell's slot sees it: AXI4-Lite register window (glidelink_module_axil), the registers of
module.yaml, and the module itself, which sees the registers as plain ports:

    rw register / field  NAME     input  [W-1:0] name    the value written (default after reset)
    pulse field          name     input          name    one cycle per write of a 1
    strobe: true         NAME     input          name_wr one cycle per write (name holds the data)
    wo register          NAME     input  [W-1:0] name, input name_wr
    readback: true       NAME     output [W-1:0] name_rd read back instead of the stored value
    ro register / field  NAME     output [W-1:0] name    (none if it has a constant `value`)

next to clk, rstn, flush and the two AXI4-Stream ports (s_axis_* in, m_axis_* out: tdata
32, tuser 72, tlast). Port names are the register names in lower case, field names as given.

GNU Radio blocks (modules with a block section): glidelink_<id>.block.yml (the module in its
PL slot) and glidelink_<id>_model.block.yml (the reference model in software), the blocks of
sw/gr-glidelink/python/glidelink/modules.py.

    python gen_module.py wrapper <id> <out_dir>   writes <out_dir>/<top>_slot.v, prints its name
    python gen_module.py ports <id>                the module's port list (Verilog)
    python gen_module.py grc <out_dir>             GRC block files of every module with a block
    python gen_module.py blocks                    ids of the modules with a block
"""
import glob
import os
import sys

import yaml

HW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(HW, "modules"))
import module_desc  # noqa: E402

STD_PORTS = """\
  input             clk,
  input             rstn,
  input             flush,                  // stream state only (PORT_RESET): registers kept
"""
AXIL_PORTS = """\
  input             s_axil_awvalid,
  output            s_axil_awready,
  input     [11:0]  s_axil_awaddr,
  input             s_axil_wvalid,
  output            s_axil_wready,
  input     [31:0]  s_axil_wdata,
  output            s_axil_bvalid,
  input             s_axil_bready,
  input             s_axil_arvalid,
  output            s_axil_arready,
  input     [11:0]  s_axil_araddr,
  output            s_axil_rvalid,
  input             s_axil_rready,
  output    [31:0]  s_axil_rdata,
"""
AXIS_PORTS = """\
  input             s_axis_tvalid,
  output            s_axis_tready,
  input     [31:0]  s_axis_tdata,
  input     [71:0]  s_axis_tuser,
  input             s_axis_tlast,

  output            m_axis_tvalid,
  input             m_axis_tready,
  output    [31:0]  m_axis_tdata,
  output    [71:0]  m_axis_tuser,
  output            m_axis_tlast
"""
RESERVED = {"clk", "rstn", "flush"}


def _rng(w):
    return f"[{w - 1}:0] " if w > 1 else ""


def _vparam(v):
    return str(v) if isinstance(v, int) else f'"{v}"'


def signals(desc):
    """the module's register ports: (direction, width, name, doc) per port, and per register
    how it is held and read: list of dicts"""
    ports, regs = [], []
    for r in desc["regs"]:
        if r.get("builtin"):
            continue
        n = r["name"].lower()
        doc = r.get("doc", "")
        item = {"reg": r, "write": [], "read": None}
        if "fields" in r:
            parts = []
            for f in r["fields"]:
                w = f["hi"] - f["lo"] + 1
                fd = f.get("doc", "")
                if f["access"] in ("rw", "pulse"):
                    ports.append(("input", w, f["name"], f"{r['name']}[{f['hi']}:{f['lo']}]"
                                  + (", one cycle per write of 1" if f["access"] == "pulse" else "")
                                  + (f": {fd}" if fd else "")))
                    item["write"].append((f["name"], f["hi"], f["lo"], f["access"], f["default"]))
                    if f["access"] == "rw":
                        parts.append((f["hi"], f["lo"], f"r_{f['name']}"))
                elif "value" in f:
                    parts.append((f["hi"], f["lo"], f"({f['value']})"))
                else:
                    ports.append(("output", w, f["name"], f"{r['name']}[{f['hi']}:{f['lo']}]"
                                  + (f": {fd}" if fd else "")))
                    parts.append((f["hi"], f["lo"], f"w_{f['name']}"))
            item["read"] = ("fields", parts)
        else:
            w = r["width"]
            if r["access"] in ("rw", "wo"):
                ports.append(("input", w, n, f"{r['name']}" + (f": {doc}" if doc else "")))
                item["write"].append((n, w - 1, 0, "rw", r["default"]))
                if r.get("strobe") or r["access"] == "wo":
                    ports.append(("input", 1, n + "_wr", f"one cycle per write of {r['name']}"))
                if r.get("readback"):
                    ports.append(("output", w, n + "_rd", f"{r['name']} as read"))
                    item["read"] = ("value", f"w_{n}_rd", w)
                elif r["access"] == "rw":
                    item["read"] = ("value", f"r_{n}", w)
            elif "value" in r:
                item["read"] = ("value", f"({r['value']})", w)
            else:
                ports.append(("output", w, n, f"{r['name']}" + (f": {doc}" if doc else "")))
                item["read"] = ("value", f"w_{n}", w)
        if (r.get("strobe") or r["access"] == "wo") and "fields" in r:
            ports.append(("input", 1, n + "_wr", f"one cycle per write of {r['name']}"))
        regs.append(item)
    names = [p[2] for p in ports]
    for p in names:
        if p in RESERVED or p.startswith(("s_axis_", "m_axis_", "s_axil_")) or names.count(p) > 1:
            raise SystemExit(f"{desc['id']}: register port name {p!r} clashes")
    return ports, regs


def ports_text(desc):
    ports, _ = signals(desc)
    lines = [STD_PORTS]
    if ports:
        lines.append("  // registers (module.yaml; the register file is generated)\n")
        for d, w, n, doc in ports:
            lines.append(f"  {d:<6} {_rng(w):<10}{n + ',':<24}// {doc}\n")
        lines.append("\n")
    lines.append(AXIS_PORTS)
    return "".join(lines)


def wrapper(desc, out):
    """writes <out>/<top>_slot.v; returns the wrapper's module name"""
    top = desc["top"]
    name = top + "_slot"
    params = desc.get("parameters", {}) or {}
    ports, regs = signals(desc)
    ptxt = ""
    if params:
        ptxt = " #(\n" + ",\n".join(f"  parameter {k} = {_vparam(v)}" for k, v in params.items()) + "\n)"

    decl, wr_reset, wr_clear, wr_case, rd_case = [], [], [], [], []
    for d, w, n, _ in ports:
        if d == "output":
            decl.append(f"  wire {_rng(w)}w_{n};")
    for item in regs:
        r = item["reg"]
        n = r["name"].lower()
        stmts = []
        for sig, hi, lo, acc, dflt in item["write"]:
            w = hi - lo + 1
            if acc == "pulse":
                decl.append(f"  reg  r_{sig} = 1'b0;")
                wr_clear.append(f"    r_{sig} <= 1'b0;")
                stmts.append(f"r_{sig} <= wr_data[{lo}];")
            else:
                dv = f"{w}'d{int(dflt) & ((1 << w) - 1)}"
                decl.append(f"  reg  {_rng(w)}r_{sig} = {dv};")
                wr_reset.append(f"      r_{sig} <= {dv};")
                stmts.append(f"r_{sig} <= wr_data[{hi}:{lo}];" if w > 1 else f"r_{sig} <= wr_data[{lo}];")
        if r.get("strobe") or r["access"] == "wo":
            decl.append(f"  reg  r_{n}_wr = 1'b0;")
            wr_clear.append(f"    r_{n}_wr <= 1'b0;")
            stmts.append(f"r_{n}_wr <= 1'b1;")
        idx = f"10'h{r['offset'] >> 2:03X}"
        if stmts:
            wr_case.append(f"        {idx}: begin {' '.join(stmts)} end   // {r['name']}")
        rd = item["read"]
        if rd is None:
            continue
        if rd[0] == "value":
            _, expr, w = rd
            if w >= 32:
                val = expr
            elif r.get("signed"):
                val = f"{{{{{32 - w}{{{expr}[{w - 1}]}}}}, {expr}[{w - 1}:0]}}"
            else:
                val = f"{{{32 - w}'d0, {expr}[{w - 1}:0]}}" if not expr.startswith("(") else f"32'd0 | {expr}"
            rd_case.append(f"      {idx}: rd_data = {val};   // {r['name']}")
        else:
            body = " ".join(f"rd_data[{hi}:{lo}] = {e};" for hi, lo, e in rd[1])
            rd_case.append(f"      {idx}: begin rd_data = 32'd0; {body} end   // {r['name']}")

    conn = []
    pconn = (" #(" + ", ".join(f".{k}({k})" for k in params) + ")") if params else ""
    for d, w, n, _ in ports:
        conn.append(f"    .{n}({'w_' + n if d == 'output' else 'r_' + n}),")
    regmap = "\n".join(f"//   0x{r['offset']:03X}  {r['name']:<12} {r['access'].upper():<3} {r.get('doc', '')}".rstrip()
                       for r in desc["regs"])
    text = f"""// generated by hw/scripts/gen_module.py from hw/modules/{desc['id']}/module.yaml: do not edit
// {desc.get('name', desc['id'])}: register file (AXI4-Lite, 4 KB window) around {top}
{regmap}

`timescale 1ns/100ps

module {name}{ptxt} (
{STD_PORTS}
{AXIL_PORTS}
{AXIS_PORTS});

  wire        wr_en;
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  reg  [31:0] rd_data;
{chr(10).join(decl)}

  glidelink_module_axil i_axil (
    .clk(clk), .rstn(rstn),
    .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready), .s_axil_awaddr(s_axil_awaddr),
    .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready), .s_axil_wdata(s_axil_wdata),
    .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready), .s_axil_araddr(s_axil_araddr),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready), .s_axil_rdata(s_axil_rdata),
    .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .rd_addr(rd_addr), .rd_data(rd_data));

  always @(posedge clk) begin
{chr(10).join(wr_clear)}
    if (!rstn) begin
{chr(10).join(wr_reset)}
    end else if (wr_en) begin
      case (wr_addr[11:2])
{chr(10).join(wr_case)}
        default: ;
      endcase
    end
  end

  always @(*) begin
    case (rd_addr[11:2])
      10'h000: rd_data = 32'h{desc['id_value']:08X};   // ID
      10'h001: rd_data = 32'h{module_desc.version_word(desc.get('version', '1.0.0')):08X};   // VERSION
{chr(10).join(rd_case)}
      default: rd_data = 32'd0;
    endcase
  end

  {top}{pconn} i_mod (
    .clk(clk), .rstn(rstn), .flush(flush),
{chr(10).join(conn)}
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tdata(s_axis_tdata),
    .s_axis_tuser(s_axis_tuser), .s_axis_tlast(s_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tdata(m_axis_tdata),
    .m_axis_tuser(m_axis_tuser), .m_axis_tlast(m_axis_tlast));

endmodule
"""
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, name + ".v"), "w", newline="\n") as f:
        f.write(text)
    return name


# ---------------------------------------------------------------------------
# GNU Radio blocks
# ---------------------------------------------------------------------------

GRC_TYPES = {"real": "real", "int": "int", "bool": "bool", "string": "string", "enum": "enum",
             "int_vector": "int_vector", "real_vector": "real_vector"}


def _grc_default(p):
    if "grc_default" in p:
        return str(p["grc_default"])
    v = p.get("default", 0)
    t = p.get("type", "real")
    if t in ("enum", "string"):
        return repr(str(v)).replace("'", '"')
    return str(v)


def _grc_param(p):
    t = p.get("type", "real")
    out = {"id": p["name"], "label": p.get("label", p["name"]), "dtype": GRC_TYPES[t],
           "default": _grc_default(p)}
    if t == "enum":
        out["options"] = [f'"{o[0]}"' for o in p["options"]]
        out["option_labels"] = [str(o[1]) for o in p["options"]]
    return out


def _doc(desc, pl):
    blk = desc["block"]
    lines = [blk.get("doc", desc.get("name", desc["id"])).strip(), ""]
    if pl:
        lines.append(f"The module in its PL slot (hw/modules/{desc['id']}): the block writes its registers; "
                     "the data goes through the PL ports (orange), connected to other PL ports. "
                     "Slot -1: the first slot holding the module.")
    else:
        lines.append(f"The reference model of hw/modules/{desc['id']} in software, with the same parameters "
                     f"as GlideLink {desc.get('name', desc['id'])} (PL)"
                     + (": bit-exact." if desc.get("exact", True) else ".")
                     + " Samples are sc16 scaled to 1.0 (rounded and saturated on the way in).")
    docs = [f"{p.get('label', p['name'])}: {p['doc']}" for p in blk.get("params", []) if p.get("doc")]
    if docs:
        lines += [""] + docs
    return "\n".join(lines)


class _Lit(str):
    pass


yaml.SafeDumper.add_representer(_Lit, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style="|"))


def grc_blocks(desc):
    """{file name: text} of the module's two GRC blocks"""
    i = desc["id"]
    name = desc.get("name", i)
    params = desc["block"].get("params", [])
    kw = ", ".join(f"{p['name']}=${{{p['name']}}}" for p in params)
    cbs = [f"set_{p['name']}(${{{p['name']}}})" for p in params]
    pl = {
        "id": f"glidelink_{i}", "label": f"GlideLink {name} (PL)", "category": "[GlideLink]/FPGA modules",
        "flags": ["python"],
        "parameters": [{"id": "args", "label": "Device arguments", "dtype": "string",
                        "default": "driver=glidelink"},
                       {"id": "slot", "label": "Slot", "dtype": "int", "default": "-1"}]
        + [_grc_param(p) for p in params],
        "inputs": [{"domain": "glidelink_pl", "dtype": "sc16", "label": "pl_in", "optional": True}],
        "outputs": [{"domain": "glidelink_pl", "dtype": "sc16", "label": "pl_out", "optional": True}],
        "templates": {"imports": "from gnuradio import glidelink",
                      "make": f"glidelink.{i}(args=${{args}}, slot=${{slot}}" + (", " + kw if kw else "") + ")",
                      "callbacks": cbs},
        "documentation": _Lit(_doc(desc, True)),
        "file_format": 1,
    }
    sw = {
        "id": f"glidelink_{i}_model", "label": f"GlideLink {name} (software)",
        "category": "[GlideLink]/FPGA modules", "flags": ["python"],
        "parameters": [_grc_param(p) for p in params],
        "inputs": [{"domain": "stream", "dtype": "complex"}],
        "outputs": [{"domain": "stream", "dtype": "complex"}],
        "templates": {"imports": "from gnuradio import glidelink",
                      "make": f"glidelink.{i}_model({kw})", "callbacks": cbs},
        "documentation": _Lit(_doc(desc, False)),
        "file_format": 1,
    }
    head = f"# generated by hw/scripts/gen_module.py from hw/modules/{i}/module.yaml: do not edit\n"
    dump = lambda d: head + yaml.safe_dump(d, sort_keys=False, allow_unicode=True, width=1000)  # noqa: E731
    if not sw["templates"]["callbacks"]:
        del sw["templates"]["callbacks"], pl["templates"]["callbacks"]
    return {f"glidelink_{i}.block.yml": dump(pl), f"glidelink_{i}_model.block.yml": dump(sw)}


def block_modules(root=None):
    root = root or os.path.join(HW, "modules")
    ids = []
    for y in sorted(glob.glob(os.path.join(root, "*", "module.yaml"))):
        with open(y, encoding="utf8") as f:
            if "block" in (yaml.safe_load(f) or {}):
                ids.append(os.path.basename(os.path.dirname(y)))
    return ids


def main(argv):
    if len(argv) >= 3 and argv[0] == "wrapper":
        print(wrapper(module_desc.load(argv[1]), argv[2]))
    elif len(argv) == 2 and argv[0] == "ports":
        print(ports_text(module_desc.load(argv[1])))
    elif len(argv) == 2 and argv[0] == "grc":
        os.makedirs(argv[1], exist_ok=True)
        for i in block_modules():
            for fn, text in grc_blocks(module_desc.load(i)).items():
                with open(os.path.join(argv[1], fn), "w", encoding="utf8", newline="\n") as f:
                    f.write(text)
            print(i)
    elif argv == ["blocks"]:
        print("\n".join(block_modules()))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
