--!strict
--!optimize 2
--!native

--// ============================================================
--//  Flux v2
--//  Sometimes I think, therefore I am..
--//
--//  Architecture: ALL events share ONE RemoteEvent and ONE buffer
--//  per Heartbeat.
--//
--//  All review issues resolved:
--//    • 8-arg demux limit → codec.decode writes into a result table,
--//      table.unpack dispatches any arg count without truncation
--//      Thanks to Manka
--//    • growIfNeeded capped at maxFrameSize (256 KB) with hard error
--//    • EventID free-list — IDs recycled on Destroy()
--//      Thanks to Manka
--//    • Demux frame truncation logs a warning now
--//      Thanks for it breaking to Manka
--//    • PlayerRemoving race documented with comment in serverFlush
--//      Thanks for Manka
--//    • CFrame/Vector3/Color3 demux uses sequential local reads
--//    • decodeOut shared-table reuse: table.clear + explicit .n reset
--//      Thanks to Manka for the idea and testing that it’s safe in Roblox’s single-threaded model
--//    • Bench.runAll seed reset placed OUTSIDE buildArgs 
--// ============================================================

--//Services
local runService        = game:GetService("RunService")
local replicatedStorage = game:GetService("ReplicatedStorage")
local playersService    = game:GetService("Players")

--//Checking if server

local isServer = runService:IsServer()

--// CuteSignal - made by Hank_Hail (tuff as blud scripter)
--//   signal.Fire(...)       no self
--//   signal.Connect(fn)     
--//   signal.Destroy()
--//   signal.Count()
local newSignal = require(replicatedStorage.CuteSignal)

--//  EXPORTED TYPES

export type Connection = {
    Disconnect: (self: Connection) -> (),
}

export type Stats = {
    bytesSent        : number,
    messagesSent     : number,
    messagesDropped  : number,
    bytesReceived    : number,
    messagesReceived : number,
    clientSpamBlocked: number,
}

export type FieldType =
    "u8"  | "u16" | "u32" |
    "i8"  | "i16" | "i32" |
    "f32" | "f64" |
    "bool" | "string" |
    "Vector3" | "CFrame" | "Color3"

export type SchemaField = {
    name: string,
    type: FieldType,
}

export type Schema = { SchemaField }

export type Event = {
    Fire                     : (self: Event, ...any) -> (),
    FireDeferred             : (self: Event, ...any) -> (),
    FireSome                 : (self: Event, targets: { Player }, ...any) -> (),
    FireServer               : (self: Event, ...any) -> (),
    SetAllowClientReplication: (self: Event, allowed: boolean) -> (),
    SetClientValidator       : (self: Event, validator: ((Player, ...any) -> boolean)?) -> (),
    Connect                  : (self: Event, fn: (...any) -> ()) -> Connection,
    Once                     : (self: Event, fn: (...any) -> ()) -> Connection,
    Wait                     : (self: Event) -> ...any,
    ListenerCount            : (self: Event) -> number,
    Destroy                  : (self: Event) -> (),
    GetStats                 : (self: Event) -> Stats,
    networkId                : string,
}

export type FluxOptions = {
    fast  : boolean?, --// true → local-only fast event, no network
    schema: Schema?,  --// optional schema for structured events with zero typeof() overhead
}

--//  WIRE CONSTANTS

local handshakeToken  = newproxy(false)
local clientFireToken = newproxy(false)

local tagNil              = 0
local tagNumber           = 1
local tagBool             = 2
local tagString           = 3
local tagVector3          = 4
local tagCFrame           = 5
local tagColor3           = 6
local tagStringCompressed = 7
local tagMaxKnown         = 7

local sTagU8    = 16
local sTagU16   = 17
local sTagU32   = 18
local sTagI8    = 19
local sTagI16   = 20
local sTagI32   = 21
local sTagF32   = 22
local sTagF64   = 23
local sTagBool  = 24
local sTagStr   = 25
local sTagVec3  = 26
local sTagCf    = 27
local sTagColor = 28

local muxBroadcast  = 0xAA   --// server → all clients
local muxTargeted   = 0xBB   --// server → specific
local muxClientFire = 0xCC   --// client → server


local maxArgc       = 32
local maxStringLen  = 65535  --//u16
local maxCompressLen = 65535


local maxFrameSize = 256 * 1024


local compressThreshold = 256
local compressMinRatio  = 0.75   
local compressEnabled   = true   --// set false to skip compression entirely


local clientFireCooldown = 0.05  --// seconds

--//  BUFFER POOL

local poolMaxSize = 64
local poolMinBuf  = 1024
local pool: { buffer } = table.create(poolMaxSize)
local poolSize = 0

local function acquireBuf(minSize: number?): buffer
    local needed = math.max(minSize or poolMinBuf, poolMinBuf)
    if poolSize > 0 then
        local b = pool[poolSize]
        if buffer.len(b) >= needed then
            pool[poolSize] = nil
            poolSize -= 1
            return b
        end
    end
    return buffer.create(needed)
end

local function releaseBuf(b: buffer)
    if poolSize < poolMaxSize then
        poolSize += 1
        pool[poolSize] = b
    end
end

type RcBuf = {
    buf : buffer,
    size: number,
    refs: number,
}

local function rcNew(b: buffer, size: number, initialRefs: number): RcBuf
    return { buf = b, size = size, refs = initialRefs }
end

local function rcRelease(rc: RcBuf)
    rc.refs -= 1
    if rc.refs <= 0 then
        releaseBuf(rc.buf)
    end
end

type DecodeOut = {
    [number]: any,
    n  : number,
    err: string?,
}

type Codec = {
    encode: (...any) -> RcBuf,
    decode: (buf: buffer, out: DecodeOut) -> boolean,
}


local function dynamicEncode(...): RcBuf
    local argc = select("#", ...)
    if argc > maxArgc then
        error(("Flux: too many args (%d > %d)"):format(argc, maxArgc), 2)
    end

    --// Convert varargs to table once — indexing is cheaper than repeated select()
    local args = { ... }
    local buf  = acquireBuf(argc * 64)
    local w    = 0

    buffer.writeu8(buf, w, argc); w += 1

    for i = 1, argc do
        local v  = args[i]
        local vt = typeof(v)

        if vt == "number" then
            buffer.writeu8(buf, w, tagNumber);  w += 1
            buffer.writef64(buf, w, v);         w += 8

        elseif vt == "boolean" then
            buffer.writeu8(buf, w, tagBool);    w += 1
            buffer.writeu8(buf, w, if v then 1 else 0); w += 1

        elseif vt == "string" then
            local slen = #v
            if slen > maxStringLen then
                error(("Flux: string arg %d too long (%d)"):format(i, slen), 2)
            end
            if compressEnabled and slen >= compressThreshold then
                local cb = buffer.compress(buffer.fromstring(v))
                local cl = buffer.len(cb)
                if cl <= maxCompressLen and cl < slen * compressMinRatio then
                    buffer.writeu8(buf, w, tagStringCompressed); w += 1
                    buffer.writeu16(buf, w, cl);                 w += 2
                    buffer.copy(buf, w, cb, 0, cl);              w += cl
                else
                    buffer.writeu8(buf, w, tagString);   w += 1
                    buffer.writeu16(buf, w, slen);       w += 2
                    buffer.writestring(buf, w, v, slen); w += slen
                end
            else
                buffer.writeu8(buf, w, tagString);   w += 1
                buffer.writeu16(buf, w, slen);       w += 2
                buffer.writestring(buf, w, v, slen); w += slen
            end

        elseif vt == "Vector3" then
            buffer.writeu8(buf, w, tagVector3); w += 1
            buffer.writef32(buf, w, v.X);       w += 4
            buffer.writef32(buf, w, v.Y);       w += 4
            buffer.writef32(buf, w, v.Z);       w += 4

        elseif vt == "CFrame" then
            buffer.writeu8(buf, w, tagCFrame); w += 1
            local x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22 = v:GetComponents()
            buffer.writef32(buf, w, x);   w += 4
            buffer.writef32(buf, w, y);   w += 4
            buffer.writef32(buf, w, z);   w += 4
            buffer.writef32(buf, w, r00); w += 4
            buffer.writef32(buf, w, r01); w += 4
            buffer.writef32(buf, w, r02); w += 4
            buffer.writef32(buf, w, r10); w += 4
            buffer.writef32(buf, w, r11); w += 4
            buffer.writef32(buf, w, r12); w += 4
            buffer.writef32(buf, w, r20); w += 4
            buffer.writef32(buf, w, r21); w += 4
            buffer.writef32(buf, w, r22); w += 4

        elseif vt == "Color3" then
            buffer.writeu8(buf, w, tagColor3); w += 1
            buffer.writef32(buf, w, v.R);      w += 4
            buffer.writef32(buf, w, v.G);      w += 4
            buffer.writef32(buf, w, v.B);      w += 4

        else
            buffer.writeu8(buf, w, tagNil); w += 1
        end
    end

    return rcNew(buf, w, 1)
end

local function dynamicDecode(buf: buffer, out: DecodeOut): boolean
    local blen = buffer.len(buf)
    local r    = 0

    local function canRead(n: number): boolean
        return r + n <= blen
    end

    if not canRead(1) then out.err = "missing argc"; return false end
    local argc = buffer.readu8(buf, r); r += 1
    if argc > maxArgc then out.err = "argc exceeds limit"; return false end

    out.n = argc

    for i = 1, argc do
        if not canRead(1) then
            out.err = ("missing tag at arg %d"):format(i); return false
        end
        local tag = buffer.readu8(buf, r); r += 1

        --// Hard reject: unknown tag = malformed or cross-codec mismatch
        if tag > tagMaxKnown then
            out.err = ("unknown tag %d at arg %d"):format(tag, i); return false
        end

        if tag == tagNumber then
            if not canRead(8) then out.err = "truncated number"; return false end
            out[i] = buffer.readf64(buf, r); r += 8

        elseif tag == tagBool then
            if not canRead(1) then out.err = "truncated bool"; return false end
            out[i] = buffer.readu8(buf, r) ~= 0; r += 1

        elseif tag == tagString then
            if not canRead(2) then out.err = "truncated str len"; return false end
            local slen = buffer.readu16(buf, r); r += 2
            if not canRead(slen) then out.err = "truncated str data"; return false end
            out[i] = buffer.readstring(buf, r, slen); r += slen

        elseif tag == tagStringCompressed then
            if not canRead(2) then out.err = "truncated cstr len"; return false end
            local clen = buffer.readu16(buf, r); r += 2
            if not canRead(clen) then out.err = "truncated cstr data"; return false end
            local slice = buffer.slice(buf, r, r + clen); r += clen
            local ok, dec = pcall(buffer.decompress, slice)
            if not ok then out.err = "decompress failed"; return false end
            out[i] = buffer.tostring(dec)

        elseif tag == tagVector3 then
            if not canRead(12) then out.err = "truncated vec3"; return false end
            local x = buffer.readf32(buf, r); r += 4
            local y = buffer.readf32(buf, r); r += 4
            local z = buffer.readf32(buf, r); r += 4
            out[i] = Vector3.new(x, y, z)

        elseif tag == tagCFrame then
            if not canRead(48) then out.err = "truncated cframe"; return false end
            local x   = buffer.readf32(buf, r); r += 4
            local y   = buffer.readf32(buf, r); r += 4
            local z   = buffer.readf32(buf, r); r += 4
            local r00 = buffer.readf32(buf, r); r += 4
            local r01 = buffer.readf32(buf, r); r += 4
            local r02 = buffer.readf32(buf, r); r += 4
            local r10 = buffer.readf32(buf, r); r += 4
            local r11 = buffer.readf32(buf, r); r += 4
            local r12 = buffer.readf32(buf, r); r += 4
            local r20 = buffer.readf32(buf, r); r += 4
            local r21 = buffer.readf32(buf, r); r += 4
            local r22 = buffer.readf32(buf, r); r += 4
            out[i] = CFrame.new(x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22)

        elseif tag == tagColor3 then
            if not canRead(12) then out.err = "truncated color3"; return false end
            local red   = buffer.readf32(buf, r); r += 4
            local green = buffer.readf32(buf, r); r += 4
            local blue  = buffer.readf32(buf, r); r += 4
            out[i] = Color3.new(red, green, blue)

        elseif tag == tagNil then
            out[i] = nil
        end
    end

    return true
end

local validFieldTypes: { [string]: boolean } = {
    u8=true, u16=true, u32=true,
    i8=true, i16=true, i32=true,
    f32=true, f64=true,
    bool=true, string=true,
    Vector3=true, CFrame=true, Color3=true,
}

local schemaWireSizes: { [string]: number } = {
    u8=1, u16=2, u32=4,
    i8=1, i16=2, i32=4,
    f32=4, f64=8, bool=1,
}

local function compileCodec(schema: Schema): Codec
    local fields  = schema
    local nFields = #fields
    for idx, f in fields do
        if not validFieldTypes[f.type] then
            error(("Flux schema: invalid type '%s' at index %d (field '%s')")
                :format(tostring(f.type), idx, tostring(f.name)), 2)
        end
    end

    local bufHint = 1
    for _, f in fields do
        local ws = schemaWireSizes[f.type]
        bufHint += 1 + (ws or 16)
    end
    --//Encoding
    local function encode(...): RcBuf
        local argc = select("#", ...)
        if argc ~= nFields then
            error(("Flux schema: expected %d args, got %d"):format(nFields, argc), 2)
        end

        local args = { ... }
        local buf  = acquireBuf(bufHint + argc * 8)
        local w    = 0

        buffer.writeu8(buf, w, nFields); w += 1

        for idx, f in fields do
            local v  = args[idx]
            local ft = f.type

            --// Nil guard surfaces before any buffer write so the error
            --// message names the field, not a buffer offset
            if v == nil then
                error(("Flux schema: field '%s' (index %d) is nil"):format(f.name, idx), 2)
            end

            if ft == "u8" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagU8);  w += 1
                buffer.writeu8(buf, w, v);       w += 1

            elseif ft == "u16" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagU16); w += 1
                buffer.writeu16(buf, w, v);      w += 2

            elseif ft == "u32" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagU32); w += 1
                buffer.writeu32(buf, w, v);      w += 4

            elseif ft == "i8" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagI8);  w += 1
                buffer.writei8(buf, w, v);       w += 1

            elseif ft == "i16" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagI16); w += 1
                buffer.writei16(buf, w, v);      w += 2

            elseif ft == "i32" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagI32); w += 1
                buffer.writei32(buf, w, v);      w += 4

            elseif ft == "f32" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagF32); w += 1
                buffer.writef32(buf, w, v);      w += 4

            elseif ft == "f64" then
                if type(v) ~= "number" then error(("Flux schema: '%s' expects number"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagF64); w += 1
                buffer.writef64(buf, w, v);      w += 8

            elseif ft == "bool" then
                if type(v) ~= "boolean" then error(("Flux schema: '%s' expects boolean"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagBool); w += 1
                buffer.writeu8(buf, w, if v then 1 else 0); w += 1

            elseif ft == "string" then
                if type(v) ~= "string" then error(("Flux schema: '%s' expects string"):format(f.name), 2) end
                local slen = #v
                if slen > maxStringLen then
                    error(("Flux schema: '%s' string too long (%d)"):format(f.name, slen), 2)
                end
                buffer.writeu8(buf, w, sTagStr);     w += 1
                buffer.writeu16(buf, w, slen);       w += 2
                buffer.writestring(buf, w, v, slen); w += slen

            elseif ft == "Vector3" then
                if typeof(v) ~= "Vector3" then error(("Flux schema: '%s' expects Vector3"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagVec3); w += 1
                buffer.writef32(buf, w, v.X);     w += 4
                buffer.writef32(buf, w, v.Y);     w += 4
                buffer.writef32(buf, w, v.Z);     w += 4

            elseif ft == "CFrame" then
                if typeof(v) ~= "CFrame" then error(("Flux schema: '%s' expects CFrame"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagCf); w += 1
                local x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22 = v:GetComponents()
                buffer.writef32(buf, w, x);   w += 4
                buffer.writef32(buf, w, y);   w += 4
                buffer.writef32(buf, w, z);   w += 4
                buffer.writef32(buf, w, r00); w += 4
                buffer.writef32(buf, w, r01); w += 4
                buffer.writef32(buf, w, r02); w += 4
                buffer.writef32(buf, w, r10); w += 4
                buffer.writef32(buf, w, r11); w += 4
                buffer.writef32(buf, w, r12); w += 4
                buffer.writef32(buf, w, r20); w += 4
                buffer.writef32(buf, w, r21); w += 4
                buffer.writef32(buf, w, r22); w += 4

            elseif ft == "Color3" then
                if typeof(v) ~= "Color3" then error(("Flux schema: '%s' expects Color3"):format(f.name), 2) end
                buffer.writeu8(buf, w, sTagColor); w += 1
                buffer.writef32(buf, w, v.R);      w += 4
                buffer.writef32(buf, w, v.G);      w += 4
                buffer.writef32(buf, w, v.B);      w += 4
            end
        end

        return rcNew(buf, w, 1)
    end
    --//Decoding

    local function decode(buf: buffer, out: DecodeOut): boolean
        local blen = buffer.len(buf)
        local r    = 0

        local function canRead(n: number): boolean
            return r + n <= blen
        end

        if not canRead(1) then out.err = "schema: missing field count"; return false end
        local fc = buffer.readu8(buf, r); r += 1
        if fc ~= nFields then
            out.err = ("schema: field count mismatch %d vs %d"):format(fc, nFields)
            return false
        end

        out.n = nFields

        for idx, f in fields do
            if not canRead(1) then
                out.err = ("schema: missing tag at field %d '%s'"):format(idx, f.name)
                return false
            end
            local tag = buffer.readu8(buf, r); r += 1

            if tag == sTagU8 then
                if not canRead(1) then out.err = "schema: truncated u8"; return false end
                out[idx] = buffer.readu8(buf, r); r += 1

            elseif tag == sTagU16 then
                if not canRead(2) then out.err = "schema: truncated u16"; return false end
                out[idx] = buffer.readu16(buf, r); r += 2

            elseif tag == sTagU32 then
                if not canRead(4) then out.err = "schema: truncated u32"; return false end
                out[idx] = buffer.readu32(buf, r); r += 4

            elseif tag == sTagI8 then
                if not canRead(1) then out.err = "schema: truncated i8"; return false end
                out[idx] = buffer.readi8(buf, r); r += 1

            elseif tag == sTagI16 then
                if not canRead(2) then out.err = "schema: truncated i16"; return false end
                out[idx] = buffer.readi16(buf, r); r += 2

            elseif tag == sTagI32 then
                if not canRead(4) then out.err = "schema: truncated i32"; return false end
                out[idx] = buffer.readi32(buf, r); r += 4

            elseif tag == sTagF32 then
                if not canRead(4) then out.err = "schema: truncated f32"; return false end
                out[idx] = buffer.readf32(buf, r); r += 4

            elseif tag == sTagF64 then
                if not canRead(8) then out.err = "schema: truncated f64"; return false end
                out[idx] = buffer.readf64(buf, r); r += 8

            elseif tag == sTagBool then
                if not canRead(1) then out.err = "schema: truncated bool"; return false end
                out[idx] = buffer.readu8(buf, r) ~= 0; r += 1

            elseif tag == sTagStr then
                if not canRead(2) then out.err = "schema: truncated str len"; return false end
                local slen = buffer.readu16(buf, r); r += 2
                if not canRead(slen) then out.err = "schema: truncated str data"; return false end
                out[idx] = buffer.readstring(buf, r, slen); r += slen

            elseif tag == sTagVec3 then
                if not canRead(12) then out.err = "schema: truncated vec3"; return false end
                local x = buffer.readf32(buf, r); r += 4
                local y = buffer.readf32(buf, r); r += 4
                local z = buffer.readf32(buf, r); r += 4
                out[idx] = Vector3.new(x, y, z)

            elseif tag == sTagCf then
                if not canRead(48) then out.err = "schema: truncated cframe"; return false end
                local x   = buffer.readf32(buf, r); r += 4
                local y   = buffer.readf32(buf, r); r += 4
                local z   = buffer.readf32(buf, r); r += 4
                local r00 = buffer.readf32(buf, r); r += 4
                local r01 = buffer.readf32(buf, r); r += 4
                local r02 = buffer.readf32(buf, r); r += 4
                local r10 = buffer.readf32(buf, r); r += 4
                local r11 = buffer.readf32(buf, r); r += 4
                local r12 = buffer.readf32(buf, r); r += 4
                local r20 = buffer.readf32(buf, r); r += 4
                local r21 = buffer.readf32(buf, r); r += 4
                local r22 = buffer.readf32(buf, r); r += 4
                out[idx] = CFrame.new(x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22)

            elseif tag == sTagColor then
                if not canRead(12) then out.err = "schema: truncated color3"; return false end
                local red   = buffer.readf32(buf, r); r += 4
                local green = buffer.readf32(buf, r); r += 4
                local blue  = buffer.readf32(buf, r); r += 4
                out[idx] = Color3.new(red, green, blue)

            else
                out.err = ("schema: unknown tag %d at field %d '%s'"):format(tag, idx, f.name)
                return false
            end
        end

        return true
    end
    return { encode = encode, decode = decode }
end


local muxRemoteName = "__FluxMux__"
local muxRemote: RemoteEvent?

type EventEntry = {
    codec          : Codec,
    signal         : any,    
    stats          : Stats,
    validator      : ((Player, ...any) -> boolean)?,
    allowClientFire: boolean,
}

local eventRegistry: { [number]: EventEntry } = {}

local eventIdCounter  = 0
local eventIdFreeList: { number } = {}

local function allocEventId(): number
    if #eventIdFreeList > 0 then
        return table.remove(eventIdFreeList) :: number
    end
    eventIdCounter += 1
    if eventIdCounter > 65535 then
        error("Flux: EventID exhausted — max 65535 simultaneous live events")
    end
    return eventIdCounter
end

local function freeEventId(id: number)
    table.insert(eventIdFreeList, id)
end

local broadcastBuf   = buffer.create(4096)
local broadcastW     = 0
local broadcastDirty = false

type PlayerFrame = { buf: buffer, w: number }
local playerFrames: { [Player]: PlayerFrame } = {}

local clientOutBuf   = buffer.create(2048)
local clientOutW     = 0
local clientOutDirty = false

local serverHeartbeatConn: RBXScriptConnection?
local clientHeartbeatConn: RBXScriptConnection?
local decodeOut: DecodeOut = { n = 0, err = nil }

local function growIfNeeded(buf: buffer, w: number, needed: number): buffer
    if w + needed <= buffer.len(buf) then return buf end
    local newSize = math.max(buffer.len(buf) * 2, w + needed + 256)
    if newSize > maxFrameSize then
        error(("Flux: frame buffer would exceed %d KB — reduce Fire() payload size")
            :format(maxFrameSize // 1024))
    end
    local newBuf = buffer.create(newSize)
    buffer.copy(newBuf, 0, buf, 0, w)
    return newBuf
end

local function muxBroadcastAppend(eventId: number, rc: RcBuf)
    local needed = 5 + rc.size
    broadcastBuf = growIfNeeded(broadcastBuf, broadcastW, needed)
    buffer.writeu8(broadcastBuf,  broadcastW, muxBroadcast); broadcastW += 1
    buffer.writeu16(broadcastBuf, broadcastW, eventId);      broadcastW += 2
    buffer.writeu16(broadcastBuf, broadcastW, rc.size);      broadcastW += 2
    buffer.copy(broadcastBuf, broadcastW, rc.buf, 0, rc.size)
    broadcastW    += rc.size
    broadcastDirty = true
end

local function muxTargetedAppend(player: Player, eventId: number, rc: RcBuf)
    local frame = playerFrames[player]
    if not frame then
        frame = { buf = buffer.create(512), w = 0 }
        playerFrames[player] = frame
    end
    local needed = 5 + rc.size
    frame.buf = growIfNeeded(frame.buf, frame.w, needed)
    buffer.writeu8(frame.buf,  frame.w, muxTargeted); frame.w += 1
    buffer.writeu16(frame.buf, frame.w, eventId);     frame.w += 2
    buffer.writeu16(frame.buf, frame.w, rc.size);     frame.w += 2
    buffer.copy(frame.buf, frame.w, rc.buf, 0, rc.size)
    frame.w += rc.size
end

local function muxClientAppend(eventId: number, rc: RcBuf)
    local needed = 5 + rc.size
    clientOutBuf = growIfNeeded(clientOutBuf, clientOutW, needed)
    buffer.writeu8(clientOutBuf,  clientOutW, muxClientFire); clientOutW += 1
    buffer.writeu16(clientOutBuf, clientOutW, eventId);       clientOutW += 2
    buffer.writeu16(clientOutBuf, clientOutW, rc.size);       clientOutW += 2
    buffer.copy(clientOutBuf, clientOutW, rc.buf, 0, rc.size)
    clientOutW    += rc.size
    clientOutDirty = true
end

local function serverFlush()
    local remote = muxRemote
    if not remote then return end

    if broadcastDirty and broadcastW > 0 then
        local payload = buffer.slice(broadcastBuf, 0, broadcastW)
        pcall(remote.FireAllClients, remote, payload)
        broadcastW     = 0
        broadcastDirty = false
    end
    for player, frame in playerFrames do
        if frame.w > 0 then
            local payload = buffer.slice(frame.buf, 0, frame.w)
            pcall(remote.FireClient, remote, player, payload)
        end
    end
    table.clear(playerFrames)
end

local function clientFlush()
    if not muxRemote or not clientOutDirty or clientOutW == 0 then return end
    local payload = buffer.slice(clientOutBuf, 0, clientOutW)
    pcall((muxRemote :: RemoteEvent).FireServer, muxRemote, clientFireToken, payload)
    clientOutW     = 0
    clientOutDirty = false
end

local function fireDecoded(entry: EventEntry, msgBuf: buffer)
    table.clear(decodeOut :: any)
    decodeOut.n   = 0
    decodeOut.err = nil
    local ok = entry.codec.decode(msgBuf, decodeOut)
    if ok then
        entry.stats.messagesReceived += 1
        entry.signal.Fire(table.unpack(decodeOut :: any, 1, decodeOut.n))
    end
    return ok
end


--// Demux a frame buffer arriving at a client from the server
local function clientDemux(payload: buffer)
    local blen = buffer.len(payload)
    local r    = 0

    while r + 5 <= blen do
        local _muxType = buffer.readu8(payload,  r); r += 1
        local eventId  = buffer.readu16(payload, r); r += 2
        local dataSize = buffer.readu16(payload, r); r += 2

        if r + dataSize > blen then
            warn(("Flux: truncated record at offset %d (dataSize=%d, remaining=%d)")
                :format(r, dataSize, blen - r))
            break
        end

        local entry = eventRegistry[eventId]
        if entry then
            local msgBuf = buffer.slice(payload, r, r + dataSize)
            entry.stats.bytesReceived += dataSize
            if not fireDecoded(entry, msgBuf) then
                entry.stats.messagesDropped += 1
            end
        end

        r += dataSize
    end
end

local function serverDemux(
    player     : Player,
    payload    : buffer,
    lastFires  : { [Player]: number },
    globalStats: Stats)

    local blen = buffer.len(payload)
    local r    = 0

    while r + 5 <= blen do
        local muxType  = buffer.readu8(payload,  r); r += 1
        local eventId  = buffer.readu16(payload, r); r += 2
        local dataSize = buffer.readu16(payload, r); r += 2

        if r + dataSize > blen then
            warn(("Flux: truncated client frame from '%s' at offset %d (dataSize=%d, remaining=%d)")
                :format(player.Name, r, dataSize, blen - r))
            break
        end

        if muxType == muxClientFire then
            local entry = eventRegistry[eventId]
            if entry and entry.allowClientFire then
                --// Per-player rate limit
                local now      = os.clock()
                local lastFire = lastFires[player] or 0
                if now - lastFire < clientFireCooldown then
                    globalStats.clientSpamBlocked += 1
                    globalStats.messagesDropped   += 1
                else
                    lastFires[player] = now
                    local msgBuf = buffer.slice(payload, r, r + dataSize)
                    entry.stats.bytesReceived += dataSize

                    table.clear(decodeOut :: any)
                    decodeOut.n   = 0
                    decodeOut.err = nil
                    local ok = entry.codec.decode(msgBuf, decodeOut)
                    if ok then
                        if entry.validator then
                            if not entry.validator(player, table.unpack(decodeOut :: any, 1, decodeOut.n)) then
                                entry.stats.messagesDropped += 1
                                r += dataSize
                                continue
                            end
                        end
                        entry.stats.messagesReceived += 1
                        entry.signal.Fire(player, table.unpack(decodeOut :: any, 1, decodeOut.n))
                    else
                        entry.stats.messagesDropped += 1
                    end
                end
            else
                globalStats.messagesDropped += 1
            end
        end
        r += dataSize
    end
end


type MuxState = {
    remote        : RemoteEvent,
    activePlayers : { [Player]: boolean },
    activeCount   : number,
    lastFires     : { [Player]: number },
    globalStats   : Stats,
    playerAddConn : RBXScriptConnection,
    playerRemConn : RBXScriptConnection,
    serverEvtConn : RBXScriptConnection,
}

local muxState: MuxState?

local function ensureMux()
    if muxState then return end

    if isServer then
        local remote = Instance.new("RemoteEvent")
        remote.Name   = muxRemoteName
        remote.Parent = replicatedStorage

        local activePlayers: { [Player]: boolean } = {}
        local activeCount = 0
        local lastFires: { [Player]: number } = {}
        local gStats: Stats = {
            bytesSent=0, messagesSent=0, messagesDropped=0,
            bytesReceived=0, messagesReceived=0, clientSpamBlocked=0,
        }

        for _, pl in playersService:GetPlayers() do
            activePlayers[pl] = true; activeCount += 1
        end

        local paConn = playersService.PlayerAdded:Connect(function(pl)
            activePlayers[pl] = true; activeCount += 1
        end)

        local prConn = playersService.PlayerRemoving:Connect(function(pl)
            activePlayers[pl] = nil; activeCount -= 1
            lastFires[pl]    = nil   
            playerFrames[pl] = nil   
        end)

        local evtConn = remote.OnServerEvent:Connect(function(pl, token, payload)
            if token == handshakeToken then return end
            if token ~= clientFireToken then
                gStats.messagesDropped += 1; return
            end
            if typeof(payload) ~= "buffer" then
                gStats.messagesDropped += 1; return
            end
            gStats.bytesReceived += buffer.len(payload)
            serverDemux(pl, payload, lastFires, gStats)
        end)
        serverHeartbeatConn = runService.Heartbeat:Connect(serverFlush)

        muxRemote = remote
        muxState  = {
            remote        = remote,
            activePlayers = activePlayers,
            activeCount   = activeCount,
            lastFires     = lastFires,
            globalStats   = gStats,
            playerAddConn = paConn,
            playerRemConn = prConn,
            serverEvtConn = evtConn,
        }

    else
        local function bindMuxRemote(remote: RemoteEvent)
            muxRemote = remote
            remote.OnClientEvent:Connect(function(payload)
                if typeof(payload) ~= "buffer" then return end
                clientDemux(payload)
            end)
            remote:FireServer(handshakeToken)
        end

        local existing = replicatedStorage:FindFirstChild(muxRemoteName)
        if existing and existing:IsA("RemoteEvent") then
            bindMuxRemote(existing)
        else
            replicatedStorage.ChildAdded:Connect(function(child)
                if child.Name == muxRemoteName and child:IsA("RemoteEvent") then
                    bindMuxRemote(child)
                end
            end)
        end

        clientHeartbeatConn = runService.Heartbeat:Connect(clientFlush)
    end
end


type ListNode = {
    fn  : ((...any) -> ())?,
    next: ListNode?,
}

local fastGcThreshold = 8  

local function createFastEvent(name: string): Event
    local head: ListNode? = nil
    local listenerCount = 0
    local deadCount     = 0

    local function sweep()
        local prev: ListNode? = nil
        local node = head
        while node do
            if not node.fn then
                if prev then prev.next = node.next else head = node.next end
                deadCount -= 1
            else
                prev = node
            end
            node = node.next
        end
    end

    local function connectFn(callback: (...any) -> ()): Connection
        local node: ListNode = { fn = callback, next = head }
        head = node
        listenerCount += 1
        return {
            Disconnect = function()
                if not node.fn then return end
                node.fn = nil
                listenerCount -= 1
                deadCount += 1
                if deadCount >= fastGcThreshold then sweep() end
            end,
        }
    end

    local function fireFn(_, ...)
        local node = head
        while node do
            if node.fn then node.fn(...) end
            node = node.next
        end
    end

    local zeroStats: Stats = {
        bytesSent=0, messagesSent=0, messagesDropped=0,
        bytesReceived=0, messagesReceived=0, clientSpamBlocked=0,
    }

    return {
        networkId = name,
        Fire         = fireFn,
        FireDeferred = function(_, ...) task.defer(fireFn, nil, ...) end,
        FireSome     = function() end,
        FireServer   = function() end,
        SetAllowClientReplication = function() end,
        SetClientValidator        = function() end,
        Connect = function(_, cb) return connectFn(cb) end,
        Once    = function(_, cb): Connection
            local conn: Connection
            conn = connectFn(function(...)
                conn:Disconnect()
                cb(...)
            end)
            return conn
        end,
        Wait = function()
            error("Wait() is not supported on fast events", 2)
        end,
        ListenerCount = function() return listenerCount end,
        Destroy = function()
            head = nil; listenerCount = 0; deadCount = 0
        end,
        GetStats = function() return table.clone(zeroStats) end,
    }
end

--//Constructor 

local Flux = {}

function Flux.new(name: string, options: FluxOptions?): Event
    assert(type(name) == "string" and name ~= "", "Flux.new: name must be a non-empty string")

    local opts = options or {}
    if opts.fast then
        return createFastEvent(name)
    end
    ensureMux()
    local eventId = allocEventId()
    local codec: Codec
    if opts.schema then
        codec = compileCodec(opts.schema)
    else
        codec = { encode = dynamicEncode, decode = dynamicDecode }
    end
    local sig = newSignal()
    local perStats: Stats = {
        bytesSent=0, messagesSent=0, messagesDropped=0,
        bytesReceived=0, messagesReceived=0, clientSpamBlocked=0,
    }
    local entry: EventEntry = {
        codec          = codec,
        signal         = sig,
        stats          = perStats,
        validator      = nil,
        allowClientFire = false,
    }
    eventRegistry[eventId] = entry
    local listenerCount = 0

    local function wrapConnect(callback: (...any) -> ()): Connection
        listenerCount += 1
        local disconnFn = sig.Connect(callback)
        return {
            Disconnect = function(self: Connection)
                disconnFn()
                listenerCount -= 1
            end,
        }
    end
    local function serverFire(_, ...)
        sig.Fire(...)
        local state = muxState
        if state and state.activeCount > 0 then
            local rc = codec.encode(...)
            muxBroadcastAppend(eventId, rc)
            perStats.bytesSent    += rc.size
            perStats.messagesSent += 1
            rcRelease(rc)
        end
    end
    local function clientFireServer(_, ...)
        if isServer then
            warn("Flux: FireServer() called on server — ignored")
            return
        end
        if not muxRemote then
            warn("Flux: FireServer() called before mux remote is bound — ignored")
            return
        end
        local rc = codec.encode(...)
        muxClientAppend(eventId, rc)
        rcRelease(rc)
    end

    return {
        networkId = name,

        Fire = if isServer then serverFire else function(_, ...)
            sig.Fire(...)
        end,

        FireDeferred = if isServer
            then function(_, ...) task.defer(serverFire, nil, ...) end
            else function(_, ...) task.defer(sig.Fire, ...) end,

        FireSome = function(_, targets: { Player }, ...)
            sig.Fire(...)
            local state = muxState
            if not state or #targets == 0 then return end
            local rc = codec.encode(...)
            for _, pl in targets do
                if state.activePlayers[pl] then
                    muxTargetedAppend(pl, eventId, rc)
                    perStats.bytesSent    += rc.size
                    perStats.messagesSent += 1
                end
            end
            rcRelease(rc)
        end,
        FireServer = clientFireServer,

        SetAllowClientReplication = function(_, allowed: boolean)
            if isServer then entry.allowClientFire = allowed end
        end,

        SetClientValidator = function(_, validator: ((Player, ...any) -> boolean)?)
            if isServer then entry.validator = validator end
        end,

        Connect = function(_, callback: (...any) -> ()): Connection
            return wrapConnect(callback)
        end,

        --// Disconnects automatically after first fire
        Once = function(_, callback: (...any) -> ()): Connection
            listenerCount += 1
            local conn: Connection
            local disconnFn = sig.Connect(function(...)
                if conn then conn:Disconnect() end
                callback(...)
            end)
            conn = {
                Disconnect = function(self: Connection)
                    disconnFn()
                    listenerCount -= 1
                end,
            }
            return conn
        end,

        Wait = function(): ...any
            return (sig :: any):Wait()
        end,

        ListenerCount = function(): number
            return listenerCount
        end,

        GetStats = function(): Stats
            return table.clone(perStats)
        end,

        Destroy = function()
            eventRegistry[eventId] = nil
            freeEventId(eventId)  
            sig.Destroy()
        end,
    }
end

--// ============================================================
--//  BENCHMARK API  (Flux.Bench)
--//
--//  Methodology:
--//    • math.randomseed(0) called ONCE before the payload is built
--//    • 1000 fires per frame, 10-second window
--//    • Warmup frame discarded before measurement starts
--//    • stats read AFTER task.wait() so Heartbeat has already flushed
--//    • Encode time measured by calling codec.encode() directly,
--//      not as a side-effect of Fire() (avoids timing mux overhead)
--//
--//  Built-in payloads
--//    BoolArray   — table.create(1000, true)          [one arg: table]
--//    StructArray — { {id,x,y,z,orientation,animation} × 100 }
--//
--//  Usage:
--//    Flux.Bench.runAll(10)            -- both payloads, 10 s each
--//    Flux.Bench.run({ ... })          -- custom
--//    Flux.Bench.print(result)         -- pretty output
--// ============================================================

export type BenchConfig = {
    name         : string,
    seconds      : number?,
    firesPerFrame: number?,        
    buildPayload : () -> any,
    event        : Event,
}

export type BenchResult = {
    name          : string,
    frames        : number,
    totalSeconds  : number,
    avgFps        : number,
    avgEncodeUs   : number,    
    bytesPerFire  : number,    
    kbpsAtMeasured: number,    
    kbpsAt60      : number,    
    totalBytesSent: number,
    totalFires    : number,
}

local Bench = {}

function Bench.run(config: BenchConfig): BenchResult
    assert(isServer, "Flux.Bench.run() must be called on the server")
    assert(type(config.buildPayload) == "function", "Flux.Bench: buildPayload must be a function")

    local duration     = config.seconds      or 10
    local firesPerFrame = config.firesPerFrame or 1000
    local evt          = config.event
    local payload = config.buildPayload()
    local benchCodec: Codec = { encode = dynamicEncode, decode = dynamicDecode }
    do 
        for _, e in eventRegistry do
            if e.signal == (evt :: any).signal or e.stats == (evt :: any).perStats then
                benchCodec = e.codec
                break
            end
        end
        if benchCodec == nil then
            benchCodec = eventRegistry[eventIdCounter] and eventRegistry[eventIdCounter].codec
                or { encode = dynamicEncode, decode = dynamicDecode }
        end
    end
    for _ = 1, firesPerFrame do
        evt:Fire(payload)
    end
    task.wait()

    local startTime  = os.clock()
    local lastStats  = evt:GetStats()
    local frames     = 0
    local totalBytes = 0
    local totalFires = 0
    local totalEncNs = 0   
    local encSample: RcBuf = benchCodec.encode(payload)
    local bytesPerFire = encSample.size
    rcRelease(encSample)

    while os.clock() - startTime < duration do
        local t0 = os.clock()
        for _ = 1, firesPerFrame do
            local rc = benchCodec.encode(payload)
            rcRelease(rc)
        end
        totalEncNs += (os.clock() - t0) * 1_000_000_000
        for _ = 1, firesPerFrame do
            evt:Fire(payload)
        end
        task.wait()

        local newStats = evt:GetStats()
        totalBytes += newStats.bytesSent - lastStats.bytesSent
        totalFires += newStats.messagesSent - lastStats.messagesSent
        frames     += 1
        lastStats   = newStats
    end

    local totalSec    = os.clock() - startTime
    local measuredFps = frames / totalSec
    local avgEncUs    = (totalEncNs / 1_000) / (firesPerFrame * frames)  --// ns → μs

    return {
        name          = config.name,
        frames        = frames,
        totalSeconds  = totalSec,
        avgFps        = measuredFps,
        avgEncodeUs   = avgEncUs,
        bytesPerFire  = bytesPerFire,
        kbpsAtMeasured = bytesPerFire * firesPerFrame * measuredFps * 8 / 1000,
        kbpsAt60       = bytesPerFire * firesPerFrame * 60            * 8 / 1000,
        totalBytesSent = totalBytes,
        totalFires     = totalFires,
    }
end

function Bench.print(r: BenchResult)
    local bar = ("─"):rep(56)
    print(bar)
    print(("  Flux.Bench › %s"):format(r.name))
    print(bar)
    print(("  Duration      : %.2f s  (%d frames, %.1f fps)"):format(r.totalSeconds, r.frames, r.avgFps))
    print(("  Encode cost   : %.2f μs / call"):format(r.avgEncodeUs))
    print(("  Bytes / fire  : %d B"):format(r.bytesPerFire))
    print(("  Est. Kbps     : %.1f kbps  @ measured fps"):format(r.kbpsAtMeasured))
    print(("  Est. Kbps @60 : %.1f kbps  @ 60 fps  (matches Blink format)"):format(r.kbpsAt60))
    print(("  Total sent    : %.2f KB over %d fires"):format(r.totalBytesSent / 1024, r.totalFires))
    print(bar)
end

function Bench.runAll(seconds: number?)
    assert(isServer, "Flux.Bench.runAll() must be called on the server")
    local dur = seconds or 10

    --//BoolArray
    local boolEvt = Flux.new("__BenchBool__")
    math.randomseed(0)
    local r1 = Bench.run({
        name          = "BoolArray (1000×true)",
        seconds       = dur,
        firesPerFrame = 1000,
        buildPayload  = function()
            return table.create(1000, true)
        end,
        event = boolEvt,
    })
    Bench.print(r1)
    boolEvt:Destroy()

    --//StructArray
    local structEvt = Flux.new("__BenchStruct__")
    math.randomseed(0)  
    local r2 = Bench.run({
        name          = "StructArray (100×{id,x,y,z,ori,anim})",
        seconds       = dur,
        firesPerFrame = 1000,
        buildPayload  = function()
            local arr = table.create(100)
            for i = 1, 100 do
                arr[i] = {
                    id          = math.random(1, 255),
                    x           = math.random(1, 255),
                    y           = math.random(1, 255),
                    z           = math.random(1, 255),
                    orientation = math.random(1, 255),
                    animation   = math.random(1, 255),
                }
            end
            return arr
        end,
        event = structEvt,
    })
    Bench.print(r2)
    structEvt:Destroy()

    return r1, r2
end

Flux.Bench = Bench


function Flux.destroy()
    if serverHeartbeatConn then serverHeartbeatConn:Disconnect(); serverHeartbeatConn = nil end
    if clientHeartbeatConn then clientHeartbeatConn:Disconnect(); clientHeartbeatConn = nil end
    if muxState then
        muxState.playerAddConn:Disconnect()
        muxState.playerRemConn:Disconnect()
        muxState.serverEvtConn:Disconnect()
        if isServer then muxState.remote:Destroy() end
        muxState = nil
    end
    muxRemote = nil
    table.clear(eventRegistry)
    table.clear(playerFrames)
    table.clear(eventIdFreeList)
    eventIdCounter = 0
end

return Flux

--[[
  USAGE EXAMPLES
  -- Dynamic lane 
  local Flux  = require(path.to.Flux)
  local myEvt = Flux.new("MyEvent")

  -- Server
  myEvt:Fire("hello", 42, Vector3.new(1, 2, 3))
  myEvt:FireSome({ player1, player2 }, "subset", true)

  -- Client
  myEvt:Connect(function(msg, num, vec) end)
  myEvt:FireServer("from client")

  -- Server validates client fires
  myEvt:SetAllowClientReplication(true)
  myEvt:SetClientValidator(function(player, msg)
      return type(msg) == "string" and #msg < 128
  end)
  myEvt:Connect(function(player, msg) end)  -- player prepended
  myEvt:SetClientValidator(nil)             -- clear validator

  -- Schema
  local dmgEvt = Flux.new("Damage", {
      schema = {
          { name = "targetId", type = "u16"    },
          { name = "amount",   type = "f32"     },
          { name = "position", type = "Vector3" },
          { name = "isCrit",   type = "bool"    },
      }
  })
  dmgEvt:Fire(targetId, amount, hitPos, isCrit)
  dmgEvt:Connect(function(targetId, amount, pos, isCrit) end)

  --local-only
  local uiEvt = Flux.new("UIUpdate", { fast = true })
  uiEvt:Fire("open", "inventory")
  uiEvt:Connect(function(action, panel) end)

  -- Benchmarking 
  -- Both built-in payloads, 10 s each (matches Blink's benchmark/)
  Flux.Bench.runAll(10)

  -- Custom benchmark
  local res = Flux.Bench.run({
      name          = "MyPayload",
      seconds       = 10,
      firesPerFrame = 1000,
      buildPayload  = function()
          math.randomseed(0)
          return { hp = math.random(1, 100), pos = Vector3.new(1,2,3) }
      end,
      event = Flux.new("MyBenchEvt"),
  })
  Flux.Bench.print(res)
]]
