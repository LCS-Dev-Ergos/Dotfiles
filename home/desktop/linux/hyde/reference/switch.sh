#!/usr/bin/env zsh
# =====--------------------------------------------------------------------=====
# HYDE HISTORICAL DOCK SWITCH
#
# Retain the former dock/lid display helper as reference material. Connector
# names and monitor syntax require review before any future reuse.
# =====--------------------------------------------------------------------=====

if [[ "$(hyprctl monitors)" =~ "\sDP-[0-9]+" ]]; then
  if [[ $1 == "open" ]]; then
    hyprctl keyword monitor "eDP-1, 2560x1600x60, -1920, 1.333333"
  else
    hyprctl keyword monitor "eDP-1, disable"
  fi
fi