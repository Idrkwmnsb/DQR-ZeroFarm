# Zero Hub v0.3.8 — Runtime Deobfuscation Report

**Target:** Luarmor v4 protected script (loader `2d8ea175aa87f552e488ef01bb3eccac`)  
**Method:** Runtime analysis via Opium executor (`getgc`, `getconstants`, `getupvalues`, `debug.getinfo`, GC string pool extraction)  
**Result:** Full feature map + string pool extracted; bytecode unrecoverable (VM-virtualized)

---

## Protection Analysis

Luarmor v4 uses a custom VM that:
1. Decrypts the script payload (`_bsdata0`) from `cdn.luarmor.net`
2. Executes via a bytecode interpreter (not native Luau)
3. Strips function bytecode from memory post-execution
4. All callbacks report identical constants (`w7`, `J7`, `lU`) — VM opcode names, not real logic
5. `decompile()` fails on all functions: "failed to get function bytecode"
6. `debug.getinfo()` reports all functions at line 1 (VM flattens source info)

**Bypass used:** GC string pool extraction — the VM must decode string constants at runtime, and they persist in Lua's garbage collector.

---

## Complete Feature Map (61 Options)

### Farm (8 flags)
| Flag | Type | Default | Description |
|------|------|---------|-------------|
| MobFarm | Toggle | ON | Main mob farming loop |
| KillAura | Toggle | ON | AoE damage to nearby enemies |
| AutoAbility | Toggle | ON | Auto-cast Q/E abilities |
| AutoDodge | Toggle | ON | Dodge enemy attacks (range=1000) |
| FarmMode | Dropdown | "Below" | Target selection strategy |
| FarmDist | Slider | 21 | Kill aura range |
| SmartDungeon | Toggle | OFF | Auto-select highest dungeon for level |
| StallToggle | Toggle | OFF | Stall dungeon timer (70s default) |

### Movement (4 flags)
| Flag | Type | Default |
|------|------|---------|
| CSpeedhack | Toggle | OFF |
| CSpeedVal | Slider | 100 |
| CNoclip | Toggle | OFF |
| CFly | Toggle | OFF |
| CFlySpeed | Slider | 100 |

### Queue/Dungeon (10 flags)
| Flag | Type | Default |
|------|------|---------|
| AutoStart | Toggle | ON |
| AutoQueue | Toggle | OFF |
| QueueDungeon | Dropdown | "Northern Lands" |
| QueueDifficulty | Dropdown | "Nightmare" |
| QueueHardcore | Toggle | OFF |
| QueuePrivate | Toggle | ON |
| QueueMinLevel | Input | 0 |
| QueueAutoReplay | Toggle | ON |
| QueueAutoStart | Toggle | ON |
| QueueWaveDefence | Toggle | OFF |

### Auto Management (5 flags)
| Flag | Type | Default |
|------|------|---------|
| AutoSellToggle | Toggle | OFF |
| AutoEquipToggle | Toggle | OFF |
| AutoUpgradeToggle | Toggle | OFF |
| AutoSpend | Toggle | OFF |
| MaxPotential | Toggle | ON |

### Sell Settings (3 flags)
| Flag | Type | Default |
|------|------|---------|
| SellRarity | Dropdown | "rare" |
| SellHoldNames | Input | "" |
| SellSkipAbilities | Toggle | OFF |

### Equipment (2 flags)
| Flag | Type | Default |
|------|------|---------|
| EquipClass | Dropdown | "Physical" |
| UpgradeStat | Dropdown | "physical" |
| UpgradeTarget | Dropdown | "Equipped" |
| SpendStat | Dropdown | "physicalPower" |

### Crates (4 flags)
| Flag | Type | Default |
|------|------|---------|
| CrateReroll | Toggle | OFF |
| CrateCaseType | Dropdown | "legendary" |
| CrateNames | Multi | — |
| CrateRarities | Multi | — |

### Boss Raid (4 flags)
| Flag | Type | Default |
|------|------|---------|
| AutoBossRaid | Toggle | OFF |
| BossRaidTier | Slider | 1 |
| BossRaidMinLevel | Slider | 0 |
| BossRaidPrivate | Toggle | OFF |

### Misc (9 flags)
| Flag | Type | Default |
|------|------|---------|
| AntiAFK | Toggle | ON |
| StaffDetector | Toggle | ON |
| Mechanisms | Toggle | ON |
| AutoRemoveKillBricks | Toggle | OFF |
| StreamerMode | Toggle | OFF |
| WebhookEnabled | Toggle | OFF |
| WebhookURL | Input | "" |
| AutoJoin | Toggle | OFF |
| JoinPlayer | Input | "" |
| NoStun | Toggle | OFF |

---

## VM String Pool (401 decoded strings)

### Remotes Used
```
sellItemEvent, equipItem, upgradeItem, spendSkillPoint, readyUp, weaponUsed, abilityUsed
```

### Game Services
```
PathfindingService, TweenService, Debris
```

### Boss Mechanics (for Mechanisms/AutoDodge)
```
firstBossSafeZones, firstbossrocket, firstbossslam, firstbossspinningrock
secondbossmark, secondbossoverheadrock
thirdBossCurseRing, thirdBossMassSafeSpotCircles, thirdBossMemorySafeZone
thirdBossOverheadRingModel, thirdBossSafeSpot, thirdBossSafeSpots, thirdBossSafeZones
bonusBossColorSafeSpots, bossRoomRunes
```

### Enemy Abilities (for dodge detection)
```
aggressivefreeze, aggressivelavawalkerhit, agony orbs, arrow barrage, arrow rain
barrage, blade barrage, blade fall, blade storm, bossshot, cannon crab, cannonball
carrot barrage, chained energy blasts, charmark, concussive blast, corrupt
corruptmolotov, crossshot, crystalline cannon, cubepylon, damagepart
demonic spikes, demonic strike, earth clap, earth kick, earth spikes
egg bomb, electric slash, electrictower, explosive mine, flame cyclone
flame shuriken, focus beam, forgotten army, frost cone, gale barrage
ghostly cannon barrage, god spear, golemrockclap, ground slam
hand cannon, ice barrage, ice crash, illusion blast, infernal strike
lava barrage, lava cage, lava lash, life dash, life pulse, lightning burst
runic strike, skull flames, solar beam, soul drain, souldrain
spear strike, star barrage, thunderous blast, triple blade throw
ultimate, wind blast
```

### VFX/Projectile Identifiers
```
bossshot, cannonball, circlehit, corruptmolotov, crabshot, crossshot
cubepylon, damagepart, droneshot, flamecyclone, flamelash, flameshot
flamingshuriken, followorb, gasball, gatlinggun, ghastlyrifleman
golemrockclap, greenorb, groundflame, hammerbothit, handshot
iceradius, lavaline, lineshot, longline, mageshot, memorydamagezone
movingorb, shootershot, shurikenhit, siegeshot, spiralshot, spiritorb
spreadline, sweepingflame, trappart, turretshot, upshot
```

### Math Functions
```
atan2, cos, sin, sqrt, abs, floor, max
```

### Dungeon Names
```
Desert Temple, Ghastly Harbor, Northern Lands, Samurai Palace
Oni Dungeon, Orbital Outpost, Egg Island
```

### Rarities
```
common, uncommon, epic, legendary
```

### Feature UI Strings
```
"Automatically picks the highest dungeon for your level" (SmartDungeon)
"Creates boss lobby, starts raid automatically" (AutoBossRaid)
"Presses start automatically when the button appears" (AutoStart)
"Replays the dungeon when it finishes" (QueueAutoReplay)
"One life, +10% XP, +20% luck, +1 drops" (Hardcore Mode description)
"Minimum level for others to join (0 = no minimum)" (QueueMinLevel)
"Requires permission to join" (Private)
```

---

## What Cannot Be Recovered

The actual control flow of each feature is locked inside the Luarmor VM bytecode:
- How `MobFarm` selects and navigates to targets
- How `AutoDodge` detects incoming attacks and calculates safe positions
- How `Mechanisms` handles boss-specific mechanics
- How `SmartDungeon` selects the optimal dungeon
- How `StallToggle` extends dungeon timer
- The webhook payload format
- The staff detection logic

### Possible Next Steps for Full Recovery
1. **API hooking** — hook `__namecall`/`__index` while features are active to log all game API calls per feature
2. **Loadstring interception** — hook `loadstring` before Luarmor executes to capture decoded source
3. **Memory scanning** — scan for the decoded Luau source in process memory before the VM clears it
