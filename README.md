# DQR ZeroFarm

Autofarm script for Dungeon Quest Reborn (Roblox) with **[Cascade UI](https://github.com/cascadeui/Cascade)** (macOS Sequoia-style GUI). Built as a security audit PoC.

## Features

**Combat Tab**
- Kill Aura — `weaponUsed` remote spam
- Auto Ability — casts Q/E via Tool `localEvent`, respects cooldowns and `busyCasting`
- Auto Dodge — perpendicular sidestep away from 24+ projectile types
- Auto Start — fires `readyUp` and `changeStartValue`
- Nerf Enemies — zeros `moveSpeed`, maxes `attackSpeed` client-side
- No Stun — removes `stunned` tag and `PlatformStand`
- Barrier Bypass — removes room barrier collision
- Steppers: WalkSpeed | Slider: Retreat HP %

**Movement Tab**
- Farm Distance, Orbit Distance, Dodge Range (steppers)
- Lead Time slider for velocity prediction

**Window Tab**
- Dark/Light theme toggle, accent color picker
- Minimize keybind field, searchable window
- Stop button

**Pathing Tab**
- Repath interval, waypoint timeout, ability delay

**Under the Hood**
- Movement arbiter with priority system: dodge > retreat > orbit > path
- PathfindingService navigation with stuck detection, jump retry, Path.Blocked repath
- BodyGyro aim-lock — always faces nearest enemy
- Velocity prediction on moving enemies
- Anti-cheat spoof for `underworldBossSpecficEvents`
- Anti-AFK via VirtualUser

## Usage

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/YOUR_USER/DQR-ZeroFarm/main/ZeroFarm.lua"))()
```

Or execute `ZeroFarm.lua` directly in your executor.

```lua
-- Runtime config via _G.ZF table or the Rayfield GUI
-- Stop:
_G.StopZF()
```

## Architecture

```
ZeroFarm.lua
  Cascade UI (macOS Sequoia style)
    Combat Tab ─── toggles + steppers for all combat features
    Movement Tab ── orbit/dodge/range tuning
    Window Tab ──── theme, accent, keybinds
    Pathing Tab ─── path recompute + timeout tuning

  Movement Arbiter (Heartbeat)
    dodge (4) ─── perpendicular projectile sidestep
    retreat (3) ── HP-based flee
    orbit (2) ─── circle-strafe combat
    path (1) ──── PathfindingService navigation

  Combat: Kill Aura, Auto Ability (localEvent), Enemy Nerf
  Defense: Auto Dodge, BodyGyro, Anti-Stun, HP Retreat
  Utility: Barrier Clear, Anti-Cheat Spoof, Auto Start, Anti-AFK
```

## Security Findings

See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the full black-box audit:
- BridgeNet2 rate limiter bug (critical)
- Client-writable ValueObjects and enemy stats
- 206 remotes cataloged

See [ZEROHUB_DEOBFUSCATION.md](ZEROHUB_DEOBFUSCATION.md) for the Zero Hub v0.3.8 deobfuscation (Luarmor v4, 61 flags, 401 strings).

## Disclaimer

Educational and security research purposes only.
