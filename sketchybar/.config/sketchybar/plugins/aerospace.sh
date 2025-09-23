#!/usr/bin/env bash

# Debug of variables passed to the script:
echo "Script called with: NAME=$NAME, FOCUSED_WORKSPACE=$FOCUSED_WORKSPACE, Arg1=$1" >>/tmp/aerospace-debug.log

if [ "$1" = "$FOCUSED_WORKSPACE" ]; then
    sketchybar --set $NAME background.drawing=on \
        background.color=0xff007acc \
        label.color=0xffffffff
else
    sketchybar --set $NAME background.drawing=off \
        background.color=0x00000000 \
        label.color=0xff888888
fi
