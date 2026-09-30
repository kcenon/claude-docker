# Resource Requirements

Each container **defaults** to a 4 GB memory limit (2 GB reserved), 2 CPU limit
(1 CPU reserved). These are configuration defaults, not measurements; both
generators set them (`scripts/generate-compose.sh`,
`scripts/generate-compose.ps1`). Override per installation in `.env`:

```env
CONTAINER_CPU_LIMIT=2
CONTAINER_CPU_RESERVATION=1
CONTAINER_MEM_LIMIT=4G
CONTAINER_MEM_RESERVATION=2G
```

Re-run `scripts/generate-compose.sh` (or `.ps1`) after changing these so the
generated compose files pick up the new values.

## Node heap headroom

The container memory limit caps *everything* inside the container. The Node
old-space limit caps only the JavaScript heap, and the two are not the same
budget: V8's other heap spaces, native allocations from node modules, every
subprocess an agent spawns (git, ripgrep, package managers, compilers) and the
page cache for the bind mounts all draw on the container limit as well.

A heap allowed to reach the cap on its own is therefore OOM-killed before V8
ever reaches the ceiling that would have made it collect garbage instead — and
an OOM kill is the less useful of the two failures, since it takes the whole
container down with no JavaScript stack.

The generator derives the heap from the cap rather than setting it beside it:

| `CONTAINER_MEM_LIMIT` | Reserved | `--max-old-space-size` |
|:---|:---|:---|
| 1G | 512 MiB | 512 |
| 2G | 512 MiB | 1536 |
| 4G (default) | 1024 MiB | 3072 |
| 8G | 2048 MiB | 6144 |
| 16G | 4096 MiB | 12288 |

The reservation is a quarter of the cap, with a floor of 512 MiB — a flat
percentage collapses to nothing on small caps, where the fixed costs do not
shrink along with the cap. **This is a convention, not a measurement**: no
steady-state non-heap footprint has been measured for these containers yet, so
the number is stated as a convention on purpose, to be replaced by a measured
one rather than reinterpreted.

Override it with `CONTAINER_NODE_HEAP_MB` (in MiB, the unit
`--max-old-space-size` actually uses). An explicit value is checked against the
cap, and a combination leaving less than 512 MiB free is refused when compose
files are generated — before any container starts — rather than at run time:

```
$ CONTAINER_NODE_HEAP_MB=4096 scripts/generate-compose.sh
Error: the Node heap limit does not leave enough of the container memory cap free.
       CONTAINER_MEM_LIMIT=4G is 4096 MiB; a 4096 MiB heap leaves 0 MiB, and at least 512 MiB is required.
       Set CONTAINER_NODE_HEAP_MB to at most 3584, or raise CONTAINER_MEM_LIMIT.
```

Installations that generated compose files before this existed carried a
4096 MiB heap under a 4 GiB cap — exactly zero headroom. Regenerating lowers it
to 3072 MiB. That is a deliberate change of an existing default rather than a
preserved one.

## Memory per instance count

Recommended, based on the 4 GB per-container default; adjust to your workload.

The table below assumes defaults. Docker RAM is the recommended Docker Desktop
memory allocation to allow all containers to run at peak load.

| Instances | Docker RAM (recommended) | Host RAM (Linux / macOS / Windows) |
|:---------:|:------------------------:|:----------------------------------:|
| 2 | 8 GB | 12 / 12 / 12 GB |
| 3 | 12 GB | 16 / 16 / 16 GB |
| 4 | 16 GB | 20 / 20 / 20 GB |
| 5 | 20 GB | 24 / 24 / 24 GB |
| 6+ | N x 4 GB | (N x 4) + 4 GB |
