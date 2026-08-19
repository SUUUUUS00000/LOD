# LOD System
Hides objects that are at a distance from the player, increasing FPS.

Objects are hidden in a special folder located in the `ReplicatedStorage` service

# EnableDynamicFPS mode
You can also optionally enable the `EnableDynamicFPS` mode, this should significantly increase FPS on weak devices
You'll need to change the mode from false to true. It should look something like this:
```lua
_G.LOD_SETTINGS = _G.LOD_SETTINGS or {
EnableDynamicFPS = true,
TargetFPS = 60
}
```
