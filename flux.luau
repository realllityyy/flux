--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")

local isServer = RunService:IsServer()
local LemonSignal = require(ReplicatedFirst.LemonSignal)

-- throughout heaven and earth, I alone am the type error oned
-- TYPE DEFINITIONS

export type Connection = {
    Disconnect: (self: Connection) -> (),
}

export type Stats = {
    bytesSent: number,
    messagesSent: number,
    messagesDropped: number,
    bytesReceived: number,
    messagesReceived: number,
    clientSpamBlocked: number,
}

export type Event = {
    Fire: (self: Event, ...any) -> (),
    FireDeferred: (self: Event, ...any) -> (),
    FireSome: (self: Event, players: { Player }, ...any) -> (),
    SetAllowClientReplication: (self: Event, allowed: boolean) -> (),
    SetClientValidator: (self: Event, validator: (Player, ...any) -> boolean) -> (),
    Connect: (self: Event, fn: (...any) -> ()) -> Connection,
    Once: (self: Event, fn: (...any) -> ()) -> Connection,
    Wait: (self: Event) -> ...any,
    ListenerCount: (self: Event) -> number,
    Destroy: (self: Event) -> (),
    GetStats: (self: Event) -> Stats,
    networkId: string,
}

-- CONSTANTS

-- Security tokens (unforgeable by clients due to newproxy)
local HANDSHAKE_TOKEN = newproxy(false)
local CLIENT_FIRE_TOKEN = newproxy(false)

-- Buffer pool configuration (HOT PATH: optimized for reuse)
local BUFFER_SIZE = 1024
local MAX_POOL_SIZE = 64
local bufferPool: { buffer } = table.create(MAX_POOL_SIZE)
local poolSize = 0

-- Serialization type tags (HOT PATH: minimal branching)
local TYPE_NIL = 0
local TYPE_NUMBER = 1
local TYPE_BOOLEAN = 2
local TYPE_STRING = 3
local TYPE_VECTOR3 = 4
local TYPE_CFRAME = 5
local TYPE_COLOR3 = 6
local TYPE_STRING_COMPRESSED = 7

-- Compression settings
local COMPRESS_THRESHOLD = 256
local COMPRESS_MIN_SAVINGS = 0.75

-- Batching configuration (HOT PATH: optimized flush)
local MAX_BATCH_SIZE = 100
local TARGET_ALL = 1
local TARGET_PLAYER = 2

-- Rate limiting
local CLIENT_FIRE_COOLDOWN = 0.05

-- BUFFER POOL (HOT PATH: zero-alloc acquisition)
-- HOT PATH: Acquire buffer from pool or create new one
local function acquireBuffer(minSize: number?): buffer
    local requiredSize = math.max(minSize or BUFFER_SIZE, BUFFER_SIZE)

    -- Fast path: reuse from pool
    if poolSize > 0 then
        local buf = bufferPool[poolSize]
        if buffer.len(buf) >= requiredSize then
            bufferPool[poolSize] = nil
            poolSize -= 1
            return buf
        end
    end

    -- Slow path: allocate new buffer
    return buffer.create(requiredSize)
end

-- HOT PATH: Return buffer to pool for reuse
local function releaseBuffer(buf: buffer)
    if poolSize < MAX_POOL_SIZE then
        poolSize += 1
        bufferPool[poolSize] = buf
    end
end

-- SERIALIZER (HOT PATH: zero-alloc encoding)

local Serializer = {}

-- HOT PATH: Encode Lua values into binary buffer
-- Returns: (payload: buffer, bufferToRelease: buffer, payloadSize: number)
function Serializer.encode(...): (buffer, buffer, number)
    local argc = select("#", ...)

    -- Pre-calculate buffer size (avoids overflow checks in hot loop)
    local estimatedSize = 1
    for i = 1, argc do
        local value = select(i, ...)
        local valueType = typeof(value)

        if valueType == "number" then
            estimatedSize += 9
        elseif valueType == "boolean" then
            estimatedSize += 2
        elseif valueType == "string" then
            local len = #value
            if len >= COMPRESS_THRESHOLD then
                estimatedSize += 3 + math.ceil(len * 0.6)
            else
                estimatedSize += 3 + len
            end
        elseif valueType == "Vector3" then
            estimatedSize += 13
        elseif valueType == "CFrame" then
            estimatedSize += 49
        elseif valueType == "Color3" then
            estimatedSize += 13
        else
            estimatedSize += 1
        end
    end

    local buf = acquireBuffer(estimatedSize)
    local bufferSize = buffer.len(buf)
    local w = 0

    -- Write argc
    buffer.writeu8(buf, w, argc)
    w += 1

    -- HOT PATH: Encode loop (minimal branching, inlined operations)
    for i = 1, argc do
        local value = select(i, ...)
        local valueType = typeof(value)

        if valueType == "number" then
            buffer.writeu8(buf, w, TYPE_NUMBER)
            w += 1
            buffer.writef64(buf, w, value)
            w += 8

        elseif valueType == "boolean" then
            buffer.writeu8(buf, w, TYPE_BOOLEAN)
            w += 1
            buffer.writeu8(buf, w, if value then 1 else 0)
            w += 1

        elseif valueType == "string" then
            local stringLength = #value

            if stringLength >= COMPRESS_THRESHOLD then
                local stringBuffer = buffer.fromstring(value)
                local compressedBuffer = buffer.compress(stringBuffer)
                local compressedLength = buffer.len(compressedBuffer)

                if compressedLength < stringLength * COMPRESS_MIN_SAVINGS then
                    buffer.writeu8(buf, w, TYPE_STRING_COMPRESSED)
                    w += 1
                    buffer.writeu16(buf, w, compressedLength)
                    w += 2
                    buffer.copy(buf, w, compressedBuffer, 0, compressedLength)
                    w += compressedLength
                else
                    buffer.writeu8(buf, w, TYPE_STRING)
                    w += 1
                    buffer.writeu16(buf, w, stringLength)
                    w += 2
                    buffer.writestring(buf, w, value, stringLength)
                    w += stringLength
                end
            else
                buffer.writeu8(buf, w, TYPE_STRING)
                w += 1
                buffer.writeu16(buf, w, stringLength)
                w += 2
                buffer.writestring(buf, w, value, stringLength)
                w += stringLength
            end

        elseif valueType == "Vector3" then
            buffer.writeu8(buf, w, TYPE_VECTOR3)
            w += 1
            buffer.writef32(buf, w, value.X)
            w += 4
            buffer.writef32(buf, w, value.Y)
            w += 4
            buffer.writef32(buf, w, value.Z)
            w += 4

        elseif valueType == "CFrame" then
            buffer.writeu8(buf, w, TYPE_CFRAME)
            w += 1
            local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
            buffer.writef32(buf, w, x)
            w += 4
            buffer.writef32(buf, w, y)
            w += 4
            buffer.writef32(buf, w, z)
            w += 4
            buffer.writef32(buf, w, r00)
            w += 4
            buffer.writef32(buf, w, r01)
            w += 4
            buffer.writef32(buf, w, r02)
            w += 4
            buffer.writef32(buf, w, r10)
            w += 4
            buffer.writef32(buf, w, r11)
            w += 4
            buffer.writef32(buf, w, r12)
            w += 4
            buffer.writef32(buf, w, r20)
            w += 4
            buffer.writef32(buf, w, r21)
            w += 4
            buffer.writef32(buf, w, r22)
            w += 4

        elseif valueType == "Color3" then
            buffer.writeu8(buf, w, TYPE_COLOR3)
            w += 1
            buffer.writef32(buf, w, value.R)
            w += 4
            buffer.writef32(buf, w, value.G)
            w += 4
            buffer.writef32(buf, w, value.B)
            w += 4

        else
            buffer.writeu8(buf, w, TYPE_NIL)
            w += 1
        end
    end

    return buf, buf, w
end

-- Decode binary buffer into Lua values
function Serializer.decode(buf: buffer): (boolean, ...any)
    local bufferSize = buffer.len(buf)
    local r = 0

    local function canRead(needed: number): boolean
        return r + needed <= bufferSize
    end

    if not canRead(1) then
        return false, "Malformed: missing argc"
    end

    local argc = buffer.readu8(buf, r)
    r += 1

    if argc > 255 then
        return false, "Malformed: argc exceeds limit"
    end

    local values = table.create(argc)

    for i = 1, argc do
        if not canRead(1) then
            return false, `Malformed: missing type tag at arg {i}`
        end

        local typeTag = buffer.readu8(buf, r)
        r += 1

        if typeTag == TYPE_NUMBER then
            if not canRead(8) then
                return false, `Malformed: incomplete number at arg {i}`
            end
            values[i] = buffer.readf64(buf, r)
            r += 8

        elseif typeTag == TYPE_BOOLEAN then
            if not canRead(1) then
                return false, `Malformed: incomplete boolean at arg {i}`
            end
            values[i] = buffer.readu8(buf, r) == 1
            r += 1

        elseif typeTag == TYPE_STRING then
            if not canRead(2) then
                return false, `Malformed: incomplete string length at arg {i}`
            end
            local stringLength = buffer.readu16(buf, r)
            r += 2

            if not canRead(stringLength) then
                return false, `Malformed: string length {stringLength} exceeds buffer at arg {i}`
            end

            values[i] = buffer.readstring(buf, r, stringLength)
            r += stringLength

        elseif typeTag == TYPE_VECTOR3 then
            if not canRead(12) then
                return false, `Malformed: incomplete Vector3 at arg {i}`
            end
            local x = buffer.readf32(buf, r)
            r += 4
            local y = buffer.readf32(buf, r)
            r += 4
            local z = buffer.readf32(buf, r)
            r += 4
            values[i] = Vector3.new(x, y, z)

        elseif typeTag == TYPE_CFRAME then
            if not canRead(48) then
                return false, `Malformed: incomplete CFrame at arg {i}`
            end
            local x = buffer.readf32(buf, r)
            r += 4
            local y = buffer.readf32(buf, r)
            r += 4
            local z = buffer.readf32(buf, r)
            r += 4
            local r00 = buffer.readf32(buf, r)
            r += 4
            local r01 = buffer.readf32(buf, r)
            r += 4
            local r02 = buffer.readf32(buf, r)
            r += 4
            local r10 = buffer.readf32(buf, r)
            r += 4
            local r11 = buffer.readf32(buf, r)
            r += 4
            local r12 = buffer.readf32(buf, r)
            r += 4
            local r20 = buffer.readf32(buf, r)
            r += 4
            local r21 = buffer.readf32(buf, r)
            r += 4
            local r22 = buffer.readf32(buf, r)
            r += 4
            values[i] = CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)

        elseif typeTag == TYPE_COLOR3 then
            if not canRead(12) then
                return false, `Malformed: incomplete Color3 at arg {i}`
            end
            local red = buffer.readf32(buf, r)
            r += 4
            local green = buffer.readf32(buf, r)
            r += 4
            local blue = buffer.readf32(buf, r)
            r += 4
            values[i] = Color3.new(red, green, blue)

        elseif typeTag == TYPE_STRING_COMPRESSED then
            if not canRead(2) then
                return false, `Malformed: incomplete compressed length at arg {i}`
            end
            local compressedLength = buffer.readu16(buf, r)
            r += 2

            if not canRead(compressedLength) then
                return false, `Malformed: compressed data {compressedLength} exceeds buffer at arg {i}`
            end

            local compressedSlice = buffer.slice(buf, r, r + compressedLength)
            r += compressedLength

            local success, decompressedBuffer = pcall(buffer.decompress, compressedSlice)
            if not success then
                return false, `Malformed: decompression failed at arg {i}`
            end

            values[i] = buffer.tostring(decompressedBuffer)

        elseif typeTag == TYPE_NIL then
            values[i] = nil

        else
            values[i] = nil
        end
    end

    return true, table.unpack(values, 1, argc)
end

-- BATCHER (HOT PATH: efficient message accumulation)

type BatchData = {
    payloads: { buffer },
    buffers: { buffer },
    sizes: { number },
    count: number,
}

-- Create batcher for accumulating and flushing messages
local function createBatcher(remote: RemoteEvent, stats: Stats)
    local broadcastPayloads: { buffer } = table.create(16)
    local broadcastBuffers: { buffer } = table.create(16)
    local broadcastSizes: { number } = table.create(16)
    local broadcastCount = 0

    local playerBatches: { [Player]: BatchData } = {}
    local flushScheduled = false

    -- HOT PATH: Flush batched messages
    local function flush()
        flushScheduled = false

        if broadcastCount > 0 then
            local chunk = math.min(broadcastCount, MAX_BATCH_SIZE)

            for i = 1, chunk do
                local ok = pcall(remote.FireAllClients, remote, broadcastPayloads[i])
                if ok then
                    stats.bytesSent += broadcastSizes[i]
                    stats.messagesSent += 1
                else
                    stats.messagesDropped += 1
                end
                releaseBuffer(broadcastBuffers[i])
            end

            if broadcastCount > chunk then
                for i = 1, broadcastCount - chunk do
                    broadcastPayloads[i] = broadcastPayloads[chunk + i]
                    broadcastBuffers[i] = broadcastBuffers[chunk + i]
                    broadcastSizes[i] = broadcastSizes[chunk + i]
                end
                for i = broadcastCount - chunk + 1, broadcastCount do
                    broadcastPayloads[i] = nil
                    broadcastBuffers[i] = nil
                    broadcastSizes[i] = nil
                end
                broadcastCount -= chunk
                task.defer(flush)
            else
                for i = 1, broadcastCount do
                    broadcastPayloads[i] = nil
                    broadcastBuffers[i] = nil
                    broadcastSizes[i] = nil
                end
                broadcastCount = 0
            end
        end

        for player, batch in playerBatches do
            local chunk = math.min(batch.count, MAX_BATCH_SIZE)

            for i = 1, chunk do
                local ok = pcall(remote.FireClient, remote, player, batch.payloads[i])
                if ok then
                    stats.bytesSent += batch.sizes[i]
                    stats.messagesSent += 1
                else
                    stats.messagesDropped += 1
                end
                releaseBuffer(batch.buffers[i])
            end

            if batch.count > chunk then
                for i = 1, batch.count - chunk do
                    batch.payloads[i] = batch.payloads[chunk + i]
                    batch.buffers[i] = batch.buffers[chunk + i]
                    batch.sizes[i] = batch.sizes[chunk + i]
                end
                for i = batch.count - chunk + 1, batch.count do
                    batch.payloads[i] = nil
                    batch.buffers[i] = nil
                    batch.sizes[i] = nil
                end
                batch.count -= chunk
            else
                playerBatches[player] = nil
            end
        end
    end

    -- HOT PATH: Queue message for batched sending
    return function(targetType: number, targetPlayer: Player?, payload: buffer, buf: buffer, size: number)
        if targetType == TARGET_ALL then
            broadcastCount += 1
            broadcastPayloads[broadcastCount] = payload
            broadcastBuffers[broadcastCount] = buf
            broadcastSizes[broadcastCount] = size
        elseif targetType == TARGET_PLAYER and targetPlayer then
            local batch = playerBatches[targetPlayer]
            if not batch then
                batch = {
                    payloads = table.create(8),
                    buffers = table.create(8),
                    sizes = table.create(8),
                    count = 0,
                }
                playerBatches[targetPlayer] = batch
            end

            batch.count += 1
            batch.payloads[batch.count] = payload
            batch.buffers[batch.count] = buf
            batch.sizes[batch.count] = size
        end

        if not flushScheduled then
            flushScheduled = true
            task.defer(flush)
        end
    end
end

-- FAST LOCAL EVENT (HOT PATH: zero overhead signaling)

type ListNode = {
    fn: ((...any) -> ())?,
    next: ListNode?,
}

-- Create fast local event (no networking, no serialization)
local function createFastEvent(name: string): Event
    local head: ListNode? = nil
    local listenerCount = 0
    local deadCount = 0
    local gcThreshold = 20

    local function cleanDeadNodes()
        local prev: ListNode? = nil
        local node = head

        while node do
            if not node.fn then
                if prev then
                    prev.next = node.next
                else
                    head = node.next
                end
                deadCount -= 1
            else
                prev = node
            end
            node = node.next
        end
    end

    -- HOT PATH: O(1) connection insertion
    local function Connect(_: Event, callback: (...any) -> ()): Connection
        local node: ListNode = { fn = callback, next = head }
        head = node
        listenerCount += 1

        return {
            Disconnect = function()
                if not node.fn then
                    return
                end
                node.fn = nil
                listenerCount -= 1
                deadCount += 1

                if deadCount >= gcThreshold then
                    cleanDeadNodes()
                end
            end,
        }
    end

    -- HOT PATH: Fire event (linked list traversal)
    local function Fire(_: Event, ...)
        local node = head
        while node do
            if node.fn then
                node.fn(...)
            end
            node = node.next
        end
    end

    return {
        Fire = Fire,

        FireDeferred = function(_, ...)
            task.defer(Fire, nil, ...)
        end,

        FireSome = function() end,
        SetAllowClientReplication = function() end,
        SetClientValidator = function() end,
        Connect = Connect,

        Once = function(_, callback: (...any) -> ()): Connection
            local conn
            conn = Connect(nil, function(...)
                conn:Disconnect()
                callback(...)
            end)
            return conn
        end,

        Wait = function()
            error("Wait not supported on fast events", 2)
        end,

        ListenerCount = function(): number
            return listenerCount
        end,

        Destroy = function()
            head = nil
            listenerCount = 0
            deadCount = 0
        end,

        GetStats = function(): Stats
            return {
                bytesSent = 0,
                messagesSent = 0,
                messagesDropped = 0,
                bytesReceived = 0,
                messagesReceived = 0,
                clientSpamBlocked = 0,
            }
        end,

        networkId = name,
    }
end


-- MAIN CONSTRUCTOR (COLD PATH)
-- This is da real deal

local Flux = {}

function Flux.new(name: string, options: { fast: number? }?): Event
    assert(name ~= "", "Event name required")

    if options and options.fast == 1 then
        return createFastEvent(name)
    end

    local remote: RemoteEvent?
    local allowClientReplication = false
    local clientValidator: ((Player, ...any) -> boolean)?

    local activePlayers: { [Player]: boolean } = {}
    local activePlayerCount = 0

    local listenerCount = 0
    local stats: Stats = {
        bytesSent = 0,
        messagesSent = 0,
        messagesDropped = 0,
        bytesReceived = 0,
        messagesReceived = 0,
        clientSpamBlocked = 0,
    }

    local signal = LemonSignal.new()
    local serverConn: RBXScriptConnection?
    local clientConn: RBXScriptConnection?
    local childConn: RBXScriptConnection?
    local playerAddedConn: RBXScriptConnection?
    local playerRemovingConn: RBXScriptConnection?
    local batcher

    local lastClientFire: { [Player]: number } = {}
    local networkId = name

    if isServer then
        remote = Instance.new("RemoteEvent")
        remote.Name = name
        remote.Parent = script
        batcher = createBatcher(remote, stats)

        playerAddedConn = Players.PlayerAdded:Connect(function(player)
            activePlayers[player] = true
            activePlayerCount += 1
        end)

        playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
            activePlayers[player] = nil
            activePlayerCount -= 1
            lastClientFire[player] = nil
        end)

        for _, player in Players:GetPlayers() do
            activePlayers[player] = true
            activePlayerCount += 1
        end

        serverConn = remote.OnServerEvent:Connect(function(player: Player, token: any, payload: any)
            if token == HANDSHAKE_TOKEN then
                return
            end

            if token == CLIENT_FIRE_TOKEN then
                if not allowClientReplication then
                    stats.messagesDropped += 1
                    return
                end

                local now = os.clock()
                local lastFire = lastClientFire[player] or 0
                if now - lastFire < CLIENT_FIRE_COOLDOWN then
                    stats.clientSpamBlocked += 1
                    stats.messagesDropped += 1
                    return
                end
                lastClientFire[player] = now

                if typeof(payload) ~= "buffer" then
                    stats.messagesDropped += 1
                    return
                end

                stats.bytesReceived += buffer.len(payload)

                local success, result = Serializer.decode(payload)
                if not success then
                    stats.messagesDropped += 1
                    return
                end

                local args = { select(2, success, result) }

                if clientValidator then
                    local valid = clientValidator(player, table.unpack(args))
                    if not valid then
                        stats.messagesDropped += 1
                        return
                    end
                end

                stats.messagesReceived += 1
                signal:Fire(table.unpack(args))
            end
        end)
    else
        local function bindRemote(re: RemoteEvent)
            remote = re

            clientConn = re.OnClientEvent:Connect(function(payload: any)
                if typeof(payload) ~= "buffer" then
                    return
                end

                stats.bytesReceived += buffer.len(payload)

                local success, result = Serializer.decode(payload)
                if not success then
                    return
                end

                stats.messagesReceived += 1
                signal:Fire(select(2, success, result))
            end)

            re:FireServer(HANDSHAKE_TOKEN)
        end

        local existing = script:FindFirstChild(name)
        if existing and existing:IsA("RemoteEvent") then
            bindRemote(existing)
        else
            childConn = script.ChildAdded:Connect(function(child)
                if child:IsA("RemoteEvent") and child.Name == name then
                    if childConn then
                        childConn:Disconnect()
                        childConn = nil
                    end
                    bindRemote(child)
                end
            end)
        end
    end

    -- HOT PATH: Fire implementation
    local function Fire(_: Event, ...)
        signal:Fire(...)
        if isServer and activePlayerCount > 0 and remote then
            local payload, buf, size = Serializer.encode(...)
            batcher(TARGET_ALL, nil, payload, buf, size)
        end
    end

    return {
        Fire = Fire,

        FireDeferred = function(_, ...)
            task.defer(Fire, nil, ...)
        end,

        FireSome = function(_, players: { Player }, ...)
            signal:Fire(...)
            if remote and #players > 0 then
                local payload, buf, size = Serializer.encode(...)
                for _, player in players do
                    if activePlayers[player] then
                        batcher(TARGET_PLAYER, player, payload, buf, size)
                    end
                end
            end
        end,

        SetAllowClientReplication = function(_, allowed: boolean)
            if isServer then
                allowClientReplication = allowed
            end
        end,

        SetClientValidator = function(_, validator: (Player, ...any) -> boolean)
            if isServer then
                clientValidator = validator
            end
        end,

        Connect = function(_, callback: (...any) -> ()): Connection
            listenerCount += 1
            local conn = signal:Connect(callback)
            local disconnect = conn.Disconnect
            conn.Disconnect = function(c)
                disconnect(c)
                listenerCount -= 1
            end
            return conn
        end,

        Once = function(_, callback: (...any) -> ()): Connection
            listenerCount += 1
            local conn = signal:Once(function(...)
                listenerCount -= 1
                callback(...)
            end)
            return conn
        end,

        Wait = function(): ...any
            return signal:Wait()
        end,

        ListenerCount = function(): number
            return listenerCount
        end,

        GetStats = function(): Stats
            return table.clone(stats)
        end,

        Destroy = function()
            if childConn then
                childConn:Disconnect()
            end
            if clientConn then
                clientConn:Disconnect()
            end
            if serverConn then
                serverConn:Disconnect()
            end
            if playerAddedConn then
                playerAddedConn:Disconnect()
            end
            if playerRemovingConn then
                playerRemovingConn:Disconnect()
            end
            signal:Destroy()
            if isServer and remote then
                remote:Destroy()
            end
            table.clear(lastClientFire)
            table.clear(activePlayers)
        end,

        networkId = networkId,
    }
end

return Flux
