# Flux - Minimalist Network Event System for Roblox

[![Version](https://img.shields.io/badge/version-1.0-blue.svg)](https://github.com/realllityyy/Flux)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Roblox](https://img.shields.io/badge/platform-Roblox-red.svg)](https://create.roblox.com/store/asset/71059602594151)

Flux is a **lightweight, high-performance networking module** for Roblox. It provides **safe and efficient communication** between server and clients, with **built-in anti-spam protections** and **optional local-only events**.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Constructor](#constructor)
- [Methods](#methods)
- [Usage Examples](#usage-examples)
  - [Server Example](#server-example)
  - [Client Example](#client-example)
  - [Fast Local Event Example](#fast-local-event-example)
- [Notes](#notes)
- [Updates](#updates)
- [License](#license)

---

## Features

| Feature                | Description                                                                 |
|------------------------|-----------------------------------------------------------------------------|
| **Batching**           | Groups events to reduce network calls                                       |
| **Serialization**      | Compact binary encoding of Lua types                                        |
| **Supported Types**    | `number`, `boolean`, `string`, `Vector3`, `CFrame`, `Color3`, `nil`        |
| **Anti-Spam / DDoS**   | Rate limits and client validation                                           |
| **Fast Local Events**  | Zero-overhead events for local signaling                                    |
| **FireSome**           | Targeted events to specific players                                         |
| **Simple API**         | Easy-to-use `Fire`, `FireDeferred`, `FireSome`, `Connect`, `Once`, `Wait`  |

---

## Installation

1. Place `Flux.lua` in `ReplicatedStorage`.
2. Require it in your scripts:

```lua
local Flux = require(game.ReplicatedStorage.Flux)
```

## Constructor


```lua
local event = Flux.new(name: string, options?: { fast: number? })
```
| Parameter      | Description                                            |
| -------------- | ------------------------------------------------------ |
| `name`         | Event identifier (string)                              |
| `options.fast` | Optional; set to `1` to create a fast local-only event |


Returns: A new or previously created event instance.

Example: 
```lua
local myEvent = Flux.new("PlayerScore")
```

## Methods

| Method                             | Description                                                                                                              |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `Fire(...any)`                     | Send event to all clients or locally.                                                                                    |
| `FireDeferred(...any)`             | Fire event on the next frame. Useful for throttling or batching.                                                         |
| `FireSome(players: {Player}, ...)` | Send to specific players (server-only).                                                                                  |
| `Connect(callback)`                | Listen for the event. Returns a connection object.                                                                       |
| `Once(callback)`                   | Listen once; auto-disconnects after first call.                                                                          |
| `Wait()`                           | Yield until the event fires.                                                                                             |
| `SetAllowClientReplication(bool)`  | Server-only. Allow or disallow clients from firing this event.                                                           |
| `SetClientValidator(func)`         | Server-only. Function that validates client messages.                                                                    |
| `Destroy()`                        | Cleans up all connections and removes the remote.                                                                        |
| `GetStats()`                       | Returns a table with `{ bytesSent, messagesSent, messagesDropped, bytesReceived, messagesReceived, clientSpamBlocked }`. |
| `ListenerCount()`                  | Returns the number of active listeners on the event.                                                                     |

Example:
```lua
myEvent:Connect(function(player, score)
    print(player.Name, "scored", score)
end)
```
## Usage Examples
# Server Example
```lua
local Flux = require(game.ReplicatedStorage.Flux)
local event = Flux.new("TestEvent")

-- Wait for a player to join
local player = game.Players.PlayerAdded:Wait()

-- Fire a message to a specific player
event:FireSome({player}, 42, "Hello")

-- Fire to all clients
event:Fire("Global message to all players")

```
# Client Example
```lua
local localEvent = Flux.new("LocalOnly", { fast = 1 })

-- Connect to the event locally
localEvent:Connect(function(msg)
    print("Local received:", msg)
end)

-- Fire locally
localEvent:Fire("Hi locally!")
```

## Notes
Safe for production: Server-client communication, anti-spam, optional validation.

FireSome reduces bandwidth for large games.

Fast events provide zero-allocation, minimal CPU overhead.

Can be used for leaderboards, chat systems, gameplay events, and more.

Supports common Roblox types: number, boolean, string, Vector3, CFrame, Color3, and nil.

## Updates
v1.0: Initial release




