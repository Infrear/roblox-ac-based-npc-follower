---
description: Connection lifecycle management — table-based tracking, table.clear reuse, Event:Once guarded disconnects, and Maid/Janitor + task.spawn() for more complex lifecycles
---

# Workflow 2: Connections & Preventing Data Leaks

## Core Pattern
- All `RBXScriptConnection`s go into a table (commonly named `Cons`, `generalCons`, or `cons` for a single-purpose local) and get disconnected in a loop when the owning object/UI/state is torn down:
```lua
for i, v in pairs(Cons) do
	v:Disconnect()
end
```
- **Reuse tables with `table.clear()` instead of reassigning `{}`** when the table is a persistent, outside-scope reference (e.g. a module-level `generalCons = {}` that gets reused every time a menu opens/closes) — this avoids extra garbage-collector churn. Don't force this onto a table that's freshly created each call anyway; it only pays off when the table already exists as a long-lived variable.
- **Use `task.wait()`, not `wait()`**: legacy `wait()` runs on Roblox's older 30 Hz throttled path and has a floor of roughly 0.03s regardless of the argument passed in. `task.wait()` is accurate and current — use it everywhere, including in the yield-based patterns below.
- **Use `task.spawn()`, not `coroutine.wrap()`, for fire-and-forget threads**: `coroutine.wrap()` only surfaces an error the *next* time the wrapped function is resumed — if it's a one-shot call (`coroutine.wrap(function() ... end)()`), an error inside it is silently swallowed with no console output. `task.spawn()` runs on Roblox's Task Scheduler and reports errors to the output immediately, same call shape: `task.spawn(function() ... end)`. Swap existing one-shot `coroutine.wrap()` calls to `task.spawn()` — it's a drop-in replacement for the fire-and-forget case.

## `Event:Once()` — Use When It Makes Sense, Still Guard It
- When a connection is genuinely fire-once (e.g. waiting for a single state change before moving on), prefer `Event:Once(function() ... end)` over `Connect` + manual `:Disconnect()` — it self-cleans after firing.
- **Even so, always check the connection exists before calling `:Disconnect()` on it elsewhere** (e.g. in a cleanup path that might run before or after the `:Once` has already fired and cleared itself):
```lua
if con and con.Connected then
	con:Disconnect()
end
```
This defensive check costs nothing and avoids errors from disconnecting something already gone.

## Maid / Janitor Pattern (for when a plain table isn't enough)
Your manual `Cons` table approach is correct and sufficient for most scripts — don't add a dependency for its own sake. Reach for a **Maid** (or the near-identical **Janitor**) when an object's cleanup surface grows past "a handful of connections," specifically when you're also cleaning up:
- Instances (`:Destroy()`)
- Plain functions (arbitrary cleanup callbacks)
- Nested child objects that themselves have their own cleanup method

**What it is**: a Maid is a small utility (originated in Quenty's Nevermore Engine, also implemented as "Janitor" by RoStrap/others) that centralizes all of the above into one container. **It is not a built-in Roblox class** — there's no `Maid` service or global to `require()`. You either pull in a community module or drop in your own implementation as a ModuleScript. Below is a corrected reference implementation (this fixes two real bugs that show up in naive versions of this class — see the notes after the code):

```lua
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end

-- List-style add (order doesn't matter, cleaned up on next :DoCleaning()/:Destroy())
function Maid:GiveTask(job)
	table.insert(self._tasks, job)
	return job
end

-- Keyed add: maid["ActiveTween"] = TS:Create(...) auto-cleans whatever was
-- previously stored under that key before storing the new one.
function Maid:__newindex(index, newJob)
	local oldJob = self._tasks[index]
	if oldJob then
		self:_cleanJob(oldJob)
	end
	self._tasks[index] = newJob
end

function Maid:_cleanJob(job)
	if typeof(job) == "RBXScriptConnection" then
		job:Disconnect()
	elseif typeof(job) == "Instance" then
		-- Tweens ARE Instances (typeof() == "Instance"), so Destroy() here
		-- also halts a still-playing Tween — no separate Tween branch needed.
		job:Destroy()
	elseif type(job) == "function" then
		job()
	elseif type(job) == "table" and typeof(job.Destroy) == "function" then
		job:Destroy()
	elseif type(job) == "thread" then
		task.cancel(job)
	end
end

function Maid:DoCleaning()
	for index, job in pairs(self._tasks) do
		self:_cleanJob(job)
	end
	table.clear(self._tasks)
end

Maid.Destroy = Maid.DoCleaning

return Maid
```

**Bug notes (fixed above, flag these if you see the naive version elsewhere):**
1. Never name the per-task parameter `task` in `_cleanJob` — it shadows the global `task` library, so `task.cancel(task)` tries to index the thread itself for a `.cancel` method instead of calling the real library, and errors at runtime the first time a thread needs cancelling. Named it `job` here instead.
2. There's no `typeof() == "RBXScriptTween"` type in Roblox — that check is dead code. A `Tween` from `TweenService:Create()` reports `typeof() == "Instance"`, so it already falls into the `Instance` branch and gets `:Destroy()`'d, which also stops playback. No separate Tween-specific branch is needed.

**Where `task.spawn()` fits in**: `task.spawn()` starts a new thread that runs immediately (unlike the legacy `spawn()`, which deferred to the next `Heartbeat`/resumption cycle). The leak risk is that a `task.spawn()`'d thread is **not automatically tied to the lifetime of the object that created it** — if that object gets destroyed/cleaned up while the thread is still running (mid-`task.wait()`, mid-loop), the thread keeps executing and can touch destroyed instances or stale state. Two ways to handle this, matching your existing style:
1. **Cheap/manual (matches Workflow 3)**: capture a local `interrupted`/`stopped` flag or generation token in the closure, and check it after every yield inside the spawned thread before continuing.
2. **Maid-integrated**: `task.spawn()` returns a `thread`, which the Maid above accepts directly (`maid:GiveTask(task.spawn(function() ... end))`) and cancels via `task.cancel()` on cleanup. This is the more robust option once the object already has a Maid for its connections — just give it the thread too, rather than hand-rolling a flag.

Use whichever fits the script's existing complexity — plain `Cons` table + flags for smaller scripts (your default), Maid/Janitor once an object's cleanup involves more than connections.

## Steps
1. **Track every connection**: as soon as `:Connect(...)` is called, store the result in a `Cons`/`generalCons` table (or a single `con` variable if only one can ever exist at a time — see Workflow 1's table-vs-single-variable rule, it applies here too).
2. **Tear down on cleanup**: at the point where the owning object/menu/state is done, loop through and `:Disconnect()` everything, then clear the table with `table.clear()` if it's a reused, long-lived table — reassign `{}` only if it's freshly scoped each time anyway.
3. **Prefer `Event:Once()` for genuinely one-shot listeners**, but still defensively check `.Connected` (or nil-check) before any manual `:Disconnect()` elsewhere in case it already fired.
4. **Escalate to Maid/Janitor only when justified**: if the object's cleanup involves instances, functions, *and* connections together — not just connections alone — introduce a Maid rather than expanding the manual table pattern further. Use the corrected implementation above, not a naive one with the `task` shadowing bug.
5. **Guard `task.spawn()` threads**: if a script spawns a thread that outlives a single frame (contains a `task.wait()` or loop), either check an `interrupted` flag after every yield, or hand the thread to the object's Maid via `task.cancel()` on cleanup.
6. **Swap legacy calls opportunistically**: when editing a script that still uses `wait()`, `spawn()`, or one-shot `coroutine.wrap()`, replace with `task.wait()`/`task.spawn()` as part of the same change — don't leave the old and new style mixed in one file.