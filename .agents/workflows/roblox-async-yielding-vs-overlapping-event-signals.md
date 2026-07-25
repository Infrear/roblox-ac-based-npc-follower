---
description: Preventing premature completion of long-running async actions when they overlap with newer triggers or event signals — the "throwaway callback" / cancellation-token pattern
---

# Workflow 3: Async Yielding vs. Overlapping Event Signals

## The Problem
Some actions are started, yield for a while (`task.wait(n)`), and then run a "finish" step afterward — a hand-grab ability that waits 10 seconds before retracting, a fire effect that waits 20 seconds before extinguishing, a UI element that waits before fading out. The bug: if the same action (or a related one) is re-triggered *during* that wait, the **original** wait still finishes on its own schedule and runs its finish step — even though the new trigger means the finish step is now premature. The old callback needs to become a **throwaway**: it should recognize a newer trigger happened and quietly do nothing instead of finishing early.

This isn't specific to one system — it applies any time "wait, then finish" logic can be restarted before the wait is up. It does **not** apply when re-triggering is impossible or meaningless (e.g. a hand that's already stretched out can't be grabbed again, so there's nothing to protect against) — only add this where overlap can actually happen.

## The Pattern
Use a signal that fires every time the action restarts, paired with an `interrupted` flag checked after every yield:

```lua
local stopEv = Instance.new("BindableEvent")  -- or a module-level one reused across calls

local function doTimedAction()
	stopEv:Fire()  -- invalidate any previous in-flight call

	local interrupted = false
	local con
	con = stopEv.Event:Connect(function()
		interrupted = true
		con:Disconnect()
	end)

	-- ... start the action (e.g. turn fire VFX on, extend the hand) ...

	task.wait(20)

	if interrupted then
		if con then con:Disconnect() end
		return  -- a newer trigger already fired; this call is a throwaway, do nothing
	end

	-- ... finish the action (e.g. turn fire off, retract hand) ...
	if con then con:Disconnect() end
end
```

Why it works: every new call to `doTimedAction` fires `stopEv` first, which flips `interrupted = true` on every *previously running* call's listener. When an old call wakes up from its `task.wait()`, it checks its own `interrupted` flag before doing anything destructive — if a newer call already superseded it, it just disconnects and returns instead of finishing early.

**Terminology note**: this is generally called a **cancellation token** (or sometimes "generation token"/"epoch" pattern) in general async programming — a lightweight, disposable flag/signal that lets a stale async operation detect it's been superseded and bail out instead of completing. It's the same family of idea as Workflow 2's `task.spawn()` thread-lifetime problem, just solved with a flag instead of `task.cancel()`.

## Lightweight Alternative: Incrementing Sequence Token
The `BindableEvent` + `interrupted` version above is worth its overhead specifically when a currently-yielding action needs something **proactively cancelled mid-wait** — e.g. `TES[tri]:Cancel()`-ing a tween the moment a new trigger comes in, rather than waiting for the old wait to finish on its own. When nothing needs to be actively stopped and you only need to **skip stale finish-logic after the wait completes anyway** (the fire-particle and hand-grab examples are both this simpler case), a plain incrementing integer avoids allocating a `BindableEvent`/connection at all:

```lua
local currentSequenceId = 0

local function runDelayedEffect()
	currentSequenceId += 1
	local localToken = currentSequenceId

	fireEmitter.Enabled = true
	task.wait(10)

	if localToken ~= currentSequenceId then
		return -- a newer call already bumped the counter; throw this one away
	end

	fireEmitter.Enabled = false
end
```

**Choosing between the two**: use the `BindableEvent`/`interrupted` version when something mid-flight needs to be actively cancelled the moment a new trigger arrives (tweens, animations). Use the sequence-token version when the only requirement is "don't let a stale wait run its finish step" and nothing needs to be proactively interrupted — it's strictly cheaper since it avoids instantiating a Roblox `Instance` for a purely internal signal (see the Bad Practice Audit below for where this actually matters in your existing code).

## Good Practice Regardless of Which Variant You Use
- Always disconnect the `stopEv` listener when the call finishes normally, not just on the interrupted path — it's easy to leak these if you only remember the early-return branch.
- If using `Event:Once(function() ... end)` for the stop signal instead of `Connect`, still nil/`.Connected`-check before any manual disconnect elsewhere, per Workflow 2.
- Reuse a single `stopEv` (module- or object-scoped) rather than creating a new `BindableEvent` per call — creating one per call works but is wasteful if this action can fire often.

## Steps
1. **Identify overlap risk**: before adding this pattern, confirm the action can actually be re-triggered while a previous instance is still yielding. If re-triggering is impossible or already blocked upstream, skip this — don't add cancellation-token overhead where it can't matter.
2. **Pick the variant**: if a mid-flight tween/animation needs to be actively cancelled the instant a new trigger fires, use the `BindableEvent`/`interrupted` version. If the only need is to discard a stale finish step, use the cheaper sequence-token version.
3. **Set up the signal**: use an existing `stopEv` if the object already has one (e.g. shared with a UI transition's cleanup) or bump the existing counter — don't create a new `BindableEvent` per call if a persistent one already exists in scope.
4. **Fire/bump-then-listen**: at the start of the action, invalidate any in-flight previous call (`:Fire()` or `+= 1`), then set up whatever check the chosen variant needs.
5. **Check after every yield**: anywhere the function resumes after a `task.wait()`, `:Wait()`, or similar, check `interrupted`/the token before running the "finish" logic — if stale, disconnect (if applicable) and return early instead.
6. **Clean up on the normal path too**: disconnect any listener whether the function finishes normally or bails out early — don't only handle the interrupted branch.

---

--- description: Sprite sheet / high-resolution UI texture warm-up before first display, to reduce first-show flicker ---
# Workflow 4: UI Sprite Sheet & Texture Warm-Up

`ContentProvider:PreloadAsync()` ensures assets are downloaded and marked loaded, but a flash/flicker on first display is a real, commonly-reported issue on the Roblox dev forum even with correct preloading — this is not fully solved by `PreloadAsync()` alone, and the exact underlying engine mechanism isn't officially documented, so treat the fix below as an empirical community workaround rather than confirmed internals.

**Known prerequisite (already validated in your NPC chat sprite work)**: UI elements must be parented into the live UI tree (`PlayerGui`, not sitting detached in `ReplicatedStorage`/`script`) *before* calling `PreloadAsync()` — preloading elements that aren't yet part of the live DataModel tree is a documented gotcha that can cause preload to silently not do its job.

**Common workaround for residual flicker**: briefly make the element visible (and back off, one or two `RunService.Heartbeat:Wait()` steps) during initialization, before the UI is meant to actually show, then hide it again:

```lua
local function initSpriteSheets()
	-- 1. Build/parent grid structures into the live UI tree first
	-- 2. Preload
	CPV:PreloadAsync(assetList)

	-- 3. Warm-up pass: briefly visible, then hidden again
	for _, bar in ipairs(uiBars) do
		bar.Visible = true
		bar.Secondary.Visible = true

		RS.Heartbeat:Wait()
		RS.Heartbeat:Wait()

		bar.Visible = false
		bar.Secondary.Visible = false
	end

	-- 4. Bind animation loops
end
```

## Steps
1. **Parent into the live tree first**: confirm sprite sheet UI elements are already under `PlayerGui` (or otherwise live in the DataModel) before calling `PreloadAsync()` on them.
2. **Preload**: call `CPV:PreloadAsync(assetList)` and yield for it to complete.
3. **Warm-up pass only if flicker is actually observed**: don't add the visible/hidden toggle loop preemptively — confirm there's a real flash first, since this is a workaround for an inconsistent engine behavior, not a guaranteed fix.
4. **Restore hidden state before binding anything else**: make sure `Visible` is set back to its true initial state before any animation or reveal logic runs.