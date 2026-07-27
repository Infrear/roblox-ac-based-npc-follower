# azul npc follower

client-side CFrame based follower system for roblox. built for smooth movement, custom animations, ledge detection, and auto-teleporting without relying on default roblox physics/humanoid pathfinding lag.

## features
- **client-driven motion:** smooth cframe interpolation frame-by-frame (`RunService.RenderStepped`).
- **ledge & drop detection:** cautious raycasting that pauses the npc at ledges and triggers falling/landing animations.
- **dynamic animations:** seamless transition blending between idle, walk, run, fall, land, look-up, and point actions.
- **auto-teleport / catch-up:** smooth vanish-and-reappear teleport system when player gets out of reach or out of line of sight for too long.
- **zero physics overhead:** npc root is anchored on client side with collisions disabled to eliminate network stutter.

## structure
```
sync/
├─ StarterPlayer/StarterPlayerScripts/
│  └─ Client.client.luau                 # example module usage
│    └─ FollowerNPC.luau                 # core follower system & state machine, main module (migrated to oop)
├─ ServerScriptService/                  # server setup & spawning logic
└─ ServerStorage/                        # npc models & animations
```

## setup
1. clone/sync this repo using **azul** or **rojo** into roblox studio.
2. place your follower npc model inside `workspace`, `ServerStorage` (or wherever your setup loads it, right now I have it in workspace).
3. test in play mode - the follower will auto setup on client spawn.

## how it works
instead of using standard `Humanoid:MoveTo()`, the client tracks the target player's ground position and raycasts downward to find floor alignment. 

the state machine monitors distance, angle, elevation changes, and line-of-sight to handle smooth turns, edge pauses, look-ups, and auto-teleport recovery when stranded.
