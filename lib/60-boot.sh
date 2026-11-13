#!/usr/bin/env bash
# 60-boot.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# UKI / systemd-boot / sbctl steps run inside 80-chroot-setup.sh today.
# This module is the public hook point for future extraction.
t14s_boot_lib_ready() { return 0; }
