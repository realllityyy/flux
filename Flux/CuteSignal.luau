--!strict
--!native

type Callback = (...any) -> ()
export type Disconnect = () -> ()

type SignalCore = {
	Fire: (...any) -> (),
	Connect: (callback: Callback) -> Disconnect,
	DisconnectAll: () -> (),
	Destroy: () -> (),
	Count: () -> number,
}

export type Signal = SignalCore & {
	Once: (self: Signal, callback: Callback) -> Disconnect,
	HasConnections: (self: Signal) -> boolean,
	IsDestroyed: (self: Signal) -> boolean,
}

type Slot = {
	index: number,
	generation: number,
}

local table_create = table.create
local table_clear = table.clear
local table_freeze = table.freeze
local setmetatable_ = setmetatable

-- Stable no-op function reused for empty/destroyed states.
local function NoopFire(...: any): ()
	return
end

-- Destroyed-state no-op; keeps repeated calls safe and branch-free.
local function NoopDisconnectAll(): ()
	return
end

-- Destroyed-state no-op; keeps repeated calls safe and branch-free.
local function NoopDestroy(): ()
	return
end

-- Destroyed-state Count implementation.
local function ZeroCount(): number
	return 0
end

-- Connect is disabled after Destroy.
local function DestroyedConnect(_callback: Callback): Disconnect
	error("Signal is destroyed")
end

local function SignalOnce(self: Signal, callback: Callback): Disconnect
	if type(callback) ~= "function" then
		error("Once expects a function callback")
	end

	local disconnect = nil :: any
	disconnect = self.Connect(function(...: any)
		disconnect()
		callback(...)
	end)

	return disconnect
end

local function SignalHasConnections(self: Signal): boolean
	return self.Count() ~= 0
end

local function SignalIsDestroyed(self: Signal): boolean
	return self.Connect == DestroyedConnect
end

local SIGNAL_METHODS = table_freeze({
	Once = SignalOnce,
	HasConnections = SignalHasConnections,
	IsDestroyed = SignalIsDestroyed,
})

local SIGNAL_METATABLE = table_freeze({
	__index = SIGNAL_METHODS,
})

local function NewSignal(): Signal
	local count = 0
	local generation = 1
	local callbacks = {} :: {[number]: Callback?}
	local slots = {} :: {[number]: Slot?}

	local signal: SignalCore

	-- Rebuild dispatch only when topology changes (connect/disconnect),
	-- so Fire itself stays as close as possible to direct callback calls.
	local function RebuildFire(): ()
		local fire: (...any) -> ()

		if count == 0 then
			fire = NoopFire
		elseif count == 1 then
			-- Fastest possible path: Fire becomes the callback itself.
			fire = callbacks[1] :: Callback
		elseif count == 2 then
			fire = function(...: any): ()
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 3 then
			fire = function(...: any): ()
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 4 then
			fire = function(...: any): ()
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 5 then
			fire = function(...: any): ()
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 6 then
			fire = function(...: any): ()
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 7 then
			fire = function(...: any): ()
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 8 then
			fire = function(...: any): ()
				(callbacks[8] :: Callback)(...);
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 9 then
			fire = function(...: any): ()
				(callbacks[9] :: Callback)(...);
				(callbacks[8] :: Callback)(...);
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 10 then
			fire = function(...: any): ()
				(callbacks[10] :: Callback)(...);
				(callbacks[9] :: Callback)(...);
				(callbacks[8] :: Callback)(...);
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 11 then
			fire = function(...: any): ()
				(callbacks[11] :: Callback)(...);
				(callbacks[10] :: Callback)(...);
				(callbacks[9] :: Callback)(...);
				(callbacks[8] :: Callback)(...);
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		elseif count == 12 then
			fire = function(...: any): ()
				(callbacks[12] :: Callback)(...);
				(callbacks[11] :: Callback)(...);
				(callbacks[10] :: Callback)(...);
				(callbacks[9] :: Callback)(...);
				(callbacks[8] :: Callback)(...);
				(callbacks[7] :: Callback)(...);
				(callbacks[6] :: Callback)(...);
				(callbacks[5] :: Callback)(...);
				(callbacks[4] :: Callback)(...);
				(callbacks[3] :: Callback)(...);
				(callbacks[2] :: Callback)(...);
				(callbacks[1] :: Callback)(...);
			end
		else
			-- For larger listener counts, precompute reversed order once and iterate it.
			local snapshot = table_create(count) :: {[number]: Callback}
			local source = count
			for i = 1, count do
				snapshot[i] = callbacks[source] :: Callback
				source -= 1
			end

			local snap = snapshot
			local n = count
			fire = function(...: any): ()
				for i = 1, n do
					snap[i](...)
				end
			end
		end

		signal.Fire = fire
	end

	-- Dot-call only for lower connect overhead: signal.Connect(fn).
	local function Connect(callback: Callback): Disconnect
		if type(callback) ~= "function" then
			error("Connect expects a function callback")
		end

		local index = count + 1
		count = index
		callbacks[index] = callback

		local slot = {
			index = index,
			generation = generation,
		}
		slots[index] = slot

		RebuildFire()

		return function(): ()
			-- Generation check invalidates stale disconnect closures after DisconnectAll.
			if slot.generation ~= generation then
				return
			end

			local remove_index = slot.index
			if remove_index == 0 then
				return
			end

			local last = count
			if remove_index ~= last then
				-- O(1) erase by swapping with the tail slot.
				callbacks[remove_index] = callbacks[last]
				callbacks[last] = nil

				local moved_slot = slots[last]
				slots[remove_index] = moved_slot
				slots[last] = nil
				if moved_slot ~= nil then
					moved_slot.index = remove_index
				end
			else
				callbacks[last] = nil
				slots[last] = nil
			end

			count = last - 1
			slot.index = 0
			RebuildFire()
		end
	end

	local function DisconnectAll(): ()
		if count == 0 then
			return
		end

		-- Bump generation so old disconnect closures become inert immediately.
		generation += 1
		count = 0
		table_clear(callbacks)
		table_clear(slots)
		signal.Fire = NoopFire
	end

	local function Destroy(): ()
		DisconnectAll()
		signal.Connect = DestroyedConnect
		signal.DisconnectAll = NoopDisconnectAll
		signal.Destroy = NoopDestroy
		signal.Count = ZeroCount
	end

	local function Count(): number
		return count
	end

	signal = {
		Fire = NoopFire,
		Connect = Connect,
		DisconnectAll = DisconnectAll,
		Destroy = Destroy,
		Count = Count,
	}

	return (setmetatable_(signal :: Signal, SIGNAL_METATABLE) :: any) :: Signal
end

return NewSignal
