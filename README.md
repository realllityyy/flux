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
