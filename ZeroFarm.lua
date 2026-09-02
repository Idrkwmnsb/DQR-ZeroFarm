--[[
    DQR ZeroFarm v8.1 — Cascade UI Edition
    Security audit PoC autofarm for Dungeon Quest Reborn

    v8.1 dodge rewrite:
      • Per-frame (Heartbeat) threat scan + trajectory prediction — ~16ms reaction
      • Minimal-offset dodging: moves only far enough to clear the projectile
      • Obstacle-aware: raycasts every dodge candidate, never steps into walls
      • Micro-teleport is last-resort only (tiny, capped) when a hit is unavoidable
      • Freeze fixed at the source: no post-dodge wait, arbiter re-issues MoveTo on
        target change, movement re-armed immediately after a micro-TP
      • Attacks (kill aura / abilities) never pause for dodging
      • Live breadcrumbs HUD: action / threat / prediction / target / reason

    Execute in your executor directly.
    _G.StopZF() to stop | Right Ctrl to minimize
]]

-- ============================================================
-- CONFIG
-- ============================================================
local C = {
    Speed        = 20,
    FarmDist     = 26,
    KillAura     = true,
    AutoAbility  = true,
    AutoDodge    = true,
    DodgeRange   = 50,
    AutoStart    = true,
    AutoReplay   = true,   -- auto-replay the dungeon when it completes or you run out of time
    ReplayDelay  = 2,      -- seconds to wait (loot/reward screens) before firing replay
    NoStun       = true,
    Noclip       = false,
    Debug        = true,
    ClearDebris  = false,
    AbilityCD    = 0.15,
    RepathMin    = 0.35,
    MoveTimeout  = 1.5,
    ArriveRadius = 5,
    StuckRetry   = 0.6,
    TargetEscape = 14,
    LeadTime     = 0.35,
    DetectRadius = 60,
    -- engagement ranges (spell build: fight from range, don't hug the boss)
    SpellRange   = 85,   -- cast Q/E from this far (spells are ranged, server aims by facing)
    EngageDist   = 42,   -- stop approaching and hold at this range
    HoldDist     = 30,   -- preferred standoff distance from the enemy while fighting
    -- dodge tuning
    ThreatBuffer    = 2.5,  -- extra studs added to each threat's radius
    DodgeMargin     = 2.5,  -- clearance beyond the danger radius when stepping aside
    ThreatLookahead = 1.0,  -- seconds ahead to predict stationary/AoE overlap
    ProjLookahead   = 1.8,  -- seconds ahead to predict MOVING projectile trajectories (earlier)
    GrowthLookahead = 0.45, -- seconds ahead to predict a growing hitbox's size
    MaxGrowth       = 45,   -- cap on predicted growth inflation per axis (studs)
    MaxBossDist     = 46,   -- try not to dodge farther than this from the current target
    -- micro-teleport: last-resort ONLY, used when walking can't clear an imminent hit in time.
    -- Kept small + rate-limited so the server doesn't rubber-band us.
    MicroTP         = true,
    MicroTPDist     = 9,    -- max studs per micro-teleport
    MicroTPCooldown = 0.4,  -- min seconds between micro-teleports (anti rubber-band)
    MicroTPReact    = 0.16, -- only TP when impact is sooner than this AND walking can't reach
    GridHalf        = 4,    -- safe-cell grid is (2*GridHalf+1)^2 cells (9x9)
    GridSpacing     = 3,    -- studs between grid cells (reach = GridHalf*GridSpacing = 12)
    MaxThreats      = 16,   -- cap threats reasoned about per frame (nearest first) for perf
}
_G.ZF = C

-- ============================================================
-- SERVICES
-- ============================================================
local Players = game:GetService("Players")
local PFS = game:GetService("PathfindingService")
local RunS = game:GetService("RunService")
local Rep = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local function lp() return Players.LocalPlayer end
repeat task.wait(0.1) until lp()
repeat task.wait(0.1) until lp().Character and lp().Character:FindFirstChild("Humanoid")

local remotes = Rep:WaitForChild("remotes")
local running = true
local conns = {}

-- ============================================================
-- CASCADE UI
-- ============================================================
local cascadeOk, cascade = pcall(function()
    return loadstring(game:HttpGetAsync(
        "https://github.com/cascadeui/Cascade/releases/latest/download/dist.luau"
    ), "dist.luau")()
end)
if not cascadeOk then warn("[ZF8] Cascade failed:", cascade); cascade = nil end

local minimizeKey = Enum.KeyCode.RightControl
local app

if cascade then
app = cascade.New({
    WindowPill = true,
    Theme = cascade.Themes.Dark,
    Accent = cascade.Accents.Blue,
})

local window = app:Window({
    Title = "ZeroFarm",
    Subtitle = "DQR Autofarm v8.1",
    Draggable = true,
    Searching = true,
    Size = UIS.TouchEnabled and UDim2.fromOffset(500, 320) or UDim2.fromOffset(750, 480),
})

UIS.InputEnded:Connect(function(input, gpe)
    if input.KeyCode == minimizeKey and not gpe then
        window.Minimized = not window.Minimized
    end
end)

-- ── Farm Section ──
local farmSection = window:Section({ Title = "Farm", Disclosure = false })

do -- Combat tab
    local tab = farmSection:Tab({
        Selected = true,
        Title = "Combat",
        Icon = cascade.Symbols.flameFill,
    })

    local form = tab:Form()

    local function toggle(form, title, sub, key)
        local row = form:Row({ SearchIndex = title })
        row:Left():TitleStack({ Title = title, Subtitle = sub })
        row:Right():Toggle({
            Value = C[key],
            ValueChanged = function(_, v) C[key] = v end,
        })
    end

    toggle(form, "Kill Aura", "Spam weaponUsed remote to hit nearby enemies.", "KillAura")
    toggle(form, "Auto Ability", "Cast Q/E abilities via Tool localEvent, respects cooldowns.", "AutoAbility")
    toggle(form, "Auto Dodge", "Predictive, minimal-offset projectile avoidance.", "AutoDodge")
    toggle(form, "No Stun", "Remove stunned tag and PlatformStand.", "NoStun")
    toggle(form, "Noclip", "Walk through walls and objects.", "Noclip")
    toggle(form, "Auto Start", "Auto ready-up and start dungeons.", "AutoStart")
    toggle(form, "Auto Replay", "Replay the dungeon on complete / out of time.", "AutoReplay")
    toggle(form, "Debug HUD", "Show live dodge breadcrumbs overlay.", "Debug")
    toggle(form, "Clear Debris", "Hide small loose parts so they can't block dodges.", "ClearDebris")

    do
        local row = form:Row({ SearchIndex = "WalkSpeed" })
        row:Left():TitleStack({ Title = "WalkSpeed", Subtitle = "16 = default, 20-25 safe, higher risks detection." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.Speed,
            Min = 0,
            Max = 50,
            Increment = 1,
            ValueChanged = function(_, v)
                C.Speed = math.clamp(v, 0, 50)
                local p = lp()
                if p and p.Character then
                    local hum = p.Character:FindFirstChild("Humanoid")
                    if hum then hum.WalkSpeed = C.Speed end
                end
            end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Detect Radius" })
        row:Left():TitleStack({ Title = "Detect Radius", Subtitle = "Search radius before seeking new targets (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.DetectRadius,
            Min = 10,
            Max = 150,
            Increment = 5,
            ValueChanged = function(_, v) C.DetectRadius = math.clamp(v, 10, 150) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Hold Distance" })
        row:Left():TitleStack({ Title = "Hold Distance", Subtitle = "Standoff distance while fighting (higher = safer, ranged)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.HoldDist,
            Min = 5,
            Max = 70,
            Increment = 1,
            ValueChanged = function(_, v) C.HoldDist = math.clamp(v, 5, 70) end,
        })
    end
end

do -- Movement tab
    local tab = farmSection:Tab({
        Title = "Movement",
        Icon = cascade.Symbols.figureWalk,
    })

    local form = tab:Form()

    do
        local row = form:Row({ SearchIndex = "Farm Distance" })
        row:Left():TitleStack({ Title = "Farm Distance", Subtitle = "Kill aura engagement range (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.FarmDist,
            Min = 5,
            Max = 80,
            Increment = 1,
            ValueChanged = function(_, v) C.FarmDist = math.clamp(v, 5, 80) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Dodge Range" })
        row:Left():TitleStack({ Title = "Dodge Range", Subtitle = "Threat detection radius for projectile dodge (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.DodgeRange,
            Min = 5,
            Max = 100,
            Increment = 5,
            ValueChanged = function(_, v) C.DodgeRange = math.clamp(v, 5, 100) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Threat Lookahead" })
        row:Left():TitleStack({ Title = "Threat Lookahead", Subtitle = "Seconds to project projectile trajectories." })
        row:Right():Slider({
            Value = C.ThreatLookahead,
            ValueChanged = function(_, v) C.ThreatLookahead = math.clamp(v, 0.1, 2.0) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Lead Time" })
        row:Left():TitleStack({ Title = "Lead Time", Subtitle = "Aim ahead of moving enemies (seconds)." })
        row:Right():Slider({
            Value = C.LeadTime,
            ValueChanged = function(_, v) C.LeadTime = v end,
        })
    end
end

-- ── Settings Section ──
local settingsSection = window:Section({ Title = "Settings" })

do -- Window tab
    local tab = settingsSection:Tab({
        Selected = true,
        Title = "Window",
        Icon = cascade.Symbols.sidebarLeft,
    })

    do
        local form = tab:PageSection({ Title = "Appearance" }):Form()

        do
            local row = form:Row({ SearchIndex = "Dark mode" })
            row:Left():TitleStack({ Title = "Dark Mode" })
            row:Right():Toggle({
                Value = true,
                ValueChanged = function(_, v)
                    app.Theme = v and cascade.Themes.Dark or cascade.Themes.Light
                end,
            })
        end

        do
            local row = form:Row({ SearchIndex = "Accent" })
            row:Left():TitleStack({ Title = "Accent Color" })
            local accents = {}
            for name in pairs(cascade.Accents) do table.insert(accents, name) end
            table.sort(accents)
            row:Right():PopUpButton({
                Options = accents,
                Value = table.find(accents, "Blue") or 1,
                ValueChanged = function(self, v)
                    app.Accent = cascade.Accents[self.Options[v]]
                end,
            })
        end
    end

    do
        local form = tab:PageSection({ Title = "Controls" }):Form()

        do
            local row = form:Row({ SearchIndex = "Minimize key" })
            row:Left():TitleStack({ Title = "Minimize Keybind" })
            row:Right():KeybindField({
                Value = minimizeKey,
                ValueChanged = function(_, v) minimizeKey = v end,
            })
        end

        do
            local row = form:Row({ SearchIndex = "Stop" })
            row:Left():TitleStack({ Title = "Stop ZeroFarm", Subtitle = "Stops all farm loops and cleans up." })
            row:Right():Button({
                Label = "Stop",
                State = "Destructive",
                Pushed = function()
                    if _G.StopZF then _G.StopZF() end
                end,
            })
        end
    end
end

do -- Path tab
    local tab = settingsSection:Tab({
        Title = "Pathing",
        Icon = cascade.Symbols.mapFill,
    })

    local form = tab:Form()

    do
        local row = form:Row({ SearchIndex = "Repath interval" })
        row:Left():TitleStack({ Title = "Repath Min (s)", Subtitle = "Minimum seconds between path recomputes." })
        row:Right():Slider({
            Value = C.RepathMin,
            ValueChanged = function(_, v) C.RepathMin = math.max(0.05, v) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Waypoint timeout" })
        row:Left():TitleStack({ Title = "Waypoint Timeout (s)", Subtitle = "Give up on a waypoint after this long." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.MoveTimeout,
            Min = 0.3,
            Max = 10,
            Increment = 0.1,
            ValueChanged = function(_, v) C.MoveTimeout = math.clamp(v, 0.3, 10) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Ability delay" })
        row:Left():TitleStack({ Title = "Ability Delay (s)", Subtitle = "Delay between Q and E cast." })
        row:Right():Slider({
            Value = C.AbilityCD,
            ValueChanged = function(_, v) C.AbilityCD = math.max(0.05, v) end,
        })
    end
end

end -- if cascade

-- ============================================================
-- HELPERS
-- ============================================================
local function getChar() local p = lp() return p and p.Character end
local function getHRP() local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = getChar() return c and c:FindFirstChild("Humanoid") end
local function isAlive()
    local h = getHum()
    return h and h.Health > 0 and getHRP() ~= nil
end

local function waitAlive()
    while running and not isAlive() do task.wait(0.5) end
end

local function flatVel(part)
    if not part then return Vector3.zero end
    local ok, v = pcall(function() return part.AssemblyLinearVelocity end)
    if not ok then return Vector3.zero end
    return v * Vector3.new(1, 0, 1)
end

local function flatDist(a, b)
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

-- Raycast a straight line; true if no solid wall blocks it (used for line-of-sight and
-- dodge-cell reachability). Ignores non-collidable effects and enemy models.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function clearPath(fromPos, toPos)
    local char = getChar()
    rayParams.FilterDescendantsInstances = char and { char } or {}
    local dir = toPos - fromPos
    if dir.Magnitude < 0.1 then return true end
    local res = workspace:Raycast(fromPos, dir, rayParams)
    if not res then return true end
    if not res.Instance.CanCollide then return true end       -- effects/props aren't walls
    local m = res.Instance:FindFirstAncestorWhichIsA("Model")
    if m and m:FindFirstChild("Humanoid") then return true end -- enemies aren't walls
    return false
end

-- Shared dodge/AI state (declared early so CharacterAdded handlers can reset it)
local DODGE = {
    active      = false,
    lastTp      = 0,       -- last micro-teleport time (rate limiting)
    strafeUntil = 0,       -- telegraph pre-dodge: keep strafing until this time
    strafeDir   = nil,     -- Vector3 lateral direction chosen for the current telegraph
    baseAction  = "scan",  -- what the AI would do if no threat (set by main loop)
    breadcrumb  = { action = "init", threat = "none", predict = "-", target = "-", reason = "-" },
}

-- ============================================================
-- MOVEMENT ARBITER
-- ============================================================
local MOVE_PRIORITY = { dodge = 4, hold = 3, orbit = 2, path = 1 }
local intent = { owner = "none", pos = nil, untilT = 0 }
local lastMoveSent = 0
local lastMovePos = nil

local function requestMove(owner, pos, ttl)
    local now = tick()
    local myP = MOVE_PRIORITY[owner] or 1
    local active = intent.owner ~= "none" and now < intent.untilT
    if not active or owner == intent.owner or myP >= (MOVE_PRIORITY[intent.owner] or 1) then
        intent.owner = owner
        intent.pos = pos
        intent.untilT = now + (ttl or 0.25)
    end
end

local function clearMove(owner)
    if intent.owner == owner then
        intent.owner = "none"
        intent.pos = nil
        intent.untilT = 0
    end
end

-- [v8.1] Re-issue MoveTo the instant the target moves (fixes dodge lag / post-dodge freeze).
conns.move = RunS.Heartbeat:Connect(function()
    if not running then return end
    local hum = getHum()
    if not hum or not intent.pos then return end
    if tick() > intent.untilT then
        intent.owner = "none"
        intent.pos = nil
        return
    end
    local moved = (not lastMovePos) or (intent.pos - lastMovePos).Magnitude > 0.5
    if moved or tick() - lastMoveSent >= 0.06 then
        hum:MoveTo(intent.pos)
        lastMoveSent = tick()
        lastMovePos = intent.pos
    end
end)

-- ============================================================
-- ENEMIES
-- ============================================================
local function getAllEnemies()
    local out = {}
    local ef = workspace:FindFirstChild("enemies")
    if ef then
        for _, v in ef:GetChildren() do
            if v:IsA("Model") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 and v:FindFirstChild("HumanoidRootPart") then
                table.insert(out, v)
            end
        end
    end
    local dun = workspace:FindFirstChild("dungeon")
    if dun then
        for _, room in dun:GetChildren() do
            local f = room:FindFirstChild("enemyFolder")
            if f then
                for _, v in f:GetChildren() do
                    if v:IsA("Model") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 and v:FindFirstChild("HumanoidRootPart") then
                        table.insert(out, v)
                    end
                end
            end
        end
    end
    -- mobs cloned directly into workspace
    for _, v in workspace:GetChildren() do
        if v:IsA("Model") and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
            if v.Humanoid.Health > 0 and v ~= getChar() then
                if v:FindFirstChild("enemyNameplate") or v:FindFirstChild("enemyTag") or v:FindFirstChild("enemyLevel") then
                    local dominated = false
                    for _, existing in out do
                        if existing == v then dominated = true; break end
                    end
                    if not dominated then table.insert(out, v) end
                end
            end
        end
    end
    return out
end

local function getEnemyRoom(enemy)
    local parent = enemy.Parent
    if not parent then return 0 end
    if parent.Name == "enemyFolder" then
        local room = parent.Parent
        if room then
            local n = tonumber(room.Name:match("room(%d+)"))
            if n then return n end
            if room.Name == "bossRoom" then return 999 end
        end
    end
    return 0
end

local currentTarget = nil

-- Room-aware sticky target selection
local function selectTarget()
    local hrp = getHRP()
    if not hrp then return nil, math.huge end
    local pos = hrp.Position
    local enemies = getAllEnemies()
    if #enemies == 0 then
        currentTarget = nil
        return nil, math.huge
    end

    if currentTarget and currentTarget.Parent and currentTarget:FindFirstChild("Humanoid")
        and currentTarget.Humanoid.Health > 0 and currentTarget:FindFirstChild("HumanoidRootPart") then
        local d = (pos - currentTarget.HumanoidRootPart.Position).Magnitude
        if d <= C.DetectRadius then
            return currentTarget, d
        end
    end

    local best, bestScore = nil, math.huge
    for _, e in enemies do
        local ok, d = pcall(function()
            return (pos - e.HumanoidRootPart.Position).Magnitude
        end)
        if ok then
            local score = d
            if d <= C.FarmDist then score = score - 20 end
            if score < bestScore then best, bestScore = e, score end
        end
    end

    if best then currentTarget = best end

    local d = math.huge
    if best and best:FindFirstChild("HumanoidRootPart") then
        d = (pos - best.HumanoidRootPart.Position).Magnitude
    end
    return best, d
end

local function nearest()
    local hrp = getHRP()
    if not hrp then return nil, math.huge end
    local best, bestD = nil, math.huge
    for _, e in getAllEnemies() do
        local ok, d = pcall(function()
            return (hrp.Position - e.HumanoidRootPart.Position).Magnitude
        end)
        if ok and d < bestD then best, bestD = e, d end
    end
    return best, bestD
end

-- Should we STOP travelling and fight? Only when an enemy is actually reachable — in kill
-- range, or within detect range WITH clear line of sight. An enemy behind a wall (e.g. the
-- one we're pathfinding toward) must NOT trigger this, or pathing would abort instantly.
local function shouldEngage()
    local hrp = getHRP()
    if not hrp then return false end
    local pos = hrp.Position
    for _, e in getAllEnemies() do
        local ehrp = e:FindFirstChild("HumanoidRootPart")
        if ehrp then
            local d = (pos - ehrp.Position).Magnitude
            if d <= C.FarmDist then return true end
            if d <= C.DetectRadius and clearPath(pos, ehrp.Position) then return true end
        end
    end
    return false
end

-- ============================================================
-- PATH CORE
-- ============================================================
local lastCompute = 0
local function computePath(fromPos, toPos)
    local now = tick()
    if now - lastCompute < C.RepathMin then return nil end
    lastCompute = now
    local path = PFS:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = true })
    local ok = pcall(function() path:ComputeAsync(fromPos, toPos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
    return path
end

local function followPath(path, targetModel, goalPos)
    local waypoints = path:GetWaypoints()
    local blocked = false
    local blockedConn = path.Blocked:Connect(function() blocked = true end)

    local function exit(status)
        blockedConn:Disconnect()
        clearMove("path")
        return status
    end

    for _, wp in ipairs(waypoints) do
        if not running then return exit("stopped") end
        if shouldEngage() then return exit("engage") end

        if targetModel then
            if not targetModel.Parent or not targetModel:FindFirstChild("Humanoid") or targetModel.Humanoid.Health <= 0 then
                return exit("retarget")
            end
            local ehrp = targetModel:FindFirstChild("HumanoidRootPart")
            if ehrp and (ehrp.Position - goalPos).Magnitude > C.TargetEscape then
                return exit("retarget")
            end
        end
        if blocked then return exit("repath") end
        if not isAlive() then return exit("stopped") end
        if wp.Action == Enum.PathWaypointAction.Jump then
            local hum = getHum()
            if hum then hum.Jump = true end
        end

        local t0 = tick()
        while running and isAlive() do
            local hrp = getHRP()
            if not hrp then break end
            if (hrp.Position - wp.Position).Magnitude < C.ArriveRadius then break end
            if tick() - t0 > C.MoveTimeout then break end
            if shouldEngage() then return exit("engage") end
            requestMove("path", wp.Position, 0.25)
            task.wait(0.1)
        end

        local hrp = getHRP()
        if hrp and (hrp.Position - wp.Position).Magnitude > C.ArriveRadius then
            local hum = getHum()
            if hum then hum.Jump = true end
            local t1 = tick()
            while tick() - t1 < C.StuckRetry and running and isAlive() do
                hrp = getHRP()
                if not hrp then break end
                if (hrp.Position - wp.Position).Magnitude < C.ArriveRadius then break end
                requestMove("path", wp.Position, 0.25)
                task.wait(0.1)
            end
            hrp = getHRP()
            if hrp and (hrp.Position - wp.Position).Magnitude > C.ArriveRadius then
                return exit("repath")
            end
        end
    end
    return exit("done")
end

local function pathTo(targetModel, staticGoal)
    local hrp = getHRP()
    if not hrp or not isAlive() then return end
    local goalPos = staticGoal
    if targetModel and targetModel.Parent then
        local ehrp = targetModel:FindFirstChild("HumanoidRootPart")
        if ehrp then goalPos = ehrp.Position + flatVel(ehrp) * C.LeadTime end
    end
    if not goalPos then return end

    local path = computePath(hrp.Position, goalPos)
    if path then
        local status = followPath(path, targetModel, goalPos)
        if status == "repath" and running then
            local hrp2 = getHRP()
            if hrp2 then
                lastCompute = 0
                local p2 = computePath(hrp2.Position, goalPos)
                if p2 then followPath(p2, targetModel, goalPos) end
            end
        end
    else
        requestMove("path", goalPos, 0.4)
        task.wait(0.4)
    end
end

-- ============================================================
-- ROOM NAVIGATION
-- ============================================================
local function getRoomOrder()
    local dun = workspace:FindFirstChild("dungeon")
    if not dun then return {} end
    local rooms = {}
    for _, r in dun:GetChildren() do
        local n = tonumber(r.Name:match("room(%d+)"))
        if n then table.insert(rooms, { room = r, num = n })
        elseif r.Name == "bossRoom" then table.insert(rooms, { room = r, num = 999 })
        end
    end
    table.sort(rooms, function(a, b) return a.num < b.num end)
    return rooms
end

local function nextRoomPos()
    local hrp = getHRP()
    local ordered = getRoomOrder()
    for _, entry in ipairs(ordered) do
        local ef = entry.room:FindFirstChild("enemyFolder")
        if ef then
            local total, count = Vector3.zero, 0
            for _, c in ef:GetChildren() do
                if c:IsA("Model") and c:FindFirstChild("Humanoid") and c.Humanoid.Health > 0 and c:FindFirstChild("HumanoidRootPart") then
                    total = total + c.HumanoidRootPart.Position; count = count + 1
                end
            end
            if count > 0 then return total / count end
        end
    end
    for _, entry in ipairs(ordered) do
        local ef = entry.room:FindFirstChild("enemyFolder")
        if ef then
            local hasSpawns, total, count = false, Vector3.zero, 0
            for _, c in ef:GetChildren() do
                if c:IsA("BasePart") and c.Name == "spawn" then
                    hasSpawns = true; total = total + c.Position; count = count + 1
                end
            end
            if hasSpawns and count > 0 then
                local centroid = total / count
                local dist = hrp and (hrp.Position - centroid).Magnitude or 999
                if dist > 30 then return centroid end
            end
        end
    end
    return nil
end

-- ============================================================
-- SPEED
-- ============================================================
local speedConn = nil
local function hookSpeed()
    if speedConn then speedConn:Disconnect() end
    local hum = getHum()
    if not hum then return end
    hum.WalkSpeed = C.Speed
    speedConn = hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
        if not running then return end
        if hum.WalkSpeed ~= C.Speed then
            hum.WalkSpeed = C.Speed
        end
    end)
end
hookSpeed()

conns.charSpeed = lp().CharacterAdded:Connect(function()
    task.wait(0.5)
    if running then hookSpeed() end
end)

-- ============================================================
-- BODYGYRO AIM-LOCK
-- ============================================================
local gyro = nil
local function updateGyro()
    local hrp = getHRP()
    if not hrp then
        if gyro then pcall(function() gyro:Destroy() end); gyro = nil end
        return
    end
    local enemy = nearest()
    if enemy and enemy:FindFirstChild("HumanoidRootPart") then
        if not gyro or not gyro.Parent then
            gyro = Instance.new("BodyGyro")
            gyro.MaxTorque = Vector3.new(0, 40000, 0)
            gyro.P = 10000
            gyro.D = 500
            gyro.Parent = hrp
        end
        local ePos = enemy.HumanoidRootPart.Position
        local lookDir = (ePos - hrp.Position) * Vector3.new(1, 0, 1)
        if lookDir.Magnitude > 0.1 then
            gyro.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + lookDir)
        end
    else
        if gyro then pcall(function() gyro:Destroy() end); gyro = nil end
    end
end

conns.gyro = RunS.Heartbeat:Connect(function()
    if not running then return end
    updateGyro()
end)

conns.charAdded = lp().CharacterAdded:Connect(function()
    gyro = nil
    intent.owner = "none"
    intent.pos = nil
    currentTarget = nil
    DODGE.active = false
end)

-- ============================================================
-- ANTI-CHEAT SPOOF
-- ============================================================
local uw = remotes:FindFirstChild("underworldBossSpecficEvents")
local pr = remotes:FindFirstChild("pirateBossSpecficEvents")
if uw and pr then
    conns.ac = uw.OnClientEvent:Connect(function(data)
        if typeof(data) ~= "string" then return end
        local hum, hrp = getHum(), getHRP()
        if not hum or not hrp then return end
        pr:FireServer({
            [data] = {
                walkSpeed = 16,
                hipHeight = hum.HipHeight,
                jumpPower = hum.UseJumpPower and hum.JumpPower or hum.JumpHeight,
                platformStand = false,
                rootSizeMagnitude = hrp.Size.Magnitude,
            }
        })
    end)
end

-- ============================================================
-- NO STUN
-- ============================================================
task.spawn(function()
    while running do
        if C.NoStun and isAlive() then
            local char = getChar()
            if char then
                local s = char:FindFirstChild("stunned")
                if s then pcall(function() s:Destroy() end) end
                local hum = getHum()
                if hum then hum.PlatformStand = false end
            end
        end
        task.wait(0.05)
    end
end)

-- ============================================================
-- NOCLIP  (only touches collisions while enabled)
-- ============================================================
local noclipConn = nil
local noclipRestored = true
local function hookNoclip()
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    noclipConn = RunS.Stepped:Connect(function()
        if not running then return end
        if C.Noclip then
            local char = getChar()
            if char then
                for _, p in char:GetDescendants() do
                    if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
                end
            end
            noclipRestored = false
        elseif not noclipRestored then
            -- restore collisions once after toggling off
            local char = getChar()
            if char then
                for _, p in char:GetDescendants() do
                    if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                        p.CanCollide = true
                    end
                end
            end
            noclipRestored = true
        end
    end)
end
hookNoclip()

conns.charNoclip = lp().CharacterAdded:Connect(function()
    task.wait(0.3)
    noclipRestored = true
    if running then hookNoclip() end
end)

-- ============================================================
-- KILL AURA  (independent — never pauses for dodging)
-- ============================================================
task.spawn(function()
    while running do
        if C.KillAura and isAlive() then
            local _, d = nearest()
            if d <= C.FarmDist then
                pcall(function() remotes.weaponUsed:FireServer() end)
            end
        end
        task.wait(0.12 + math.random() * 0.06)
    end
end)

-- ============================================================
-- AUTO ABILITY  (independent — never pauses for dodging)
-- ============================================================
local function findAbilityTool(slot)
    for _, t in lp().Backpack:GetChildren() do
        if t:IsA("Tool") and t:FindFirstChild("abilitySlot") then
            if t.abilitySlot.Value == slot then return t end
        end
    end
    local char = getChar()
    if char then
        for _, t in char:GetChildren() do
            if t:IsA("Tool") and t:FindFirstChild("abilitySlot") then
                if t.abilitySlot.Value == slot then return t end
            end
        end
    end
    return nil
end

local function isAbilityReady(tool)
    if not tool then return false end
    local cd = tool:FindFirstChild("cooldown")
    if cd and cd.Value > 0 then return false end
    local char = getChar()
    if char then
        local busy = char:FindFirstChild("busyCasting")
        if busy and busy.Value == true then return false end
    end
    return true
end

local function castAbility(slot)
    local tool = findAbilityTool(slot)
    if not tool or not isAbilityReady(tool) then return false end
    local le = tool:FindFirstChild("localEvent")
    if le then
        pcall(function() le:Fire() end)
        return true
    end
    local enemy = nearest()
    local targetPos = nil
    if enemy and enemy:FindFirstChild("HumanoidRootPart") then
        targetPos = enemy.HumanoidRootPart.Position
    elseif getHRP() then
        targetPos = getHRP().Position + getHRP().CFrame.LookVector * 20
    end
    pcall(function() remotes.abilityUsed:FireServer(slot, targetPos) end)
    return true
end

task.spawn(function()
    while running do
        if C.AutoAbility and isAlive() then
            local enemy, d = nearest()
            local hrp = getHRP()
            -- Spells are ranged (the server aims them along the character's facing, which the
            -- BodyGyro locks onto the enemy). Cast from far as long as we have line of sight —
            -- no need to walk into the boss. This is the fix for "spells only fire up close".
            local ehrp = enemy and enemy:FindFirstChild("HumanoidRootPart")
            if d <= C.SpellRange and hrp and ehrp and clearPath(hrp.Position, ehrp.Position) then
                castAbility("q")
                task.wait(C.AbilityCD)
                castAbility("e")
            end
        end
        task.wait(0.4 + math.random() * 0.2)
    end
end)

-- ============================================================
-- AUTO START
-- ============================================================
task.spawn(function()
    while running do
        if C.AutoStart then
            pcall(function() remotes.changeStartValue:FireServer() end)
            pcall(function() remotes.readyUp:FireServer() end)
        end
        task.wait(2 + math.random())
    end
end)

-- ============================================================
-- AUTO REPLAY — restart the dungeon when it completes or times out
-- ============================================================
-- The server fires loadCompleteGui (dungeon cleared) or loadFailedGui (out of time / all
-- lives lost) to the client to show the end screen. We listen for either and re-request the
-- dungeon: replayDungeon is the "Replay" button's remote; we also nudge the normal start
-- flow as a fallback in case the run returned to the lobby.
do
    local replayRemote  = remotes:FindFirstChild("replayDungeon")
    local completeEvent = remotes:FindFirstChild("loadCompleteGui")
    local failedEvent   = remotes:FindFirstChild("loadFailedGui")
    local lastReplay = 0

    local function tryReplay(reason)
        if not C.AutoReplay then return end
        if tick() - lastReplay < 8 then return end  -- debounce (both events / spam guard)
        lastReplay = tick()
        DODGE.breadcrumb.action = "REPLAY (" .. reason .. ")"
        task.wait(C.ReplayDelay)                      -- let loot/reward screens resolve
        if not running or not C.AutoReplay then return end
        if replayRemote then pcall(function() replayRemote:FireServer() end) end
        -- fallback: re-ready in case we were sent back to the lobby
        pcall(function() remotes.changeStartValue:FireServer() end)
        pcall(function() remotes.readyUp:FireServer() end)
    end

    if completeEvent then
        conns.replayComplete = completeEvent.OnClientEvent:Connect(function() tryReplay("cleared") end)
    end
    if failedEvent then
        conns.replayFailed = failedEvent.OnClientEvent:Connect(function() tryReplay("timeout") end)
    end
end

-- ============================================================
-- THREAT TRACKER — velocity-estimating projectile awareness
-- ============================================================
local threats = {}      -- [BasePart] = true
local threatData = {}    -- [BasePart] = { lastPos, velocity, telegraph }

-- True if `inst` lives inside any character (a Model with a Humanoid) — player or enemy.
-- Used to exclude armor/body parts, which are never attacks.
local function inCharacter(inst)
    local m = inst:FindFirstAncestorWhichIsA("Model")
    while m do
        if m:FindFirstChildOfClass("Humanoid") then return true end
        m = m:FindFirstAncestorWhichIsA("Model")
    end
    return false
end

-- Names of the player's OWN spell projectiles (ReplicatedStorage.projectiles), so we never
-- dodge our own casts (Fireball's "Soul Drain", etc. spawn into workspace when we cast).
local PLAYER_PROJ = {}
do
    local proj = Rep:FindFirstChild("projectiles")
    if proj then for _, m in proj:GetChildren() do PLAYER_PROJ[m.Name] = true end end
end
local function isPlayerProjectile(inst)
    if PLAYER_PROJ[inst.Name] then return true end
    local m = inst:FindFirstAncestorWhichIsA("Model")
    while m do
        if PLAYER_PROJ[m.Name] then return true end
        m = m:FindFirstAncestorWhichIsA("Model")
    end
    return false
end

-- A part name looks like an attack hazard (damage/telegraph/beam/circle keywords).
local function isHazardName(n)
    local l = n:lower()
    return (l:find("damage") or l:find("hit") or l:find("aoe") or l:find("zone")
        or l:find("area") or l:find("beam") or l:find("precast") or l:find("telegraph")
        or l:find("blast") or l:find("wave") or l:find("shock") or l:find("lava")
        or l:find("flame") or l:find("cyclone") or l:find("circle") or l:find("line")
        or l:find("slam") or l:find("spike") or l:find("orb") or l:find("bomb")
        or l:find("shot") or l:find("proj")) ~= nil
end

-- Names of every attack part in the two template folders (enemyProjectiles = mapSpecificLocals,
-- enemyAssets = EnemyClientEffects). A workspace part with one of these names was cloned from
-- an attack. Generic names (armor/mesh/anchor bits) are excluded so decor can't match.
local GENERIC_PART = {
    Model=true, Folder=true, Part=true, MeshPart=true, Union=true, UnionOperation=true,
    Wedge=true, WedgePart=true, Handle=true, ArmorMesh=true, newPart=true, Mesh=true,
    Bone=true, Head=true, Torso=true, PrimaryPart=true, Accessory=true, glowPart=true,
}
local ATTACK_NAMES = {}
do
    for _, folderName in { "enemyProjectiles", "enemyAssets" } do
        local f = Rep:FindFirstChild(folderName)
        if f then
            for _, d in f:GetDescendants() do
                if d:IsA("BasePart") and not GENERIC_PART[d.Name] then ATTACK_NAMES[d.Name] = true end
            end
        end
    end
end

-- TELEGRAPH ANTICIPATION: when a circle / ground-slam AoE aimed at us appears, start moving
-- laterally IMMEDIATELY (perpendicular to the boss→player line) before it grows/activates.
-- This is Bob's "circle in your direction" attack — reacting to the finished circle is too
-- late, so we pre-empt it with a committed sideways strafe.
local function triggerTelegraphStrafe(part)
    local hrp = getHRP(); if not hrp then return end
    local ok, pos = pcall(function() return part.Position end)
    if not ok then return end
    if flatDist(hrp.Position, pos) > 45 then return end   -- only if aimed near us
    local ref = currentTarget and currentTarget:FindFirstChild("HumanoidRootPart")
    local base = ref and ref.Position or pos
    local toP = Vector3.new(hrp.Position.X - base.X, 0, hrp.Position.Z - base.Z)
    if toP.Magnitude < 0.1 then toP = hrp.CFrame.LookVector * Vector3.new(1, 0, 1) end
    local perp = Vector3.new(-toP.Z, 0, toP.X)
    if perp.Magnitude < 0.1 then return end
    perp = perp.Unit
    if tick() > DODGE.strafeUntil then  -- new telegraph window: commit to one side
        DODGE.strafeDir = (math.random() < 0.5) and perp or -perp
    end
    DODGE.strafeUntil = tick() + 0.7
end

-- Is this newly-added part an actual ATTACK (not ambient decor)? A real attack part is
-- non-collidable, not on a character, not our own spell, AND is one of: cloned from an attack
-- template (ATTACK_NAMES), hazard-named, or Neon (attack visuals). This precise filter is the
-- fix for false threats — the lobby alone has ~50 non-collidable decor parts, and treating
-- every one as a threat floods the list and evicts the real attack under the MaxThreats cap.
local function looksLikeAttack(d)
    if not d:IsA("BasePart") then return false end
    if d.CanCollide then return false end
    local sz = d.Size
    if math.max(sz.X, sz.Y, sz.Z) < 1 then return false end
    if inCharacter(d) or isPlayerProjectile(d) then return false end
    if ATTACK_NAMES[d.Name] or isHazardName(d.Name) then return true end
    local ok, neon = pcall(function() return d.Material == Enum.Material.Neon end)
    return ok and neon
end

conns.ptAdd = workspace.DescendantAdded:Connect(function(d)
    if looksLikeAttack(d) then
        threats[d] = true
        if C.AutoDodge then
            local ln = d.Name:lower()
            if ln:find("circle") or ln:find("groundslam") or ln:find("slam") or ln:find("aoe") or d.Name == "precast" then
                triggerTelegraphStrafe(d)
            end
        end
    end
end)
conns.ptRem = workspace.DescendantRemoving:Connect(function(d)
    threats[d] = nil
    threatData[d] = nil
end)

-- Track each threat's POSITION velocity (for moving projectiles) AND SIZE growth rate (for
-- expanding attacks — e.g. a pulse wave that tweens Size to 280 studs). Both are estimated
-- from per-frame deltas and smoothed, so the dodge can PREDICT where the hitbox will be and
-- how big it will get, and step clear before it arrives.
conns.threatTrack = RunS.Heartbeat:Connect(function(dt)
    if not running or dt <= 0 then return end
    for part in pairs(threats) do
        if not part.Parent then
            threats[part] = nil; threatData[part] = nil; continue
        end
        local pos, sz
        local ok = pcall(function() pos = part.Position; sz = part.Size end)
        if not ok or not pos or not sz then
            threats[part] = nil; threatData[part] = nil; continue
        end
        local data = threatData[part]
        if data then
            local rawVel = (pos - data.lastPos) / dt
            if rawVel.Magnitude > 400 then rawVel = rawVel.Unit * 400 end
            data.velocity = data.velocity:Lerp(rawVel, 0.4)
            data.lastPos = pos
            -- size growth rate (studs/sec per axis); ignore huge one-frame jumps
            local rawGrow = (sz - data.lastSize) / dt
            if rawGrow.Magnitude > 2000 then rawGrow = rawGrow.Unit * 2000 end
            data.growth = data.growth:Lerp(rawGrow, 0.5)
            data.lastSize = sz
        else
            local isNeon = false
            pcall(function() isNeon = part.Material == Enum.Material.Neon end)
            threatData[part] = {
                lastPos = pos,
                velocity = Vector3.zero,
                lastSize = sz,
                growth = Vector3.zero,
                telegraph = (part.Name == "precast"),
                -- hazard = looks like real attack geometry (named or Neon). Static parts that
                -- are neither hazard nor moving/growing are ignored by the dodge (false-threat filter).
                hazard = isHazardName(part.Name) or isNeon,
            }
        end
    end
end)

-- ============================================================
-- DODGE SYSTEM  [v8.1]  — predict, step minimally, never freeze
-- ============================================================

-- Small, rate-limited CFrame hop toward safety. LAST RESORT only (see dodge loop): used
-- when an attack is about to connect and walking can't clear the danger in time. Capped
-- distance + a cooldown keep CFrame writes rare so the server doesn't rubber-band us.
local function microTeleport(targetPos)
    local hrp = getHRP(); if not hrp then return false end
    if tick() - DODGE.lastTp < C.MicroTPCooldown then return false end
    local delta = targetPos - hrp.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    local dmag = flat.Magnitude
    if dmag < 0.5 then return false end
    if dmag > C.MicroTPDist then flat = flat.Unit * C.MicroTPDist end
    hrp.CFrame = hrp.CFrame + flat
    DODGE.lastTp = tick()
    return true
end

-- Main dodge brain — GRID METHOD. Runs every frame (~16ms). Snapshots every active
-- threat, then finds the nearest grid cell that is safe from ALL of them (predicting
-- each threat's trajectory over the lookahead) and walks there. Handles many overlapping
-- attacks at once — the weakness of single-threat perpendicular stepping.
conns.dodge = RunS.Heartbeat:Connect(function()
    if not running then return end
    local bc = DODGE.breadcrumb
    if not C.AutoDodge then
        DODGE.active = false
        bc.action = "dodge off"; bc.threat = "-"; bc.predict = "-"; bc.target = "-"; bc.reason = "-"
        return
    end
    if not isAlive() then return end
    local hrp = getHRP()
    if not hrp then return end
    local pp = hrp.Position

    -- Snapshot active threats as ORIENTED BOXES (real CFrame+Size — a 150-stud beam is not a
    -- 75-radius disc). Moving projectiles get a LONGER lookahead + larger inclusion range so
    -- we react while they're still far but on-course. FALSE-THREAT FILTER: a part only counts
    -- if it's moving, growing, a telegraph, or hazard-named/Neon — static harmless props are
    -- ignored so we never dodge nothing.
    local active = {}
    for part in pairs(threats) do
        if part.Parent then
            local dta = threatData[part]
            if dta then
                local ok, cf = pcall(function() return part.CFrame end)
                if ok then
                    local sz = part.Size
                    -- predict growth: treat a tweening-larger hitbox as its near-future size
                    local g = dta.growth
                    local gx = math.clamp((g.X > 0 and g.X or 0) * C.GrowthLookahead * 0.5, 0, C.MaxGrowth)
                    local gy = math.clamp((g.Y > 0 and g.Y or 0) * C.GrowthLookahead * 0.5, 0, C.MaxGrowth)
                    local gz = math.clamp((g.Z > 0 and g.Z or 0) * C.GrowthLookahead * 0.5, 0, C.MaxGrowth)
                    local hx, hy, hz = sz.X * 0.5 + gx, sz.Y * 0.5 + gy, sz.Z * 0.5 + gz
                    local v = dta.velocity
                    local speed = math.sqrt(v.X * v.X + v.Z * v.Z)
                    local moving = speed > 2
                    local growing = (gx + gy + gz) > 1
                    -- only real hazards trigger dodges
                    if moving or growing or dta.telegraph or dta.hazard then
                        local la = moving and C.ProjLookahead or C.ThreatLookahead
                        local reach = moving and (C.DodgeRange + speed * C.ProjLookahead) or C.DodgeRange
                        local maxHalf = math.max(hx, hy, hz)
                        local edgeDist = flatDist(pp, cf.Position) - maxHalf
                        if edgeDist <= reach then
                            active[#active + 1] = {
                                cf = cf, hx = hx, hy = hy, hz = hz,
                                vx = v.X, vy = v.Y, vz = v.Z,
                                px = cf.Position.X, pz = cf.Position.Z,
                                moving = moving, growing = growing,
                                telegraph = dta.telegraph == true,
                                la = la, samples = moving and 6 or 1,
                                name = part.Name, edge = edgeDist,
                            }
                        end
                    end
                end
            end
        end
    end

    local py = pp.Y
    -- min OBB clearance of point (cx,py,cz) to threat t over t's lookahead, and the sample
    -- time at which it's closest (time-to-impact for that threat).
    local function threatClr(t, cx, cz)
        local minD, mFt = math.huge, 0
        for si = 1, t.samples do
            local ft = (t.samples == 1) and 0 or (t.la * (si - 1) / (t.samples - 1))
            local lp = t.cf:PointToObjectSpace(Vector3.new(cx - t.vx * ft, py - t.vy * ft, cz - t.vz * ft))
            local dx = math.abs(lp.X) - t.hx; if dx < 0 then dx = 0 end
            local dy = math.abs(lp.Y) - t.hy; if dy < 0 then dy = 0 end
            local dz = math.abs(lp.Z) - t.hz; if dz < 0 then dz = 0 end
            local dd = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dd < minD then minD, mFt = dd, ft end
        end
        return minD, mFt
    end

    -- CULL BY ACTUAL DANGER: keep the MaxThreats threats with the smallest predicted clearance
    -- TO THE PLAYER. (Culling by center-distance let big harmless parts evict the real
    -- overlapping threat — the "reads safe while standing in an attack" bug.)
    for _, t in ipairs(active) do t.pClr, t.pFt = threatClr(t, pp.X, pp.Z) end
    if #active > C.MaxThreats then
        table.sort(active, function(a, b) return a.pClr < b.pClr end)
        for i = #active, C.MaxThreats + 1, -1 do active[i] = nil end
    end

    -- boss position (to avoid dodging too far away from our target)
    local bossPos
    if currentTarget and currentTarget.Parent then
        local bh = currentTarget:FindFirstChild("HumanoidRootPart")
        if bh then bossPos = bh.Position end
    end

    -- clearance of an arbitrary grid cell = min over the kept threats
    local function clearanceAt(cx, cz)
        local minD, who = math.huge, nil
        for _, t in ipairs(active) do
            local dd = threatClr(t, cx, cz)
            if dd < minD then minD, who = dd, t end
        end
        return minD, who
    end

    -- player danger from the per-threat clearances already computed
    local myClr, whoT, whoFt = math.huge, nil, 0
    for _, t in ipairs(active) do
        if t.pClr < myClr then myClr, whoT, whoFt = t.pClr, t, t.pFt end
    end

    -- SAFE right now. If a telegraph pre-dodge is committed, keep strafing laterally to leave
    -- the predicted circle BEFORE it activates; otherwise stop and let the main loop resume.
    if #active == 0 or myClr >= C.ThreatBuffer then
        if tick() < DODGE.strafeUntil and DODGE.strafeDir then
            local cand = pp + DODGE.strafeDir * 16
            if not clearPath(pp, cand) then
                DODGE.strafeDir = -DODGE.strafeDir
                cand = pp + DODGE.strafeDir * 16
            end
            if clearPath(pp, cand) then
                DODGE.active = true
                requestMove("dodge", cand, 0.2)
                bc.action = "PRE-DODGE"; bc.threat = "telegraph"; bc.predict = "strafing"
                bc.target = string.format("%.0f, %.0f", cand.X, cand.Z); bc.reason = "anticipating circle"
                return
            end
        end
        if DODGE.active then clearMove("dodge"); DODGE.active = false end
        bc.action = DODGE.baseAction
        bc.threat = (#active > 0) and ("safe (" .. #active .. " near)") or "none"
        bc.predict = "-"; bc.target = "-"; bc.reason = "clear"
        return
    end

    -- In danger: grid-search the nearest reachable SAFE cell. Cost = distance moved + a
    -- penalty for ending up too far from the boss (so we don't create bad long-range spacing).
    -- Track a max-clearance cover cell as fallback for inescapable AoEs.
    DODGE.active = true
    local cellPad = C.ThreatBuffer + C.DodgeMargin
    local N, s = C.GridHalf, C.GridSpacing
    local bestSafe, bestSafeCost, bestSafeD2
    local bestCover, bestCoverClr = nil, myClr
    for gx = -N, N do
        for gz = -N, N do
            if gx ~= 0 or gz ~= 0 then
                local cx, cz = pp.X + gx * s, pp.Z + gz * s
                local clr = clearanceAt(cx, cz)
                if clr >= cellPad then
                    local d2 = (gx * gx + gz * gz) * s * s
                    local cost = d2
                    if bossPos then
                        local bd = flatDist(Vector3.new(cx, py, cz), bossPos)
                        if bd > C.MaxBossDist then cost = cost + (bd - C.MaxBossDist) ^ 2 * 6 end
                    end
                    if not bestSafeCost or cost < bestSafeCost then
                        local cp = Vector3.new(cx, py, cz)
                        if clearPath(pp, cp) then bestSafe, bestSafeCost, bestSafeD2 = cp, cost, d2 end
                    end
                elseif not bestSafe and clr > bestCoverClr then
                    local cp = Vector3.new(cx, py, cz)
                    if clearPath(pp, cp) then bestCover, bestCoverClr = cp, clr end
                end
            end
        end
    end

    local kind = whoT and (whoT.growing and "growing" or (whoT.moving and "incoming" or "AoE")) or "?"
    bc.threat = (whoT and whoT.name or "?") .. (#active > 1 and (" +" .. (#active - 1)) or "")

    local target = bestSafe or bestCover
    if target then
        requestMove("dodge", target, 0.2)  -- PRIMARY: walk (no CFrame write = no rubber-band)
        bc.target = string.format("%.0f, %.0f", target.X, target.Z)
        -- LAST-RESORT micro-TP: only if a hit is about to connect (whoFt tiny) and we cannot
        -- walk to the safe cell in that time. Rate-limited inside microTeleport.
        local tpUsed = false
        if C.MicroTP and bestSafe then
            local walkTime = math.sqrt(bestSafeD2) / math.max(hum.WalkSpeed, 1)
            if whoFt <= C.MicroTPReact and walkTime > whoFt then
                tpUsed = microTeleport(bestSafe)
            end
        end
        if bestSafe then
            bc.action = tpUsed and "DODGE+TP" or "DODGE"
            bc.predict = kind
            bc.reason = string.format("safe cell %.0f studs away", math.sqrt(bestSafeD2))
        else
            bc.action = "COVER"
            bc.predict = "no fully-safe cell"
            bc.reason = string.format("best clearance %.1f studs", bestCoverClr)
        end
    else
        clearMove("dodge")
        bc.action = "HOLD"; bc.predict = "boxed in"; bc.target = "-"; bc.reason = "no reachable safer cell"
    end
end)

-- ============================================================
-- DEBRIS CLEAR (optional, off by default) — small loose props only
-- ============================================================
task.spawn(function()
    while running do
        if C.ClearDebris then
            local hrp = getHRP()
            if hrp then
                local pp = hrp.Position
                for _, d in workspace:GetChildren() do
                    if d:IsA("BasePart") and d.CanCollide then
                        local sz = d.Size
                        if sz.X < 5 and sz.Y < 5 and sz.Z < 5 then
                            if (d.Position - pp).Magnitude < C.DodgeRange then
                                d.CanCollide = false
                                d.Transparency = 1
                            end
                        end
                    end
                end
            end
        end
        task.wait(1)
    end
end)

-- ============================================================
-- MAIN FARM LOOP — stand-and-fight (no post-dodge wait)
-- ============================================================
task.spawn(function()
    while running do
        if not isAlive() then
            waitAlive()
            currentTarget = nil
            DODGE.baseAction = "dead"
            task.wait(1)
        else
            local hum = getHum()
            local hrp = getHRP()
            if not hum or not hrp then task.wait(0.5) continue end

            local enemy, d = selectTarget()

            if enemy and enemy:FindFirstChild("HumanoidRootPart") then
                local ePos = enemy.HumanoidRootPart.Position
                if d <= C.EngageDist then
                    -- engage range: hold at HoldDist and let ranged spells do the work. Do NOT
                    -- walk into the boss — maintain the standoff distance (in or out) so we stay
                    -- out of melee/close-AoE range while still casting.
                    DODGE.baseAction = "fighting"
                    local diff = d - C.HoldDist
                    if math.abs(diff) > 4 then
                        local dir = (hrp.Position - ePos)
                        local flatDir = Vector3.new(dir.X, 0, dir.Z)
                        if flatDir.Magnitude > 0.1 then
                            requestMove("hold", ePos + flatDir.Unit * C.HoldDist, 0.2)
                        end
                    end
                    task.wait(0.15)
                elseif clearPath(hrp.Position, ePos) then
                    -- clear line of sight: approach only until we reach HoldDist (spells already
                    -- firing from SpellRange while we close the gap)
                    DODGE.baseAction = "approaching"
                    local dir = (ePos - hrp.Position)
                    local flatDir = Vector3.new(dir.X, 0, dir.Z)
                    if flatDir.Magnitude > 0.1 then
                        requestMove("path", ePos - flatDir.Unit * C.HoldDist, 0.3)
                    end
                    task.wait(0.15)
                else
                    -- enemy behind cover / around a corner: PathfindingService around walls
                    DODGE.baseAction = "pathing"
                    pathTo(enemy, nil)
                end
            else
                currentTarget = nil
                DODGE.baseAction = "seeking room"
                local target = nextRoomPos()
                if target then pathTo(nil, target) else task.wait(1) end
            end
        end
        task.wait(0.1)
    end
end)

-- ============================================================
-- ANTI-AFK
-- ============================================================
task.spawn(function()
    while running do
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
        task.wait(50 + math.random() * 20)
    end
end)

-- ============================================================
-- DEBUG BREADCRUMBS HUD
-- ============================================================
local dbgGui, dbgLabel
local function buildDebug()
    dbgGui = Instance.new("ScreenGui")
    dbgGui.Name = "ZF_Debug"
    dbgGui.ResetOnSpawn = false
    dbgGui.IgnoreGuiInset = true
    dbgGui.DisplayOrder = 999999
    local ok = pcall(function()
        dbgGui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
    end)
    if not ok then dbgGui.Parent = lp():WaitForChild("PlayerGui") end

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(300, 128)
    frame.Position = UDim2.fromOffset(14, 14)
    frame.BackgroundColor3 = Color3.fromRGB(14, 15, 18)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = dbgGui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = frame
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(60, 130, 90); stroke.Transparency = 0.4; stroke.Parent = frame

    dbgLabel = Instance.new("TextLabel")
    dbgLabel.Size = UDim2.new(1, -16, 1, -12)
    dbgLabel.Position = UDim2.fromOffset(8, 6)
    dbgLabel.BackgroundTransparency = 1
    dbgLabel.Font = Enum.Font.Code
    dbgLabel.TextSize = 13
    dbgLabel.TextXAlignment = Enum.TextXAlignment.Left
    dbgLabel.TextYAlignment = Enum.TextYAlignment.Top
    dbgLabel.TextColor3 = Color3.fromRGB(125, 232, 150)
    dbgLabel.RichText = true
    dbgLabel.Text = ""
    dbgLabel.Parent = frame
end
pcall(buildDebug)

local dbgAccum = 0
conns.dbg = RunS.Heartbeat:Connect(function(dt)
    if not running or not dbgGui then return end
    dbgGui.Enabled = C.Debug
    if not C.Debug then return end
    dbgAccum = dbgAccum + dt
    if dbgAccum < 0.1 then return end
    dbgAccum = 0
    local b = DODGE.breadcrumb
    dbgLabel.Text = string.format(
        "<b>ZF8.1 DODGE HUD</b>\nAction : <font color=\"#FFD166\">%s</font>\nThreat : %s\nPredict: %s\nTarget : %s\nReason : %s",
        b.action, b.threat, b.predict, b.target, b.reason
    )
end)

-- ============================================================
print("[ZF8] ZeroFarm v9.4 Active — predictive dodge, cull-by-danger, telegraph strafe, micro-TP")

_G.StopZF = function()
    running = false
    for _, c in pairs(conns) do
        if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
    end
    if speedConn then speedConn:Disconnect() end
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    local char = getChar()
    if char then
        for _, p in char:GetDescendants() do
            if p:IsA("BasePart") then p.CanCollide = true end
        end
    end
    if gyro then pcall(function() gyro:Destroy() end) end
    if dbgGui then pcall(function() dbgGui:Destroy() end) end
    local hum = getHum()
    if hum then hum.WalkSpeed = 16 end
    if app then pcall(function() app:Destroy() end) end
    currentTarget = nil
    threats = {}
    threatData = {}
    print("[ZF8] Stopped")
end
