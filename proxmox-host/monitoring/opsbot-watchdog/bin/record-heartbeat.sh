#!/bin/sh
# record-heartbeat.sh (runs on opsbot, as the forced command for evilbot's heartbeat key).
# Ignores any client-supplied command; just stamps the time evilbot last checked in.
mkdir -p /var/lib/health-watchdog
date +%s > /var/lib/health-watchdog/evilbot.last
exit 0
