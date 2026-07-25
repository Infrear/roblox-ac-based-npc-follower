---
description: Tween management — naming conventions, when to predefine TweenInfo vs. build inline, and resolving tween race conditions on repeated triggers
---

# Workflow 1: Roblox Tween Management

## Naming Conventions
1. **Services**: `TS = game:GetService("TweenService")`, declared at the top of the script alongside all other services — never inline or lazily required elsewhere.
2. **Tween instances**: always called `TE` (singular) or `TES` (table, plural) — never `tween`, `myTween`, etc.
3. **TweenInfo**: always called `TI` (singular) or `TIS`/`STIS`/`FTIS` (table, plural — prefix as needed to disambiguate purpose, e.g. `FTIS` for "flat" tween infos, `STIS` for "scaled" ones).
4. **Connections tied to a tween** (e.g. `.Completed:Connect(...)`): follow the general connection-naming rules in Workflow 2.

## When to Use a Table (`TES`) vs. a Single Variable (`TE`)
- If a script manages many GUI objects/instances that each need their own tween (e.g. a whole skills menu, a list of buttons), use an external `TES = {}` keyed by the instance: `TES[GuiObject] = TS:Create(...)`.
- If you know for certain there will only ever be **one** active tween for a given purpose in that scope, don't build a table for it — just use `TE = nil` / `currentTE`, and same for connections (`con = nil` / `currentCon`). Don't force the table pattern where a single variable does the job.

## Predefining TweenInfo (`TIS`) — Only When Possible
- When tween duration/easing is fixed and known ahead of time, predefine `TweenInfo.new(...)` objects once at the top of the script (or in an init table like `BASE_STIS`/`FTIS`) and reuse them. This avoids re-allocating a `TweenInfo` every call.
- **Do not force this.** If any parameter of the tween (most commonly duration) is an *input* to the system rather than a constant — e.g. a function takes `duration` as an argument — you cannot predefine the `TweenInfo`. Build it inline at the point of use instead: `TS:Create(obj, TweenInfo.new(duration, ...), goal)`.
- Rule of thumb: predefine when the tween's shape is a property of the *system*; build inline when it's a property of the *call*.

## Resolving Tween Race Conditions (Repeated/Spammed Triggers)
This is the pattern you were describing as "hysteresis" — that's not quite the right term (hysteresis is a system whose output depends on its history via a deliberate dead-zone, like a thermostat). What's actually happening is a **race condition between two competing tweens on the same object/property**: if a fairly long tween is still playing and gets re-triggered (classic case: a toggle button spamming open → close → open), the new tween starts fighting the old one for control of the same property, and it compounds the more it's spammed.

**Fix pattern** (seen throughout `guithing.lua`, e.g. `AnimsManager.FocusOnTri`):
1. Before creating a new `TE` for an object, check if one already exists in the `TES` table for that object.
2. If it exists and `PlaybackState == Enum.PlaybackState.Playing`, call `:Cancel()` on it first.
3. Only then assign the new `TS:Create(...)` result and `:Play()` it.

```lua
if sme.TES[tri] then
	if sme.TES[tri].PlaybackState == Enum.PlaybackState.Playing then
		sme.TES[tri]:Cancel()
	end
end
sme.TES[tri] = TS:Create(tri, AnimsManager.FTIS.SpazIn, {Size = sme.Default})
sme.TES[tri]:Play()
```

This only applies to tweens on the **same object** — don't add this guard reflexively to every tween; only where retriggering is actually possible (rapid input, toggles, hover/click state machines).

## Steps
1. **Set up services**: confirm `TS = game:GetService("TweenService")` exists near the top with other services before writing any tween logic.
2. **Decide table vs. single variable**: scan the surrounding scope — if multiple instances of this tween type can exist concurrently, use a `TES`/`Cons` table keyed by instance; otherwise use single `TE`/`con` variables.
3. **Decide predefined vs. inline `TweenInfo`**: if any tween parameter comes from a function argument or runtime data, build the `TweenInfo` inline at the call site. Otherwise predefine it once in an init table.
4. **Guard against race conditions**: for anything re-triggerable by rapid input (buttons, hover states, toggles), cancel any existing playing tween on that object before creating and playing the new one.
5. **Match existing style**: cross-reference `charactercustomization.lua`, `NPCs.lua`, and `guithing.lua` for the exact table-naming and cancellation idioms already in use before introducing a new one.