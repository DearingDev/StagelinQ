# StagelinQ

A PowerShell module for communicating with Denon DJ hardware over the **StagelinQ** protocol.

StagelinQ is a proprietary network protocol used by Denon DJ devices (SC5000, SC6000, Prime Go+, etc.) to broadcast their presence on a local network and expose services — including a **StateMap** service that streams real-time deck state (track title, BPM, waveform position, and more) and a **BeatInfo** service that emits sub-millisecond beat phase data.

---

## Prerequisites

- PowerShell 7.0 or later
- The DJ device must be on the same network segment as your machine (discovery uses UDP broadcast on port 51337)

---

## Importing the module

```powershell
Import-Module ./StagelinQ/StagelinQ.psd1
```

---

## How it works

StagelinQ has two phases:

1. **Discovery** — your machine and the device exchange UDP broadcast frames on port 51337. Each side announces itself with a software name and a 16-byte random token. Once you see the device you want, you know its IP address and the TCP port for its directory server.

2. **Directory handshake** — you connect to the device's TCP directory server, which sends a list of named services (e.g. `StateMap`, `BeatInfo`) and the port each one listens on.

From there you connect to individual services to subscribe to state changes.

---

## Quick start

### One-liner session (recommended)

The highest-level entry point. Discovers the device, starts both streams, launches the REST API, and optionally opens a browser dashboard — all in one call.

```powershell
Import-Module ./StagelinQ/StagelinQ.psd1

$session = Start-StagelinQSession -OpenBrowser
# ... do work, or just let it run ...
Stop-StagelinQSession -Session $session
```

### Demo mode (no hardware required)

Seeds realistic mock state and animates beat phase data so the dashboard looks live without a real device connected. Great for development and presentations.

```powershell
$session = Start-StagelinQSession -DemoMode -OpenBrowser
Stop-StagelinQSession -Session $session
```

### Manual pipeline

For fine-grained control, wire up each layer yourself:

```powershell
Import-Module ./StagelinQ/StagelinQ.psd1

# 1. Discover and connect
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'

# 2. Start background streams (StateMap + BeatInfo) into shared state
$streams = Start-StagelinQStreams -Device $device
Start-Sleep -Seconds 2   # let the initial burst of state arrive

# 3. Snapshot what we have so far
Get-StagelinQSnapshot | Format-Table -AutoSize

# 4. Launch the REST API (port 8080 by default)
$api = Start-StagelinQApi -Port 8080

# 5. Tear everything down cleanly
Stop-StagelinQApi     -Api     $api
Stop-StagelinQStreams -Streams $streams
Disconnect-StagelinQDevice -Device $device
```

---

## Function reference

### Session (high-level)

| Function | What it does |
|---|---|
| `Start-StagelinQSession` | Full pipeline in one call: discover, connect, start streams, start API, optionally open browser. Returns a session handle. |
| `Stop-StagelinQSession` | Tears down all session resources in the correct order (API → animator → streams → device). |

#### Examples

```powershell
# Real hardware, default port 8080
$s = Start-StagelinQSession -TargetSoftwareName 'JP11S' -OpenBrowser
Stop-StagelinQSession -Session $s

# Demo mode with a custom port
$s = Start-StagelinQSession -DemoMode -Port 9000 -OpenBrowser
Stop-StagelinQSession -Session $s

# Suppress all progress output (e.g. in a script)
$s = Start-StagelinQSession -DemoMode -Quiet
Start-Sleep -Seconds 30
Stop-StagelinQSession -Session $s

# Bring your own dashboard.html
$s = Start-StagelinQSession -DashboardHtmlPath C:\custom\dashboard.html -OpenBrowser
Stop-StagelinQSession -Session $s
```

---

### Discovery and connection

| Function | What it does |
|---|---|
| `Find-StagelinQDevice` | Broadcasts UDP announcements and waits for a specific device to respond. Returns a discovery frame with the device's IP and directory port. |
| `Connect-StagelinQDevice` | Calls `Find-StagelinQDevice`, completes the TCP directory handshake, and starts a background keepalive. Returns a `$device` object. |
| `Disconnect-StagelinQDevice` | Sends a goodbye announcement, stops the background keepalive, and closes all sockets. |
| `Send-StagelinQAnnouncement` | Sends a single UDP discovery broadcast (used internally; useful for testing). |
| `Read-DiscoveryFrame` | Parses raw UDP bytes into a structured discovery frame object. |

#### Examples

```powershell
# Basic connect + disconnect
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
Disconnect-StagelinQDevice -Device $device

# Longer discovery timeout (slow network)
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S' -TimeoutSeconds 30

# Discover only (no handshake) — useful for fingerprinting unknown devices
$frame = Find-StagelinQDevice -TargetSoftwareName 'JP11S' -TimeoutSeconds 10
Write-Host "Found $($frame.DeviceName) at $($frame.SourceAddress) on port $($frame.ServicePort)"

# See all available services after connecting
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
Get-StagelinQService -Device $device | Format-Table -AutoSize

# Look up a specific service port
$port = Get-StagelinQService -Device $device -Name 'StateMap'
Write-Host "StateMap is on port $port"
```

---

### Streams (background runspaces)

| Function | What it does |
|---|---|
| `Start-StagelinQStreams` | Starts StateMap and BeatInfo background runspaces that write into the shared state dictionary. Returns a handle. |
| `Stop-StagelinQStreams` | Stops and disposes both background runspaces. |
| `Get-StagelinQSnapshot` | Returns a point-in-time copy of the shared state as a plain hashtable. Safe to iterate without locking. |

StateMap keys are stored verbatim (e.g. `/Engine/Deck1/CurrentBPM`). BeatInfo keys follow the pattern `BeatInfo/Deck<N>/Phase|BPM|BeatIndex`.

#### Examples

```powershell
# Start streams with default state paths
$device  = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
$streams = Start-StagelinQStreams -Device $device
Start-Sleep -Seconds 3
Get-StagelinQSnapshot | Format-Table -AutoSize
Stop-StagelinQStreams -Streams $streams
Disconnect-StagelinQDevice -Device $device

# Subscribe to custom paths
$streams = Start-StagelinQStreams -Device $device -StateMapPath @(
    '/Engine/Deck1/Track/SongName',
    '/Engine/Deck1/CurrentBPM',
    '/Engine/Deck1/PlayState',
    '/Engine/Deck2/Track/SongName',
    '/Engine/Deck2/CurrentBPM'
)

# Poll the snapshot on a 1-second loop
while ($true) {
    $snap = Get-StagelinQSnapshot
    Write-Host "D1: $($snap['/Engine/Deck1/Track/SongName'])  BPM: $($snap['/Engine/Deck1/CurrentBPM'])"
    Start-Sleep -Seconds 1
}

# Filter the snapshot — BeatInfo keys only
(Get-StagelinQSnapshot).GetEnumerator() |
    Where-Object Key -like 'BeatInfo/*' |
    Sort-Object Key |
    Format-Table Key, Value -AutoSize

# Filter — a specific deck
(Get-StagelinQSnapshot).GetEnumerator() |
    Where-Object Key -like '*Deck1*' |
    Sort-Object Key |
    Format-Table Key, Value -AutoSize
```

---

### StateMap (low-level)

| Function | What it does |
|---|---|
| `Connect-StagelinQStateMap` | Opens a TCP connection to the StateMap service and sends the connection frame. |
| `Register-StateMapPath` | Subscribes to one or more state paths. Accepts pipeline input. |
| `Read-StateMapValue` | Reads one buffer of StateMap messages and returns `Path` + `Value` objects. |
| `Watch-StagelinQState` | Registers paths and loops, calling a scriptblock on each update (or printing to host). Runs until Ctrl+C. |

#### Examples

```powershell
# Connect and watch a few paths (prints to host until Ctrl+C)
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
$sm     = Connect-StagelinQStateMap -Device $device

Watch-StagelinQState -Connection $sm -Path @(
    '/Engine/Deck1/Track/SongName',
    '/Engine/Deck1/CurrentBPM',
    '/Engine/Deck1/PlayState'
)

Disconnect-StagelinQDevice -Device $device

# Custom handler — log track changes to a file
Watch-StagelinQState -Connection $sm -Path '/Engine/Deck1/Track/SongName' -OnUpdate {
    param($update)
    "$([datetime]::Now)  $($update.Value)" | Add-Content -Path ~/track-log.txt
}

# Subscribe via pipeline
'/Engine/Deck1/CurrentBPM', '/Engine/Deck2/CurrentBPM' |
    Register-StateMapPath -Connection $sm

# Manual read loop with conditional exit
while ($true) {
    $updates = Read-StateMapValue -Connection $sm
    foreach ($u in $updates) {
        Write-Host "$($u.Path) = $($u.Value)"
        if ($u.Path -eq '/Engine/Deck1/PlayState' -and $u.Value -eq 'false') {
            Write-Host 'Deck 1 stopped — exiting.'
            break
        }
    }
}
```

---

### BeatInfo (low-level)

| Function | What it does |
|---|---|
| `Connect-StagelinQBeatInfo` | Opens a TCP connection to the BeatInfo service and sends the connection frame. |
| `Read-BeatInfoValue` | Reads one BeatInfo frame and returns a `Deck`, `BeatPhase`, `BPM`, and `BeatIndex` object. |
| `Watch-StagelinQBeatInfo` | Loops calling `Read-BeatInfoValue`, invoking a scriptblock on each frame (or printing to host). Runs until Ctrl+C. |

BeatPhase is a value between `0.0` and `1.0` representing how far through the current beat you are. BeatIndex increments by 1 on each beat.

#### Examples

```powershell
# Print raw beat frames to the host (Ctrl+C to stop)
$device = Connect-StagelinQDevice -TargetSoftwareName 'JP11S'
$bi     = Connect-StagelinQBeatInfo -Device $device
Watch-StagelinQBeatInfo -Connection $bi
Disconnect-StagelinQDevice -Device $device

# Custom handler — print only Deck 1, formatted
Watch-StagelinQBeatInfo -Connection $bi -OnUpdate {
    param($frame)
    if ($frame.Deck -eq 1) {
        $bar = '#' * [int]($frame.BeatPhase * 20)
        Write-Host "[$($bar.PadRight(20))]  BPM $($frame.BPM)  Beat $($frame.BeatIndex)"
    }
}

# Manual read loop — trigger a light on each beat
$lastBeat = -1
while ($true) {
    $frame = Read-BeatInfoValue -Connection $bi
    if ($frame.Deck -eq 1 -and $frame.BeatIndex -ne $lastBeat) {
        $lastBeat = $frame.BeatIndex
        # pulse a GPIO, send a MIDI note, etc.
        Write-Host "BEAT $lastBeat"
    }
}
```

---

### REST API

| Function | What it does |
|---|---|
| `Start-StagelinQApi` | Starts an `HttpListener` on the given port, serving the shared state dictionary as JSON endpoints. Returns an API handle. |
| `Stop-StagelinQApi` | Stops the listener and disposes its runspace. |

#### Endpoints

| Route | Description |
|---|---|
| `GET /health` | `{"status":"ok","uptime":<seconds>}` |
| `GET /state` | Full snapshot of all keys as JSON |
| `GET /state/{key}` | Single key value (URL-encode the key), 404 if missing |
| `GET /beats` | Only `BeatInfo/*` keys |
| `GET /decks` | StateMap keys grouped by deck number |
| `GET /dashboard` | Serves the pre-loaded `dashboard.html` (404 if no bytes were provided) |

All responses include `Access-Control-Allow-Origin: *`.

#### Examples

```powershell
# Start the API alongside active streams
$api = Start-StagelinQApi -Port 8080 -DashboardBytes ([IO.File]::ReadAllBytes('./dashboard.html'))
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/state | ConvertTo-Json
Invoke-RestMethod http://localhost:8080/beats | ConvertTo-Json
Invoke-RestMethod http://localhost:8080/decks | ConvertTo-Json
Stop-StagelinQApi -Api $api

# Query a single state key (path must be URL-encoded)
$key      = '/Engine/Deck1/Track/SongName'
$encoded  = [Uri]::EscapeDataString($key)
$response = Invoke-RestMethod "http://localhost:8080/state/$encoded"
Write-Host "Now playing: $response"

# Poll the API from a second terminal (no module import needed)
while ($true) {
    $state = Invoke-RestMethod http://localhost:8080/state
    Write-Host "D1: $($state.'/Engine/Deck1/Track/SongName')  D2: $($state.'/Engine/Deck2/Track/SongName')"
    Start-Sleep -Seconds 2
}

# Bind to all interfaces (requires elevation on Windows)
$api = Start-StagelinQApi -Port 8080 -Prefix 'http://+:8080/'
```

---

## Understanding the `$device` object

`Connect-StagelinQDevice` returns a `PSCustomObject` with these properties:

| Property | Description |
|---|---|
| `DeviceFrame` | The parsed discovery frame from the device |
| `Token` | Your 16-byte session token (byte array) |
| `SoftwareName` | The name your client announced itself as |
| `Services` | Hashtable of service name → TCP port |
| `TcpClient` / `Stream` | The open directory server connection |
| `AnnounceSocket` / `AnnounceRunspace` / `AnnounceJob` | Background keepalive — don't close these manually; use `Disconnect-StagelinQDevice` |

## Understanding the `$session` object

`Start-StagelinQSession` returns a `PSCustomObject` with these properties:

| Property | Description |
|---|---|
| `Device` | The `$device` object (null in DemoMode) |
| `Streams` | The `$streams` handle (null in DemoMode) |
| `Api` | The API handle from `Start-StagelinQApi` |
| `DemoPs` / `DemoRunspace` | Beat animator runspace (null when not in DemoMode) |
| `Port` | The TCP port the API is listening on |
| `DashboardUrl` | Full URL to the dashboard endpoint |
| `IsDemoMode` | `$true` if started with `-DemoMode` |
| `StartedAt` | UTC datetime the session was created |

---

## Troubleshooting

**`Find-StagelinQDevice` times out**
- Check that the device is powered on and connected to the same network segment.
- Confirm port 51337 UDP is not blocked by a firewall.
- Use a short `-TimeoutSeconds` to see any frame received, then inspect `$frame.SoftwareName` to find the correct value for `-TargetSoftwareName`.

**`Connect-StagelinQDevice` connects but `Services` is empty**
- The directory handshake has a 500ms drain window after the first service arrives. If the device is slow to respond, increase `-TimeoutSeconds`.

**`Watch-StagelinQState` receives no updates**
- Path strings are case-sensitive. Common paths: `/Engine/Deck1/Track/SongName`, `/Engine/Deck1/CurrentBPM`, `/Engine/Deck1/PlayState`.
- Some paths only push when their value changes — start playback or move a fader to trigger an update.

**`Read-StateMapValue` blocks indefinitely**
- The default `ReadTimeout` on the StateMap stream is 30 seconds. Set `$sm.Stream.ReadTimeout` (in milliseconds) after calling `Connect-StagelinQStateMap` if you need a shorter timeout.

**`Start-StagelinQApi` throws "access denied" on Windows**
- Binding to `http://localhost:<port>/` requires the port to be registered or the process to run as administrator. Either run elevated or use `netsh http add urlacl` to grant your user access to the prefix.
