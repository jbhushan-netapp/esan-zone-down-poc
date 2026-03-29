# Azure Elastic SAN Zone-Down Failover POC

Proof-of-concept demonstrating high availability for Azure Elastic SAN iSCSI
shared volumes using SCSI Persistent Reservations (PR). A primary VM holds
exclusive write reservations on a set of shared volumes. If the primary fails,
a secondary VM detects the failure and takes over the reservations within
milliseconds. When the primary recovers it preempts the secondary and reclaims
ownership, and the secondary cleanly returns to standby.

## Architecture

```
┌──────────────┐   TCP heartbeat (port 4000)    ┌──────────────┐
│  Primary VM  │ ─────────────────────────────► │ Secondary VM │
│  (Zone 1)    │                                │  (Zone 2)    │
└──────┬───────┘                                └──────┬───────┘
       │  write timestamps                             │  read timestamps
       │  SCSI PR: Write Exclusive                     │  SCSI PR: registered
       │  (Registrants Only, type 5)                   │  (standby)
       ▼                                               ▼
┌─────────────────────────────────────────────────────────────┐
│              Azure Elastic SAN  (Premium_ZRS)               │
│  vol-01 ── vol-02 ── vol-03 ── ... ── vol-10  (iSCSI)       │
└─────────────────────────────────────────────────────────────┘
```

## Azure Resources

| Resource | Name | Details |
|---|---|---|
| Resource Group | `jbhushan-zone-down-poc-rg` | East US 2 |
| Elastic SAN | `jbhushan-zrs-esan` | Premium_ZRS, 1 TiB |
| Volume Group | `jbhushan-zrs-vg` | iSCSI protocol |
| Volumes | `jbhushan-zrs-vol-01` to `vol-10` | 1 GiB each |
| Primary VM | `jbhushan-zrs-primary` | Zone 1 |
| Secondary VM | `jbhushan-zrs-secondary` | Zone 2 |

## Heartbeat Channels

Two independent channels detect primary failure:

1. **TCP heartbeat** — The primary streams UTC timestamps to the secondary
   over a persistent TCP connection on port 4000 (one message per second,
   null-delimited).

2. **Disk heartbeat** — The primary writes a prefixed timestamp
   (`primary:<timestamp>`) to block offset 0 of every shared volume once per
   second using `O_DIRECT`. The secondary reads each volume in parallel and
   compares timestamps.

The secondary initiates a takeover **only when both channels are stale** past
the configured timeout (default 10s). This avoids false positives from
transient network blips or individual disk hiccups.

## SCSI Persistent Reservations

Each volume uses **Write Exclusive, Registrants Only (type 5)** reservations
via `sg_persist`:

- **Primary key**: `0x1000`
- **Secondary key**: `0x2000`

Both VMs register their keys on all volumes at startup. The primary acquires
the reservation. If the reservation is already held by the other party, it
preempts it.

## Programs

### `primary_main.go`

Runs on the primary VM. On startup it:

1. Disables kernel read-ahead on every device
2. Registers its PR key and acquires (or preempts) the reservation on all
   devices in parallel
3. Launches one goroutine per device to write `primary:<timestamp>` every
   second
4. Connects to the secondary on TCP port 4000 and streams timestamps

```
./primary \
  --devices /dev/sda,/dev/sdb,...,/dev/sdj \
  --remote-ip 10.163.0.5 \
  --pr-key 0x1000 \
  --log-file /var/log/poc/primary.log
```

### `secondary_main.go`

Runs on the secondary VM. It operates as a state machine:

```
  ┌─────────┐   both channels stale    ┌──────────┐
  │ Standby │ ────────────────────────►│ Takeover │
  │(monitor)│                          │(preempt) │
  └────▲────┘                          └────┬─────┘
       │                                    │
       │  write failures detected           │  reservations acquired
       │  (preempted by primary)            ▼
       │                              ┌──────────┐
       └──────────────────────────────│  Active  │
                                      │ (writing)│
                                      └──────────┘
```

1. **Standby** — Listens on TCP port 4000, reads disk timestamps from all
   devices. If both channels are stale for `--timeout` duration, triggers
   takeover.
2. **Takeover** — Preempts the primary's reservation and acquires exclusive
   access on all devices in parallel. Logs a detailed report.
3. **Active** — Writes `secondary:<timestamp>` to all devices. When the
   primary recovers and preempts back, write failures are detected
   (3 consecutive per device). Once all devices report failures, transitions
   back to standby.

```
./secondary \
  --devices /dev/sda,/dev/sdb,...,/dev/sdj \
  --pr-key 0x2000 \
  --timeout 10s \
  --log-file /var/log/poc/secondary.log
```

## Systemd Services

All services auto-start on boot and are installed on both VMs.

| Service | Purpose |
|---|---|
| `iscsi-esan.service` | Logs in to all 10 iSCSI targets on boot, logs out on stop |
| `iptables-poc.service` | Opens TCP port 4000 in iptables |
| `zonedown-primary.service` | Runs the primary program (Zone-1 VM only) |
| `zonedown-secondary.service` | Runs the secondary program with a 30 s startup delay (Zone-2 VM only) |

The 30-second delay on the secondary ensures the primary has time to
establish its reservations when both VMs boot simultaneously.

### Log Management

Logs are written to `/var/log/poc/` and managed by the Go programs themselves
(not systemd). On each service restart, the existing log file is renamed with
a timestamp suffix (e.g., `primary.log.20260329T223622`) before a new one is
created.

## Cache Bypass

Three layers prevent stale cached reads on iSCSI block devices:

1. **`O_DIRECT`** — All reads and writes bypass the kernel page cache
2. **`posix_fadvise(FADV_DONTNEED)`** — Evicts cached pages after each read
3. **`read_ahead_kb = 0`** — Disables kernel read-ahead per device via sysfs

## Experiment: Zone-Down Failover

### Setup

1. Both VMs are running with all 10 iSCSI volumes connected
2. Primary holds reservations on all volumes, writing heartbeats
3. Secondary is in standby, monitoring both channels

### Test 1: Primary Failure

**Action**: Stop or deallocate the primary VM.

**Expected behavior**:
- TCP heartbeats stop immediately
- Disk heartbeats stop (last written timestamp goes stale)
- After 10 seconds, secondary detects both channels stale
- Secondary preempts all 10 reservations in parallel
- Secondary begins writing `secondary:<timestamp>` to all volumes

**Expected log output** (secondary):
```
=== TAKEOVER STARTED ===
both heartbeat channels lost — tcp: 11s, disk: 10s (threshold 10s)
=== TAKEOVER COMPLETE — now acting as primary ===
=== TAKEOVER REPORT ===
  last tcp heartbeat at:  2026-03-29T23:21:30Z
  last disk heartbeat at: 2026-03-29T23:21:31Z
  tcp channel stale for:  11.584s
  disk channel stale for: 10.228s
  timeout threshold:      10s
  failure detected at:    2026-03-29T23:21:41Z
  [/dev/sda] acquired (16ms)
  [/dev/sdb] acquired (17ms)
  ...
  [/dev/sdj] acquired (16ms)
  total takeover time:    26ms
  takeover completed at:  2026-03-29T23:21:41Z
=======================
```

Typical total takeover time: **20–30 ms** for all 10 volumes.

### Test 2: Primary Recovery (Failback)

**Action**: Start the primary VM again.

**Expected behavior**:
- Primary boots, iSCSI reconnects, service starts
- Primary detects reservations held by secondary (`0x2000`), preempts all 10
- Primary begins writing `primary:<timestamp>` and reconnects TCP
- Secondary detects write failures on all devices (3 consecutive each)
- Secondary logs `PREEMPTED — returning to standby`
- Secondary re-registers its key and resumes monitoring

**Expected log output** (primary):
```
managing 10 devices: [/dev/sda /dev/sdb ... /dev/sdj]
=== ALL 10 DEVICES ACQUIRED in 35ms ===
connected to 10.163.0.5:4000
```

**Expected log output** (secondary):
```
[/dev/sda] write failed (1/3): write /dev/sda: invalid exchange
[/dev/sda] write failed (2/3): write /dev/sda: invalid exchange
[/dev/sda] write failed (3/3): write /dev/sda: invalid exchange
[/dev/sda] preempted
...
all devices preempted — stopping writes
=== PREEMPTED — returning to standby ===
re-registered reservation key on 10 devices
monitoring primary with 10s timeout across 10 devices (both channels must fail)
```

### Test 3: Simultaneous Boot

**Action**: Start both VMs at the same time.

**Expected behavior**:
- Primary boots and acquires all reservations (no contention — fresh volumes)
- Secondary boots 30 seconds later (startup delay), registers keys, enters
  monitoring mode
- System reaches steady state with primary writing and secondary monitoring

## Repository Structure

```
├── README.md
├── primary_main.go          # Primary VM program
├── secondary_main.go        # Secondary VM program
├── systemd/
│   ├── iscsi-esan.service         # iSCSI login/logout on boot
│   ├── iptables-poc.service       # Open TCP port 4000
│   ├── zonedown-primary.service   # Primary heartbeat service
│   └── zonedown-secondary.service # Secondary monitor service
└── scripts/
    ├── setup-azure-infra.sh  # Create Elastic SAN, volumes (run once)
    ├── setup-vm.sh           # Install packages, connect iSCSI, deploy services
    ├── monitor.sh            # Check status locally on a VM
    └── monitor-remote.sh     # Check status remotely via az vm run-command
```

## Quick Start

### 1. Create Azure infrastructure

```bash
./scripts/setup-azure-infra.sh
```

This creates the Elastic SAN, volume group, and 10 volumes. VMs must be
created separately (e.g., via the portal or CLI) in different availability
zones.

### 2. Set up each VM

Copy this repo to both VMs, then run:

```bash
# On the primary VM:
./scripts/setup-vm.sh --role primary --remote-ip <SECONDARY_IP> \
  --portal es-n4zhdze1aa20.z2.blob.storage.azure.net:3260

# On the secondary VM:
./scripts/setup-vm.sh --role secondary \
  --portal es-n4zhdze1aa20.z2.blob.storage.azure.net:3260
```

### 3. Start services

```bash
systemctl start iscsi-esan iptables-poc zonedown-primary   # on primary
systemctl start iscsi-esan iptables-poc zonedown-secondary  # on secondary
```

### 4. Monitor

```bash
# Locally on a VM:
./scripts/monitor.sh
./scripts/monitor.sh --takeover-events

# Remotely via Azure CLI:
./scripts/monitor-remote.sh
./scripts/monitor-remote.sh --takeover
./scripts/monitor-remote.sh --secondary
```

## Building

Requires Go 1.21+ and `sg3-utils` on the target VMs.

```bash
# On a machine with Go installed:
GOOS=linux GOARCH=amd64 go build -o primary primary_main.go
GOOS=linux GOARCH=amd64 go build -o secondary secondary_main.go

# On Azure VMs with Microsoft Go fork:
export GOEXPERIMENT=ms_nocgo_opensslcrypto CGO_ENABLED=0
go build -o primary primary_main.go
go build -o secondary secondary_main.go
```

## Dependencies

- `sg3-utils` — provides `sg_persist` for SCSI PR operations
- `open-iscsi` — provides `iscsiadm` for iSCSI target management
- `iptables` — for TCP port 4000 firewall rules
- Go 1.21+ — for building the programs
