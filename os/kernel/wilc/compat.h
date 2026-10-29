/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility for building the Microchip WILC driver (linux4microchip
 * linux-6.6-mchp) against ADI adi-6.6.0, which predates the 6.6 stable
 * backport that added struct ieee80211_radiotap_header_fixed.
 */
#include <linux/types.h>

struct ieee80211_radiotap_header_fixed {
	uint8_t it_version;
	uint8_t it_pad;
	__le16 it_len;
	__le32 it_present;
} __packed;
