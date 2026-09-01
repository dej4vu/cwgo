#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/test/compat/kitex-greet"

OLD_CWGO="${OLD_CWGO:?set OLD_CWGO to the archived cwgo v0.1.2 binary}"
NEW_CWGO="${NEW_CWGO:?set NEW_CWGO to the fork cwgo binary}"
COMPAT_WORK_ROOT="${COMPAT_WORK_ROOT:-$REPO_ROOT/output/compat/kitex-greet/$(date +%Y%m%d-%H%M%S)}"

OLD_KITEX_VERSION="${OLD_KITEX_VERSION:-v0.9.1}"
NEW_KITEX_VERSION="${NEW_KITEX_VERSION:-v0.15.4}"
OLD_FULL_KITEX_VERSION="${OLD_FULL_KITEX_VERSION:-v0.11.3}"
NEW_FULL_KITEX_VERSION="${NEW_FULL_KITEX_VERSION:-v0.15.4}"
OLD_FASTPB_VERSION="${OLD_FASTPB_VERSION:-v0.0.4}"
PRUTAL_VERSION="${PRUTAL_VERSION:-v0.1.3}"
PROTOBUF_OLD_VERSION="${PROTOBUF_OLD_VERSION:-v1.28.1}"
SONIC_VERSION="${SONIC_VERSION:-v1.15.3}"
DYNAMICGO_NEW_VERSION="${DYNAMICGO_NEW_VERSION:-v0.9.2}"
DYNAMICGO_OLD_VERSION="${DYNAMICGO_OLD_VERSION:-v0.4.0}"
PID_VERSION="${PID_VERSION:-v0.0.24}"

OLD_ADDR="${OLD_ADDR:-127.0.0.1:19101}"
NEW_ADDR="${NEW_ADDR:-127.0.0.1:19102}"
CALL_COUNT="${CALL_COUNT:-20}"

for binary in "$OLD_CWGO" "$NEW_CWGO"; do
	if [[ ! -x "$binary" ]]; then
		echo "cwgo binary is not executable: $binary" >&2
		exit 2
	fi
done

mkdir -p "$COMPAT_WORK_ROOT"
echo "work root: $COMPAT_WORK_ROOT"

server_pid=""
cleanup() {
	if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

generate_full() {
	local variant="$1"
	local binary="$2"
	local dir="$COMPAT_WORK_ROOT/$variant"

	echo "==> generate full $variant project"
	mkdir -p "$dir"
	(
		cd "$dir"
		if [[ ! -f go.mod ]]; then
			go mod init example.com/greet
		fi
		"$binary" server \
			--type RPC \
			--service greet \
			--module example.com/greet \
			-I "$FIXTURE_DIR" \
			--idl "$FIXTURE_DIR/greet.proto"
	)
}

verify_full() {
	local variant="$1"
	local dir="$COMPAT_WORK_ROOT/$variant"

	echo "==> build and test full $variant project"
	(
		cd "$dir"
		go mod tidy
		go build ./...
		go test ./...
	)
}

upgrade_full_dependencies() {
	local variant="$1"
	local dir="$COMPAT_WORK_ROOT/$variant"

	echo "==> upgrade serialization dependencies for $variant"
	(
		cd "$dir"
		if [[ "$variant" == "old" ]]; then
			go get "github.com/cloudwego/kitex@$OLD_FULL_KITEX_VERSION"
		else
			go get \
				"github.com/cloudwego/kitex@$NEW_FULL_KITEX_VERSION" \
				"github.com/cloudwego/prutal@$PRUTAL_VERSION"
		fi
		go get "github.com/bytedance/sonic@$SONIC_VERSION"
		if [[ "$variant" == "new" ]]; then
			go get "github.com/cloudwego/dynamicgo@$DYNAMICGO_NEW_VERSION"
		fi
		go mod tidy
	)
}

prepare_interop() {
	local variant="$1"
	local source_dir="$COMPAT_WORK_ROOT/$variant"
	local dir="$COMPAT_WORK_ROOT/interop-$variant"

	echo "==> prepare minimal interop module for $variant"
	mkdir -p "$dir"
	cp -R "$source_dir/kitex_gen" "$dir/kitex_gen"
	cp "$FIXTURE_DIR/interop_main.go.tmpl" "$dir/main.go"

	(
		cd "$dir"
		if [[ ! -f go.mod ]]; then
			go mod init example.com/greet
		fi
		if [[ "$variant" == "old" ]]; then
			go get \
				"github.com/cloudwego/kitex@$OLD_KITEX_VERSION" \
				"github.com/cloudwego/fastpb@$OLD_FASTPB_VERSION" \
				"google.golang.org/protobuf@$PROTOBUF_OLD_VERSION" \
				"github.com/choleraehyq/pid@$PID_VERSION" \
				"github.com/bytedance/sonic@$SONIC_VERSION" \
				"github.com/cloudwego/dynamicgo@$DYNAMICGO_OLD_VERSION"
			go mod edit \
				-replace="github.com/choleraehyq/pid=github.com/choleraehyq/pid@$PID_VERSION" \
				-replace="github.com/bytedance/sonic=github.com/bytedance/sonic@$SONIC_VERSION" \
				-replace="github.com/cloudwego/dynamicgo=github.com/cloudwego/dynamicgo@$DYNAMICGO_OLD_VERSION"
		else
			go get \
				"github.com/cloudwego/kitex@$NEW_KITEX_VERSION" \
				"github.com/cloudwego/prutal@$PRUTAL_VERSION" \
				"github.com/bytedance/sonic@$SONIC_VERSION" \
				"github.com/cloudwego/dynamicgo@$DYNAMICGO_NEW_VERSION"
		fi
		go mod tidy
		go build -o greet-interop .
	)
}

start_server() {
	local variant="$1"
	local dir="$COMPAT_WORK_ROOT/interop-$variant"
	local addr="$2"
	local log="$COMPAT_WORK_ROOT/$variant-server.log"

	cleanup
	"$dir/greet-interop" -mode server -addr "$addr" >"$log" 2>&1 &
	server_pid=$!
	sleep 1
	if ! kill -0 "$server_pid" 2>/dev/null; then
		echo "server $variant failed to start; log: $log" >&2
		exit 1
	fi
}

call_server() {
	local client_variant="$1"
	local server_variant="$2"
	local dir="$COMPAT_WORK_ROOT/interop-$client_variant"
	local addr="$3"

	printf 'CALL client=%s server=%s ... ' "$client_variant" "$server_variant"
	local result
	if result=$("$dir/greet-interop" -mode client -addr "$addr" -count "$CALL_COUNT"); then
		echo "$result"
	else
		echo "FAILED" >&2
		return 1
	fi
}

generate_full old "$OLD_CWGO"
generate_full new "$NEW_CWGO"
upgrade_full_dependencies old
upgrade_full_dependencies new
verify_full old
verify_full new

prepare_interop old
prepare_interop new

start_server old "$OLD_ADDR"
call_server old old "$OLD_ADDR"
call_server new old "$OLD_ADDR"
cleanup

start_server new "$NEW_ADDR"
call_server old new "$NEW_ADDR"
call_server new new "$NEW_ADDR"
cleanup

echo "MATRIX_OK"
