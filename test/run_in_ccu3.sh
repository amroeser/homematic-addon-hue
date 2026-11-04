#!/bin/sh -e
# Runs the test suite with the Tcl 8.2 interpreter of the CCU3 firmware.
#   test/run_in_ccu3.sh <path to an eq-3/occu checkout>
# Uses arm-gnueabihf-gcc8/packages-eQ-3/WebUI (tclsh, libtcl8.2.so, tcl8.2 library)
# from https://github.com/eq-3/occu in an emulated linux/arm/v7 Debian container.
cd "$(dirname "$0")/.."
occu="$(cd "$1" && pwd)/arm-gnueabihf-gcc8/packages-eQ-3/WebUI"
[ -x "$occu/bin/tclsh" ] || { echo "tclsh not found in $occu"; exit 1; }
name=hue-addon-ccu3
root="$(pwd)"
docker rm -f $name >/dev/null 2>&1 || true
docker run -d --name $name --platform linux/arm/v7 --add-host host.docker.internal:host-gateway -p 19190:19190 \
	-v "$root:$root" -v "$occu:/opt/occu:ro" --entrypoint /bin/sh debian:bookworm-slim -c 'sleep infinity' >/dev/null
trap 'docker rm -f $name >/dev/null' EXIT
docker exec $name sh -c 'apt-get update -qq >/dev/null && apt-get install -y -qq curl openssl procps >/dev/null 2>&1'
docker exec $name sh -c 'printf "#!/bin/sh\nLD_LIBRARY_PATH=/opt/occu/lib TCL_LIBRARY=/opt/occu/lib/tcl8.2 exec /opt/occu/bin/tclsh \"\$@\"\n" > /usr/local/bin/tclsh && chmod 755 /usr/local/bin/tclsh && ln -sf /usr/local/bin/tclsh /bin/tclsh'
echo 'puts "CCU3: Tcl [info patchlevel], encoding [encoding system]"' | docker exec -i $name tclsh
DOCKER_CCU=$name python3 -W ignore test/test_addon.py
