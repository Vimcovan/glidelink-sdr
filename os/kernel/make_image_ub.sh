set -e
B=/mnt/c/Users/PC/AppData/Local/Temp/claude/D--ClaudePrj-DeepJSCC-Q/9a8b0793-c517-4c5b-aceb-f63d64526a64/scratchpad/boardboot
mkdir -p /root/sdr/fit && cd /root/sdr/fit
cp /root/sdr/linux/arch/arm64/boot/Image Image
cp $B/fit.dtb system.dtb
# USB 3 link power management off on the dwc3 device port (U1/U2 entry rejected, the link stays in U0):
# with U1/U2 the PC reset the USB link now and then (docs/known_issues.md 1.1)
USB=/axi/usb@ff9d0000/usb@fe200000
fdtput system.dtb $USB snps,dis-u1-entry-quirk -t x
fdtput system.dtb $USB snps,dis-u2-entry-quirk -t x
dtc -q -I dtb -O dtb -p 8192 -o system.pad.dtb system.dtb && mv system.pad.dtb system.dtb   # room for U-Boot's fixups
cat > image.its <<'ITS'
/dts-v1/;
/ {
    description = "U-Boot fitImage for PYNQ arm kernel (ADI 6.6 kernel, GlideLink SDR)";
    #address-cells = <1>;
    images {
        kernel-0 {
            description = "Linux Kernel";
            data = /incbin/("Image");
            type = "kernel"; arch = "arm64"; os = "linux"; compression = "none";
            load = <0x80000>; entry = <0x80000>;
            hash-1 { algo = "sha1"; };
        };
        fdt-0 {
            description = "Flattened Device Tree blob";
            data = /incbin/("system.dtb");
            type = "flat_dt"; arch = "arm64"; compression = "none";
            hash-1 { algo = "sha1"; };
        };
    };
    configurations {
        default = "conf-1";
        conf-1 {
            description = "Boot Linux kernel with FDT blob";
            kernel = "kernel-0"; fdt = "fdt-0";
            hash-1 { algo = "sha1"; };
        };
    };
};
ITS
mkimage -f image.its image.ub > /dev/null
dumpimage -l image.ub | grep -E "Image|Data Size|Load|FDT|Kernel" | head
cd /root/sdr/modroot && tar -czf /root/sdr/modules-6.6.0-adi-glidelink.tgz lib/modules/6.6.0-adi-glidelink
ls -la /root/sdr/fit/image.ub /root/sdr/modules-6.6.0-adi-glidelink.tgz
cp /root/sdr/fit/image.ub /root/sdr/modules-6.6.0-adi-glidelink.tgz /mnt/c/Users/PC/AppData/Local/Temp/claude/D--ClaudePrj-DeepJSCC-Q/9a8b0793-c517-4c5b-aceb-f63d64526a64/scratchpad/
