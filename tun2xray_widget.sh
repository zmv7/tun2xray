#!/bin/bash

if [[ $1 == "status" ]]; then
    if systemctl is-active --quiet tun2xray.service; then
        echo "T2X:1"
    else
        echo "T2X:0"
    fi
elif [[ $1 == "toggle" ]]; then
    if systemctl is-active --quiet tun2xray.service; then
        systemctl stop tun2xray
    else
        systemctl start tun2xray
    fi
fi
