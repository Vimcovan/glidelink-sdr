title: The GLIDELINK OOT Module
brief: GNU Radio blocks for the GlideLink SDR platform (PYNQ-ZU + AD9361)
tags: # Tags are arbitrary, but look at CGRAN what other authors are using
  - sdr
  - ad9361
  - fpga
author:
  - GlideLink
copyright_owner:
  - GlideLink
license: GPL-3.0-or-later
gr_supported_version: v3.10
#repo: # Put the URL of the repository here, or leave blank for default
#website: <module_website> # If you have a separate project website, put it here
#icon: <icon_url> # Put a URL to a square image here that will be used as an icon on CGRAN
---
Connection management for the PL shell (stream switch routes), AD9361 driver
parameters and registers (GlideLink Control), and the host port 1 source /
sink for module data. RF streams use gr-soapy with driver=glidelink.
See README.md.
