#!/bin/bash
# Trigger script for sFlow Traffic Monitor
# Environment variables available:
#   PPS             - current packets per second
#   MBPS            - current megabits per second
#   THRESHOLD_PPS   - configured PPS threshold
#   THRESHOLD_MBPS  - configured MBPS threshold

echo "[Trigger] PPS=$PPS MBPS=$MBPS (Thresholds: PPS=$THRESHOLD_PPS, MBPS=$THRESHOLD_MBPS)"
# TODO: add custom actions here, e.g., send alert, scale service, etc.
