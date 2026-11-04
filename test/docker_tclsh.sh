#!/bin/sh
# tclsh inside the OpenCCU test container, with the test environment passed through
set -- "$@"
envs=""
for v in HUE_TEST HUE_TEST_DIR HUE_ADDON_DIR HUE_CONF HUE_LOG_FILE HUED_PORT HUED_ADDRESS HUE_LOCK_PORT LANGUAGE \
	QUERY_STRING REQUEST_METHOD CONTENT_LENGTH HUE_UPDATE_URL HUE_UPDATE_DIR HUE_FLOW_BACKUP_DIR; do
	eval "val=\${$v+x}"
	[ -n "$val" ] && envs="$envs -e $v"
done
exec docker exec -i $envs "${DOCKER_CCU}" tclsh "$@"
