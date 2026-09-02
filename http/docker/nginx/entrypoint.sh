#!/bin/sh
set -e

/usr/local/bin/hello --address 127.0.0.1 --port 8090 &

exec nginx -g "daemon off;"
