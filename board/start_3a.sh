#!/bin/sh
# Wait for the ISP video node, then start the 3A server
n=0
while [ ! -e /dev/video11 ] && [ $n -lt 30 ]; do
  sleep 1
  n=$((n+1))
done
sleep 2
exec /oem/usr/bin/rkaiq_3A_server
