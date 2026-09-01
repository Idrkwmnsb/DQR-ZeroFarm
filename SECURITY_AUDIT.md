# DQR Security Audit — Live Black-Box Testing Report

**Game:** Dungeon Quest Reborn (place 77649408247578)  
**Subplace tested:** Level (place 85776757589518)  
**Date:** 2026-08-31  
**Executor:** Opium (roblox-mcp)  
**Player:** brenbrr8 (Level 199, 127B gold, 12K gems)

---

## CRITICAL VULNERABILITIES

### 1. BridgeNet2 Rate Limiter Broken
**Severity:** Critical  
**Location:** `ReplicatedStorage.Utility.BridgeNet2.Server.ServerProcess`  
**Bug:** `math.min(0, v16)` should be `math.max(0, v16)` — rate limit variable can never be positive, so the limiter never activates.  
**Impact:** Clients can send unlimited packets (tested: 50 packets in 0.0002s). Enables remote spam, server flooding.

### 2. Client-Writable ValueObjects (Workspace)
**Severity:** Critical  
**Verified writable:**
| ValueObject | Default | Set To | Persisted |
|---|---|---|---|
| `workspace.hardcore` | false | true | Yes (client-only) |
| `workspace.tier` | 0 | 99 | Yes (client-only) |
| `workspace.currentWave` | 0 | 999 | Yes (client-only) |
| `workspace.start` | false | true | Yes (client-only) |
| `workspace.dungeonStarted` | false | true | Yes (client-only) |
| `workspace.pause` | false | — | Writable |

**Impact:** Client-side only (Roblox doesn't replicate ValueObject changes back to server). However, if any client script reads these values and sends them to the server via remotes, it becomes exploitable. The `hardcore` flag client-side change could desync reward UI.

### 3. Client-Writable Enemy Stats
**Severity:** High  
**Verified writable:**
| Property | Effect |
|---|---|
| `enemy.Humanoid.Health` | Set to 0 — client sees enemy as dead |
| `enemy.damage.Value` | Set to 0 — no visual damage |
| `enemy.moveSpeed.Value` | Set to 0 — enemy stops moving client-side |
| `enemy.attackSpeed.Value` | Set to 999 — enemy stops attacking client-side |

**Server validation:** CONFIRMED — setting enemy HP to 0 client-side does NOT award gold/XP. Server tracks enemy health independently. Enemy remains in game server-side.  
**Impact:** Cosmetic griefing, client-side desync. Not directly exploitable for rewards.

### 4. WalkSpeed / Movement Exploits
**Severity:** High  
**Verified:**
- `Humanoid.WalkSpeed` writable every frame (no anti-cheat detection)
- `BasePart.CanCollide` writable for character parts (noclip)
- Room barriers `CanCollide` writable (skip locked rooms)
- `PathfindingService` works normally (not restricted)

**Impact:** Full movement freedom — speed hack, noclip, barrier bypass, pathfinding to any location. Combined with weaponUsed spam, enables autofarm.

---

## CONFIRMED SECURE SYSTEMS

### Remotes with Server-Side Validation
| System | Remote | Test | Result |
|---|---|---|---|
| Cmdr | CmdrFunction | `giveGold` command | Blocked by BeforeRun hook (group rank check) |
| Gold/Gems/Level | leaderstats | Direct value write | Server-authoritative, changes rejected |
| Skill Points | spendSkillPoint | — | Server validates available points |
| Equipment | equipItem | — | Server validates ownership |
| Sell System | sellItemEvent | — | Server validates item exists |
| Trade | acceptTradeRequest | Without partner | Server rejects |
| DataRequester | getData | — | Only safe getters exposed |
| AssetRequester | requestAsset | — | Server-side asset delivery |
| Enemy Kills | Humanoid.Health=0 | Set client-side | No gold/XP awarded (server-independent) |
| Item Storage | moveItemToStorage | During dungeon | Returns false (blocked in dungeon) |
| Item Storage | moveItemToInventory | During dungeon | Returns false (blocked in dungeon) |
| Lobby Creation | createLobby | During dungeon | Returns false |

### BridgeNet2 Bridges (10 total)
| Bridge | Identifier | Purpose |
|---|---|---|
| NIL_VALUE | \x00 | Null sentinel |
| REQUEST | \x01 | Request/response |
| precastHitbox | \x02 | Hit detection |
| action | \x03 | Player actions |
| EnemyEffects | \x04 | Enemy VFX |
| enemy | \x05 | Enemy state sync |
| timestamp | \x06 | Time sync |
| item | \x07 | Item operations |
| status | \x08 | Status updates |
| message | \x09 | Chat/messages |

---

## AUTOFARM VECTORS (Verified)

### Working Exploits for Autofarm
1. **WalkSpeed hack** — `Humanoid.WalkSpeed = 80-100` every frame, no detection
2. **Barrier bypass** — `barrier.CanCollide = false` to skip room locks
3. **Noclip** — character `CanCollide = false` every frame
4. **PathfindingService** — compute paths to enemies, walk along waypoints
5. **weaponUsed spam** — FireServer with 0.1-0.15s interval (no rate limit due to BridgeNet2 bug)
6. **abilityUsed spam** — FireServer("q"/e", nil) for auto-ability
7. **changeStartValue + readyUp** — auto-start dungeons

### NOT Working for Autofarm
1. **Enemy HP = 0** — cosmetic only, no server-side kill
2. **CFrame teleport** — rubber-banded by anti-cheat
3. **Enemy PivotTo** — fails in executor context
4. **Tweening** — patched (Zero Hub TweenSpeed exists but may not work)

### Autofarm Scripts Created
- [`DQR_Autofarm_PoC.lua`](DQR_Autofarm_PoC.lua) — 6-module PoC (speed, noclip, barrier, auto-kill, nerf, attack spam)
- [`DQR_Pathfind_Farm.lua`](DQR_Pathfind_Farm.lua) — PathfindingService-based farm with MoveTo waypoints

---

## REMOTE CENSUS (206 remotes in subplace)

### Potentially Interesting Untested Remotes
| Remote | Type | Notes |
|---|---|---|
| castVotekickVote | RemoteEvent | Fires without error — server validation unknown |
| kickPlayerFromBossLobby | RemoteEvent | Could grief boss lobby players |
| upgradeKey | RemoteEvent | Key tier manipulation |
| bonusBossPlayerVote | RemoteFunction | Boss vote manipulation |
| selectCharacterSlot | RemoteFunction | Character slot switching |
| requestCosmeticPurchase | RemoteEvent | Cosmetic purchase |
| equipArmorCosmetic | RemoteEvent | Cosmetic equip |
| teleportToFriend | RemoteEvent | Teleport to friend |
| teleportToTutorial | RemoteEvent | Teleport to tutorial |
| eggEvent | RemoteEvent | Easter event |

### New Remotes (Not in main place)
| Remote | Type | Notes |
|---|---|---|
| moveItemToStorage | RemoteFunction | Returns false during dungeon |
| moveItemToInventory | RemoteFunction | Returns false during dungeon |
| getPlayerStorage | RemoteFunction | Returns full storage inventory |
| reloadInvy | RemoteFunction | Returns full inventory (5 categories) |
| checkNextTierKey | RemoteFunction | Key tier check |

---

## ZERO HUB v0.3.8 ANALYSIS

Full deobfuscation report: [`ZeroHub_Deobfuscation_Report.md`](ZeroHub_Deobfuscation_Report.md)

**Summary:** 61 feature flags extracted, 401 VM string constants decoded. Luarmor v4 bytecode protection prevents source recovery. Script uses PathfindingService (not just TweenService), has boss mechanism dodge tables for all dungeons, staff detection, webhook integration, and full dungeon queue automation.

---

## RECOMMENDATIONS FOR GAME DEVELOPERS

1. **Fix BridgeNet2 rate limiter** — `math.min(0, v16)` → `math.max(0, v16)` (critical, one-character fix)
2. **Server-side WalkSpeed enforcement** — validate player movement speed/distance per tick
3. **Server-side barrier collision** — don't rely on client-side CanCollide for room progression
4. **Add anti-cheat for movement** — detect teleportation, speed anomalies, wall clipping
5. **Rate limit weaponUsed/abilityUsed** — server-side cooldown enforcement per player
6. **Make enemy stats server-only** — use NumberValue on server, replicate via remotes only
7. **Protect workspace ValueObjects** — use server-side state tracking, not writable workspace values
8. **Test votekick validation** — ensure `castVotekickVote` validates target player exists
9. **Test storage operations in lobby** — `moveItemToStorage`/`moveItemToInventory` blocked in dungeon but untested in lobby (potential dupe vector)
