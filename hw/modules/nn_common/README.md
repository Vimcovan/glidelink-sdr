# nn_common

Source library shared by the DeepJSCC-Q network modules (`jscc_enc`, `jscc_dec`): convolution
engine, line / pixel buffers, GDN, sigmoid, PWL support, ROMs and FIFOs. Copied unchanged from the
competition design (Vimcovan/glidelink-fpga @ 8367bee, `src/hw/{tx,rx}/rtl/network/rtl`; the TX and
RX copies there are identical). Modules list it under `uses:` in their `module.yaml`.
