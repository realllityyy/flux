# Flux v2

Efficient binary networking for Roblox. Single RemoteEvent batches events per-Heartbeat with frame-level muxing, dual codec system, anti-spam protection, and reference-counted buffer reuse.

## Installation

Place `flux.luau` in ReplicatedStorage:

```lua
local Flux = require(game.ReplicatedStorage.flux)
```

## API

### Creating Events

```lua
local event = Flux.new(name: string, options?: FluxOptions)
```

**Parameters:**
- `name`: Event identifier (string)
- `options.fast`: Set to `true` for local-only events (zero-overhead, no networking)
- `options.schema`: Table defining compiled schema fields (see Schema section)

**Examples:**

```lua
-- Dynamic codec (auto-serializes any Lua type)
local damageEvent = Flux.new("Damage")

-- Local-only event (no RemoteEvent involved)
local uiEvent = Flux.new("UIUpdate", { fast = true })

-- Schema codec (compiled, smaller payload)
local moveEvent = Flux.new("Move", {
    schema = {
        { name = "x", type = "f32" },
        { name = "y", type = "f32" },
        { name = "z", type = "f32" },
    }
})
```

### Methods

**Firing:**
- `Fire(...any)` - Send to all clients (server) or locally (client)
- `FireDeferred(...any)` - Fire on next Heartbeat
- `FireSome(players: {Player}, ...any)` - Send to specific players (server-only)
- `FireServer(...any)` - Send from client to server

**Listening:**
- `Connect(callback)` - Returns Connection; callback fires on every event
- `Once(callback)` - Auto-disconnects after first fire
- `Wait()` - Yields until event fires (does not work on fast events)

**Configuration:**
- `SetAllowClientReplication(bool)` - Enable/disable client→server fires
- `SetClientValidator(fn: (player, ...any) -> bool)` - Validate client messages before firing

**Info:**
- `GetStats()` - Returns `{ bytesSent, messagesSent, messagesDropped, bytesReceived, messagesReceived, clientSpamBlocked }`
- `ListenerCount()` - Active listener count
- `Destroy()` - Cleanup (disconnects all, destroys RemoteEvent)

### Connection Object

```lua
local conn = event:Connect(callback)
conn:Disconnect() -- Unsubscribe
```

## Codecs

### Dynamic (Default)

Auto-serializes Lua values with type tags:
- `nil`, `number` (f64), `boolean`, `string`, `Vector3`, `CFrame`, `Color3`
- Strings ≥256 bytes compress automatically if savings ≥75%

```lua
local evt = Flux.new("Chat")
evt:Fire("hello", 42, Vector3.new(1, 2, 3))
evt:Connect(function(msg, num, pos)
    print(msg, num, pos)
end)
```

### Schema (Compiled)

Fixed-layout binary format; smaller payloads, no runtime type resolution.

**Supported types:** `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`, `f64`, `bool`, `string`, `Vector3`, `CFrame`, `Color3`

```lua
local dmgEvt = Flux.new("Damage", {
    schema = {
        { name = "targetId", type = "u16"    },
        { name = "amount",   type = "f32"    },
        { name = "pos",      type = "Vector3" },
        { name = "isCrit",   type = "bool"   },
    }
})

dmgEvt:Fire(targetId, amount, Vector3.new(1, 2, 3), isCrit)
dmgEvt:Connect(function(targetId, amount, pos, isCrit)
    print(targetId, amount, pos, isCrit)
end)
```

## Architecture

- **Muxing:** Single `__FluxMux__` RemoteEvent carries all Flux events in batched frames
- **Frame Format:** Each Heartbeat flushes pending buffers; mux tokens separate broadcast, targeted, and client-outgoing frames
- **Buffer Pool:** 64 reusable buffers (min 1KB, hard max 256KB per frame)
- **Reference Counting:** Buffers track refcount to prevent double-free
- **EventID Recycling:** Free-list reuses defunct event IDs
- **Rate Limiting:** 50ms per-client cooldown on client→server fires
- **Compression:** Auto-compress strings ≥256B if compression saves ≥75%

## Examples

### Server Broadcasting

```lua
local scoreEvent = Flux.new("ScoreUpdate")

scoreEvent:Fire(player.Name, points)
```

### Server Targeted

```lua
scoreEvent:FireSome({ player1, player2 }, data)
```

### Client to Server (Validated)

```lua
-- Server
local chatEvent = Flux.new("Chat")
chatEvent:SetAllowClientReplication(true)
chatEvent:SetClientValidator(function(player, message)
    return type(message) == "string" and #message < 128
end)
chatEvent:Connect(function(player, message)
    print(player.Name .. ": " .. message)
end)

-- Client
local chatEvent = Flux.new("Chat")
chatEvent:FireServer("Hello, server!")
```

### Local-Only Events

```lua
local uiEvent = Flux.new("MenuOpen", { fast = true })

uiEvent:Fire("inventory")
uiEvent:Connect(function(panel)
    print("Opened:", panel)
end)
```

### With Connection Management

```lua
local conn = event:Connect(function(...) end)
conn:Disconnect() -- Unsubscribe

-- Auto-disconnect after first fire
event:Once(function(...)
    print("Fired once")
end)
```

## Benchmarking

Built-in benchmark suite:

```lua
-- Server-only
Flux.Bench.runAll(10)  -- Run built-in payloads for 10s each

-- Custom benchmark
local result = Flux.Bench.run({
    name          = "MyPayload",
    seconds       = 5,
    firesPerFrame = 1000,
    buildPayload  = function()
        return { hp = math.random(1, 100), pos = Vector3.new(1, 2, 3) }
    end,
    event         = Flux.new("MyBench"),
})
Flux.Bench.print(result) -- Prints FPS, encode cost, bytes/fire, Kbps estimates
```

## Notes

- All network communication automates per Heartbeat; no manual flushing needed
- Stats track bytes sent/received and message drop count for debugging
- Client fires are rate-limited to 50ms per player to prevent spam
- Schema compression typically saves 50-80% vs dynamic codec
- `fast = true` creates zero-overhead local signaling (skips entire mux system)
- Validator functions receive `(player, ...args)` on server
- All events internally recycled on Destroy; safe to recreate with same name
