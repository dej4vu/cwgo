# Kitex v0.15.4 generation and interoperability check

Date: 2026-09-01

This note records a local compatibility comparison between the archived upstream `cwgo v0.1.2`
generator and this fork's upgraded generator. The fork embeds Kitex `v0.15.4`; upstream `v0.1.2`
embeds Kitex `v0.9.1`. The test is intentionally small so that wire-format, generated-code, and
runtime differences are easy to inspect.

Hertz generation is not covered here. The protobuf `replace` pin in this fork is also unchanged and
is a separate hz/protobuf compatibility issue.

## Test scope

The fixture is a minimal unary protobuf service:

```proto
service GreetService {
  rpc Hello(HelloRequest) returns (HelloResponse) {}
}
```

Both generators used the default Kitex server template and module name `example.com/greet`. The
comparison covered three levels:

1. generated file set and source diff;
2. full generated project `go build` / `go test`;
3. real TCP calls between old and new generated clients and servers.

The tested runtime versions were Kitex `v0.9.1` and `v0.15.4`. The local Go version was `1.26.3`.

## Reproduce

Point the two environment variables at the two cwgo binaries and run:

```bash
OLD_CWGO=/path/to/old-cwgo-v0.1.2 \
NEW_CWGO=/path/to/fork-cwgo \
  ./test/compat/kitex-greet/run.sh
```

The script writes all generated projects, logs, and binaries under:

```text
output/compat/kitex-greet/<timestamp>/
```

That directory is ignored by git. It deliberately does not use `/tmp`, so failed runs remain
inspectable beside the repository.

## Generated-code differences

The new generator produces a smaller and cleaner protobuf service tree:

| Area | Upstream cwgo / Kitex v0.9.1 | Fork / Kitex v0.15.4 |
|---|---|---|
| FastPB message file | `greet.pb.fast.go` is generated | no longer generated |
| `invoker.go` | generated | no longer generated |
| service wrapper import | `google.golang.org/protobuf/proto` | `github.com/cloudwego/prutal` |
| Args/Result methods | `FastRead`, `FastWrite`, `Size` | removed |
| service/version markers | Kitex `v0.9.1` | Kitex `v0.15.4` |

The protobuf message definitions themselves and the generated `client.go` / `server.go` APIs are
otherwise materially unchanged for this fixture. Small default-template changes were also observed:
the service constructor comment is now separated from the struct declaration, and generated config
code uses `gopkg.in/yaml.v3` instead of `yaml.v2`.

The removal of FastPB code is the expected Kitex v0.15 behavior. Keeping the old generator default
while upgrading Kitex runtime can therefore leave generated code referring to methods that no longer
exist; the fork now forces protobuf generation to `NoFastAPI=true`, matching the upstream Kitex CLI
behavior.

## Full-template build result

After allowing the generated project to use current serialization dependencies, both full generated
projects passed:

```bash
go build ./...
go test ./...
```

Dependency observations:

| Generated project | Kitex runtime | Sonic | Dynamicgo |
|---|---:|---:|---:|
| upstream cwgo `v0.1.2` default template | `v0.11.3` | `v1.15.3` | `v0.4.0` |
| fork default template | `v0.15.4` | `v1.15.3` | `v0.9.2` |

The upstream default template does not necessarily compile against its embedded generator version
because its template dependency graph can raise the resolved Kitex version. This is why the interop
test below pins the runtime explicitly.

Sonic `v1.15.3` works with the local Go `1.26.3` toolchain. Earlier failures seen while preparing
this note were caused by older dependency resolution, not by Sonic's modern Go support. The fork
default template also needed Dynamicgo `v0.9.2` for a clean Go `1.26.3` link.

## Runtime interoperability matrix

The script builds two minimal modules containing only the generated `kitex_gen` tree and one
server/client entry point. It pins the old side to Kitex `v0.9.1` and the new side to Kitex
`v0.15.4`, then starts each server on loopback and calls it with both clients.

Each cell reuses one client connection and performs 20 calls:

| Client | Server | Result |
|---|---|---|
| Kitex `v0.9.1` | Kitex `v0.9.1` | 20/20 OK |
| Kitex `v0.15.4` | Kitex `v0.9.1` | 20/20 OK |
| Kitex `v0.9.1` | Kitex `v0.15.4` | 20/20 OK |
| Kitex `v0.15.4` | Kitex `v0.15.4` | 20/20 OK |

Every response was exactly `hello kitex`; the script prints `MATRIX_OK` only after all four
directions pass. This supports default protobuf unary RPC compatibility across the tested generator
and runtime boundary.

## Limitations

This fixture does not prove every production feature is compatible. In particular, it does not
cover streaming, custom transports, mux configurations, gRPC transports, service discovery, retries,
circuit breaking, or Lemon's business handlers. It is a fast regression gate before running a real
project IDL and test-environment smoke tests.
