#!/bin/sh -e
# Runs the test suite with the addon's Tcl code inside an OpenCCU container.
#   test/run_in_openccu.sh <openccu image>   e.g. ghcr.io/openccu/openccu:arm64-3.89.11.20260919
# The image comes from the OpenCCU release assets (OpenCCU-<version>-oci_<arch>.tgz, "docker load -i").
cd "$(dirname "$0")/.."
image="$1"
name=hue-addon-test
root="$(pwd)"
docker rm -f $name >/dev/null 2>&1 || true
docker run -d --name $name --add-host host.docker.internal:host-gateway -p 19190:19190 \
	-v "$root:$root" --entrypoint /bin/sh "$image" -c 'sleep infinity' >/dev/null
trap 'docker rm -f $name >/dev/null' EXIT
echo 'puts "OpenCCU: Tcl [info patchlevel], json [package require json], encoding [encoding system]"' | docker exec -i $name tclsh
DOCKER_CCU=$name python3 -W ignore test/test_addon.py
