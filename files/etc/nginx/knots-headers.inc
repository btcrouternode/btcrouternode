# SPDX-License-Identifier: GPL-2.0-only
# S6 (review 2026-10-10) — security headers for every Knots UI response.
# nginx (1.26 on OpenWrt 24.10) drops ALL inherited add_header directives as
# soon as a location sets any add_header of its own, so this file is included
# at server level AND inside every location that adds a header.
# Not a *.conf file: conf.d/*.conf is included at http level.
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Content-Security-Policy "frame-ancestors 'none'" always;
add_header Referrer-Policy "same-origin" always;
