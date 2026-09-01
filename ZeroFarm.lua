--[[
    DQR ZeroFarm v8 — Cascade UI Edition
    Security audit PoC autofarm for Dungeon Quest Reborn

    v8 changes:
      • Trajectory-predicting projectile dodge with micro-teleport + MoveTo hybrid
      • Stand-and-fight combat: hold position, let aggroed mobs approach
      • Smarter target selection (room-aware, distance-weighted, sticky)
      • Smoother pathfinding with less jitter
      • Fixed WalkSpeed Stepper (proper Min/Max/Increment)
      • Expanded threat detection (PrecastHitbox zones, velocity tracking)

    Execute in your executor directly.
    _G.StopZF() to stop | Right Ctrl to minimize
]]

-- ============================================================
-- CONFIG
-- ============================================================
local C = {
    Speed        = 20,
    FarmDist     = 26,
    OrbitDist    = 20,
    KillAura     = true,
    AutoAbility  = true,
    AutoDodge    = true,
    DodgeRange   = 45,
    AutoStart    = true,
    NoStun       = true,
    Noclip       = false,
    AbilityCD    = 0.15,
    RepathMin    = 0.35,
    MoveTimeout  = 1.5,
    ArriveRadius = 5,
    StuckRetry   = 0.6,
    TargetEscape = 14,
    LeadTime     = 0.35,
    -- v8 additions
    DetectRadius   = 60,   -- radius to consider enemies "nearby" before seeking new targets
    HoldDist       = 12,   -- preferred standoff distance from aggroed enemy
    DodgeSamples   = 12,   -- number of angular samples for safe-position grid
    DodgeRadiusMin = 5,    -- inner ring distance for dodge candidates
    DodgeRadiusMax = 10,   -- outer ring distance for dodge candidates (keep small to avoid kicks)
    ThreatLookahead = 0.6, -- seconds to project threat trajectories forward
    ThreatBuffer   = 4,    -- extra studs around threat hitbox to consider dangerous
    SafeReturnTime = 0.3,  -- seconds after last dodge before resuming normal behavior
    MaxTpDist      = 10,   -- max CFrame teleport distance per dodge (studs, keep <=10 to avoid kicks)
    TpCooldown     = 0.15, -- minimum seconds between teleport dodges
    UrgentDist     = 18,   -- threat closer than this + moving toward player = instant CFrame snap
    WalkDodgeDist  = 35,   -- threat at this range = use MoveTo instead of teleport
    ReturnDrift    = 0.4,  -- how fast to drift back to anchor after dodging (0-1 lerp factor per tick)
    AnchorMaxAge   = 2.5,  -- discard anchor if dodge sequence lasted longer than this (seconds)
    PostTpRecheck  = true, -- re-validate position after every micro-teleport; re-dodge if still unsafe
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
    Subtitle = "DQR Autofarm v8",
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
    toggle(form, "Auto Dodge", "Trajectory-predicting projectile avoidance.", "AutoDodge")
    toggle(form, "No Stun", "Remove stunned tag and PlatformStand.", "NoStun")
    toggle(form, "Noclip", "Walk through walls and objects.", "Noclip")
    toggle(form, "Auto Start", "Auto ready-up and start dungeons.", "AutoStart")

    -- [v8 FIX] WalkSpeed Stepper: explicit Min/Max/Increment so it accepts real values
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
                -- actively apply the new speed immediately
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
        row:Left():TitleStack({ Title = "Hold Distance", Subtitle = "Preferred standoff distance from aggroed enemy (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.HoldDist,
            Min = 3,
            Max = 30,
            Increment = 1,
            ValueChanged = function(_, v) C.HoldDist = math.clamp(v, 3, 30) end,
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
        local row = form:Row({ SearchIndex = "Lead Time" })
        row:Left():TitleStack({ Title = "Lead Time", Subtitle = "Aim ahead of moving enemies (seconds)." })
        row:Right():Slider({
            Value = C.LeadTime,
            ValueChanged = function(_, v) C.LeadTime = v end,
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

-- ============================================================
-- MOVEMENT ARBITER
-- ============================================================
local MOVE_PRIORITY = { dodge = 4, hold = 3, orbit = 2, path = 1 }
local intent = { owner = "none", pos = nil, untilT = 0 }
local lastMoveSent = 0

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

conns.move = RunS.Heartbeat:Connect(function()
    if not running then return end
    local hum = getHum()
    if not hum or not intent.pos then return end
    if tick() > intent.untilT then
        intent.owner = "none"
        intent.pos = nil
        return
    end
    if tick() - lastMoveSent >= 0.12 then
        hum:MoveTo(intent.pos)
        lastMoveSent = tick()
    end
end)

-- ============================================================
-- ENEMIES
-- ============================================================
local function getAllEnemies()
    local out = {}
    -- workspace.enemies folder
    local ef = workspace:FindFirstChild("enemies")
    if ef then
        for _, v in ef:GetChildren() do
            if v:IsA("Model") and v:FindFirstChild("Humanoid") and v.Humanoid.Health > 0 and v:FindFirstChild("HumanoidRootPart") then
                table.insert(out, v)
            end
        end
    end
    -- workspace.dungeon room folders
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
    -- [v8] mobs cloned directly into workspace
    for _, v in workspace:GetChildren() do
        if v:IsA("Model") and v:FindFirstChild("Humanoid") and v:FindFirstChild("HumanoidRootPart") then
            if v.Humanoid.Health > 0 and v ~= getChar() then
                -- check it's an enemy (has enemy nameplate or is tagged)
                if v:FindFirstChild("enemyNameplate") or v:FindFirstChild("enemyTag") or v:FindFirstChild("enemyLevel") then
                    -- avoid duplicates from enemies folder
                    local dominated = false
                    for _, existing in out do
                        if existing == v then dominated = true; break end
                    end
                    if not dominated then
                        table.insert(out, v)
                    end
                end
            end
        end
    end
    return out
end

-- [v8] Room number for an enemy (for room-aware targeting)
local function getEnemyRoom(enemy)
    local parent = enemy.Parent
    if not parent then return 0 end
    -- if in enemyFolder inside a room
    if parent.Name == "enemyFolder" then
        local room = parent.Parent
        if room then
            local n = tonumber(room.Name:match("room(%d+)"))
            if n then return n end
            if room.Name == "bossRoom" then return 999 end
        end
    end
    -- workspace.enemies or workspace direct — room 0
    return 0
end

-- [v8] Sticky target tracking
local currentTarget = nil
local targetLockedAt = 0

-- [v8] Smart target selection: prefers closest within same/nearest room, sticky
local function selectTarget()
    local hrp = getHRP()
    if not hrp then return nil, math.huge end
    local pos = hrp.Position
    local enemies = getAllEnemies()
    if #enemies == 0 then
        currentTarget = nil
        return nil, math.huge
    end

    -- if current target is still valid and within detect radius, keep it
    if currentTarget and currentTarget.Parent and currentTarget:FindFirstChild("Humanoid")
        and currentTarget.Humanoid.Health > 0 and currentTarget:FindFirstChild("HumanoidRootPart") then
        local d = (pos - currentTarget.HumanoidRootPart.Position).Magnitude
        if d <= C.DetectRadius then
            return currentTarget, d
        end
    end

    -- score enemies: lower = better
    local best, bestScore = nil, math.huge
    for _, e in enemies do
        local ok, d = pcall(function()
            return (pos - e.HumanoidRootPart.Position).Magnitude
        end)
        if ok then
            local roomNum = getEnemyRoom(e)
            -- score: distance + small room penalty to prefer current/nearest room
            local score = d + roomNum * 0.5
            -- bonus: enemies already close get priority
            if d <= C.FarmDist then
                score = score - 20
            end
            if score < bestScore then
                best, bestScore = e, score
            end
        end
    end

    if best then
        currentTarget = best
        targetLockedAt = tick()
    end

    local d = math.huge
    if best and best:FindFirstChild("HumanoidRootPart") then
        d = (pos - best.HumanoidRootPart.Position).Magnitude
    end
    return best, d
end

-- [v8] Find nearest enemy (for kill aura / quick checks)
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

-- [v8] Check if any enemies exist within detect radius
local function hasNearbyEnemies()
    local hrp = getHRP()
    if not hrp then return false end
    local pos = hrp.Position
    for _, e in getAllEnemies() do
        local ok, d = pcall(function()
            return (pos - e.HumanoidRootPart.Position).Magnitude
        end)
        if ok and d <= C.DetectRadius then return true end
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

        -- [v8] if enemies appeared near us while pathing, stop and fight
        if hasNearbyEnemies() then
            return exit("engage")
        end

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
            -- [v8] interrupt path if enemies appeared nearby
            if hasNearbyEnemies() then return exit("engage") end
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
-- SPEED  [v8 FIXED]
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

-- [v8] Heartbeat speed enforcer — catches cases where the game resets WalkSpeed
-- between PropertyChanged fires, and ensures C.Speed changes propagate immediately
conns.speedEnforce = RunS.Heartbeat:Connect(function()
    if not running then return end
    local hum = getHum()
    if hum and hum.WalkSpeed ~= C.Speed then
        hum.WalkSpeed = C.Speed
    end
end)

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
    dodgeAnchor = nil
    consecutiveDodges = 0
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
-- NOCLIP
-- ============================================================
local noclipConn = nil
local function hookNoclip()
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    noclipConn = RunS.Stepped:Connect(function()
        if not running then return end
        if not C.Noclip then
            -- restore collisions once when toggled off
            local char = getChar()
            if char then
                for _, p in char:GetDescendants() do
                    if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                        p.CanCollide = true
                    end
                end
            end
            return
        end
        local char = getChar()
        if char then
            for _, p in char:GetDescendants() do
                if p:IsA("BasePart") then
                    p.CanCollide = false
                end
            end
        end
    end)
end
hookNoclip()

conns.charNoclip = lp().CharacterAdded:Connect(function()
    task.wait(0.3)
    if running then hookNoclip() end
end)

-- ============================================================
-- KILL AURA
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
-- AUTO ABILITY
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
            local _, d = nearest()
            if d <= C.FarmDist + 15 then
                castAbility("q")
                task.wait(C.AbilityCD)
                castAbility("e")
            end
        end
        task.wait(0.5 + math.random() * 0.3)
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
-- [v8] THREAT TRACKER — velocity-tracking projectile awareness
-- ============================================================
-- Expanded danger part names (from game script analysis)
local DANGER = {
    hitbox=1, hitBox=1, damagepart=1, damagePart=1, trappart=1, trapPart=1,
    lavaline=1, lavaLine=1, groundflame=1, groundFlame=1,
    flamecyclone=1, flameCyclone=1, iceradius=1, iceRadius=1,
    memorydamagezone=1, memoryDamageZone=1,
    charmark=1, charMark=1, cubepylon=1, cubePylon=1,
    electrictower=1, electricTower=1, freezeplayerpart=1, freezePlayerPart=1,
    precast=1, flamelash=1, flameLash=1, sweepingflame=1, sweepingFlame=1,
    longline=1, longLine=1, spreadline=1, spreadLine=1,
    lineshot=1, lineShot=1, circlehit=1, circleHit=1,
    shurikenhit=1, shurikenHit=1, hammerbothit=1, hammerBotHit=1,
    flamingshuriken=1, flamingShuriken=1,
    -- additional from game analysis
    damageArea=1, wave=1, sword=1,
}

-- Is this part a PrecastHitbox zone? (Neon, Anchored, non-collidable, in workspace)
local function isPrecastZone(part)
    if not part:IsA("BasePart") then return false end
    if part.Material ~= Enum.Material.Neon then return false end
    if not part.Anchored then return false end
    if part.CanCollide then return false end
    if part.Parent ~= workspace then return false end
    -- PrecastHitbox parts have no Name set (default "Part") or are Shape-based
    return true
end

local threats = {}          -- [BasePart] = true
local threatData = {}       -- [BasePart] = { lastPos: Vector3, velocity: Vector3, radius: number }
local lastDodgeTime = 0     -- timestamp of last dodge action

-- Track new danger parts
conns.ptAdd = workspace.DescendantAdded:Connect(function(d)
    if not d:IsA("BasePart") then return end
    if DANGER[d.Name] or isPrecastZone(d) then
        threats[d] = true
    end
end)

conns.ptRem = workspace.DescendantRemoving:Connect(function(d)
    threats[d] = nil
    threatData[d] = nil
end)

-- Scan existing workspace for precast zones on init
task.spawn(function()
    for _, d in workspace:GetDescendants() do
        if d:IsA("BasePart") and (DANGER[d.Name] or isPrecastZone(d)) then
            threats[d] = true
        end
    end
end)

-- Velocity tracker: runs every heartbeat, updates estimated velocity for each threat
conns.threatTrack = RunS.Heartbeat:Connect(function(dt)
    if not running then return end
    if dt <= 0 then return end

    for part in pairs(threats) do
        if not part.Parent then
            threats[part] = nil
            threatData[part] = nil
            continue
        end

        local ok, pos = pcall(function() return part.Position end)
        if not ok then
            threats[part] = nil
            threatData[part] = nil
            continue
        end

        local data = threatData[part]
        if data then
            -- estimate velocity from position delta (works for CFrame-animated projectiles)
            local rawVel = (pos - data.lastPos) / dt
            -- smooth velocity with exponential moving average to reduce jitter
            data.velocity = data.velocity:Lerp(rawVel, 0.4)
            data.lastPos = pos
        else
            -- first frame: no velocity yet
            local sz = part.Size
            local radius = math.max(sz.X, sz.Y, sz.Z) * 0.5
            threatData[part] = {
                lastPos = pos,
                velocity = Vector3.zero,
                radius = radius,
            }
        end
    end
end)

-- ============================================================
-- [v8] SAFE-POSITION DODGE SYSTEM
-- ============================================================
-- Given a set of active threats and player position, find the nearest safe position.
-- Uses grid sampling: check candidate positions in a ring around the player.

local function isPositionSafe(candidatePos, playerY, activeThreatList, lookahead)
    for _, t in activeThreatList do
        local pos = t.pos
        local vel = t.vel
        local dangerRadius = t.radius + C.ThreatBuffer

        -- check current overlap
        local flatD = flatDist(candidatePos, pos)
        if flatD < dangerRadius then
            return false
        end

        -- check predicted positions over lookahead window (sample 5 timesteps for tighter coverage)
        local velMag = vel.Magnitude
        if velMag > 1 then
            for step = 1, 5 do
                local futureT = lookahead * (step / 5)
                local futurePos = pos + vel * futureT
                local futureD = flatDist(candidatePos, futurePos)
                if futureD < dangerRadius then
                    return false
                end
            end

            -- check closest approach along the velocity line
            local toCandidate = Vector3.new(candidatePos.X - pos.X, 0, candidatePos.Z - pos.Z)
            local velFlat = Vector3.new(vel.X, 0, vel.Z)
            local velFlatMag = velFlat.Magnitude
            if velFlatMag > 1 then
                local velDir = velFlat / velFlatMag
                local proj = toCandidate:Dot(velDir)
                if proj > 0 and proj < velFlatMag * lookahead then
                    local closestPoint = Vector3.new(pos.X, 0, pos.Z) + velDir * proj
                    local perpDist = flatDist(candidatePos, closestPoint)
                    if perpDist < dangerRadius then
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function findSafePosition(overrideThreatList)
    local hrp = getHRP()
    if not hrp then return nil end
    local playerPos = hrp.Position
    local playerY = playerPos.Y

    -- use pre-built list if provided (from dodge loop), otherwise collect
    local activeThreatList = overrideThreatList
    if not activeThreatList then
        activeThreatList = {}
        for part in pairs(threats) do
            if not part.Parent then continue end
            local data = threatData[part]
            if not data then continue end
            local d = flatDist(playerPos, data.lastPos)
            if d <= C.DodgeRange then
                table.insert(activeThreatList, {
                    pos = data.lastPos,
                    vel = data.velocity,
                    radius = data.radius,
                })
            end
        end
    end

    if #activeThreatList == 0 then return nil end

    -- sample candidate positions in rings around the player
    local bestPos = nil
    local bestDist = math.huge
    local angleStep = (math.pi * 2) / C.DodgeSamples

    for ring = 1, 2 do
        local radius = (ring == 1) and C.DodgeRadiusMin or C.DodgeRadiusMax
        for i = 0, C.DodgeSamples - 1 do
            local angle = angleStep * i
            local candidate = Vector3.new(
                playerPos.X + math.cos(angle) * radius,
                playerY,
                playerPos.Z + math.sin(angle) * radius
            )

            if isPositionSafe(candidate, playerY, activeThreatList, C.ThreatLookahead) then
                local d = flatDist(playerPos, candidate)
                if d < bestDist then
                    bestDist = d
                    bestPos = candidate
                end
            end
        end
        -- if we found something in inner ring, prefer it
        if bestPos then break end
    end

    -- fallback: if no completely safe position, pick the one with fewest/farthest threats
    if not bestPos then
        local leastBadPos = nil
        local leastBadScore = -math.huge

        for ring = 1, 2 do
            local radius = (ring == 1) and C.DodgeRadiusMin or C.DodgeRadiusMax
            for i = 0, C.DodgeSamples - 1 do
                local angle = angleStep * i
                local candidate = Vector3.new(
                    playerPos.X + math.cos(angle) * radius,
                    playerY,
                    playerPos.Z + math.sin(angle) * radius
                )

                -- score: sum of distances from all threats (higher = safer)
                local score = 0
                for _, t in activeThreatList do
                    score = score + flatDist(candidate, t.pos)
                    -- bonus for being perpendicular to velocity
                    local velMag = t.vel.Magnitude
                    if velMag > 1 then
                        local toCandidate = Vector3.new(candidate.X - t.pos.X, 0, candidate.Z - t.pos.Z)
                        local velDir = t.vel.Unit
                        local dot = math.abs(toCandidate.Unit:Dot(velDir))
                        score = score + (1 - dot) * 10 -- perpendicular = bonus
                    end
                end
                -- penalize distance from player
                score = score - flatDist(playerPos, candidate) * 0.5

                if score > leastBadScore then
                    leastBadScore = score
                    leastBadPos = candidate
                end
            end
        end

        bestPos = leastBadPos
    end

    return bestPos
end

-- [v8] Micro-teleport helper: CFrame snap capped to MaxTpDist
local lastTpTime = 0

local function microTeleport(targetPos)
    local hrp = getHRP()
    if not hrp then return false end
    local now = tick()
    if now - lastTpTime < C.TpCooldown then return false end

    local current = hrp.Position
    local delta = targetPos - current
    local flatDelta = Vector3.new(delta.X, 0, delta.Z)
    local dist = flatDelta.Magnitude

    if dist < 0.5 then return false end -- too small to bother

    -- clamp distance to MaxTpDist to avoid anti-cheat kicks
    if dist > C.MaxTpDist then
        flatDelta = flatDelta.Unit * C.MaxTpDist
    end

    local newPos = Vector3.new(current.X + flatDelta.X, current.Y, current.Z + flatDelta.Z)
    hrp.CFrame = CFrame.new(newPos) * (hrp.CFrame - hrp.CFrame.Position) -- preserve rotation
    lastTpTime = now
    return true
end

-- Threat urgency assessment: is any threat about to hit the player imminently?
local function assessUrgency(playerPos, activeThreatList)
    local maxUrgency = 0 -- 0 = safe, 1 = approaching, 2 = imminent

    for _, t in activeThreatList do
        local dist = flatDist(playerPos, t.pos)
        local vel = t.vel
        local velMag = vel.Magnitude

        -- check if threat is moving toward the player
        local movingToward = false
        if velMag > 2 then
            local toPlayer = Vector3.new(playerPos.X - t.pos.X, 0, playerPos.Z - t.pos.Z)
            if toPlayer.Magnitude > 0.1 then
                local dot = toPlayer.Unit:Dot(Vector3.new(vel.X, 0, vel.Z).Unit)
                movingToward = dot > 0.3
            end
        end

        if dist < C.UrgentDist and movingToward then
            -- imminent: projectile is close AND heading our way
            maxUrgency = 2
            break
        elseif dist < C.UrgentDist then
            -- close but not moving toward us — still somewhat urgent (could be AoE)
            maxUrgency = math.max(maxUrgency, 2)
        elseif dist < C.WalkDodgeDist and movingToward then
            maxUrgency = math.max(maxUrgency, 1)
        end
    end

    return maxUrgency
end

-- [v8] Dodge anchor: remember where we were before dodging so we can drift back
local dodgeAnchor = nil   -- Vector3 or nil
local anchorSetAt = 0     -- tick() when anchor was stored
local consecutiveDodges = 0

-- Helper: collect active threat snapshot for current player position
local function collectThreats(playerPos)
    local list = {}
    for part in pairs(threats) do
        if not part.Parent then continue end
        local data = threatData[part]
        if not data then continue end
        local d = flatDist(playerPos, data.lastPos)
        if d <= C.DodgeRange then
            table.insert(list, {
                pos = data.lastPos,
                vel = data.velocity,
                radius = data.radius,
            })
        end
    end
    return list
end

-- [v8] Dodge loop: hybrid CFrame snap / MoveTo with post-TP recheck + anchor return
task.spawn(function()
    while running do
        if C.AutoDodge and isAlive() then
            local hrp = getHRP()
            if hrp then
                local playerPos = hrp.Position
                local activeThreatList = collectThreats(playerPos)

                if #activeThreatList > 0 then
                    local currentSafe = isPositionSafe(playerPos, playerPos.Y, activeThreatList, C.ThreatLookahead)

                    if not currentSafe then
                        -- store anchor before first dodge in a sequence
                        if not dodgeAnchor or (tick() - anchorSetAt > C.AnchorMaxAge) then
                            dodgeAnchor = playerPos
                            anchorSetAt = tick()
                        end

                        local safePos = findSafePosition(activeThreatList)
                        if safePos then
                            local urgency = assessUrgency(playerPos, activeThreatList)

                            if urgency >= 2 then
                                -- IMMINENT: instant CFrame snap (micro-teleport)
                                local tpOk = microTeleport(safePos)
                                lastDodgeTime = tick()
                                consecutiveDodges = consecutiveDodges + 1

                                -- POST-TP RECHECK: did we land on another projectile?
                                if tpOk and C.PostTpRecheck then
                                    local newHrp = getHRP()
                                    if newHrp then
                                        local newPos = newHrp.Position
                                        local recheckThreats = collectThreats(newPos)
                                        if #recheckThreats > 0 and not isPositionSafe(newPos, newPos.Y, recheckThreats, C.ThreatLookahead) then
                                            -- still unsafe — find a DIFFERENT safe position from the new location
                                            local escapeSafe = findSafePosition(recheckThreats)
                                            if escapeSafe then
                                                microTeleport(escapeSafe)
                                                lastDodgeTime = tick()
                                            end
                                        end
                                    end
                                end
                            else
                                -- APPROACHING: use MoveTo (smoother, less suspicious)
                                requestMove("dodge", safePos, 0.3)
                                lastDodgeTime = tick()
                                consecutiveDodges = consecutiveDodges + 1
                            end
                        end
                    else
                        -- position is safe right now
                        clearMove("dodge")

                        -- RETURN TO ANCHOR: drift back to pre-dodge position if we have one
                        if dodgeAnchor and consecutiveDodges > 0 then
                            local anchorDist = flatDist(playerPos, dodgeAnchor)
                            if anchorDist > 2 and anchorDist <= C.MaxTpDist * 2 then
                                -- lerp toward anchor gently
                                local lerpedPos = playerPos:Lerp(dodgeAnchor, C.ReturnDrift)
                                -- only return if the anchor itself is still safe
                                local anchorThreats = collectThreats(lerpedPos)
                                local anchorSafe = #anchorThreats == 0 or isPositionSafe(lerpedPos, playerPos.Y, anchorThreats, C.ThreatLookahead)
                                if anchorSafe then
                                    requestMove("hold", lerpedPos, 0.2)
                                end
                            end
                            -- clear anchor after returning close enough or if it's stale
                            if anchorDist <= 2 or (tick() - anchorSetAt > C.AnchorMaxAge) then
                                dodgeAnchor = nil
                                consecutiveDodges = 0
                            end
                        else
                            dodgeAnchor = nil
                            consecutiveDodges = 0
                        end
                    end
                else
                    clearMove("dodge")
                    -- no threats at all — clear anchor
                    if dodgeAnchor then
                        local anchorDist = flatDist(playerPos, dodgeAnchor)
                        if anchorDist > 2 and consecutiveDodges > 0 then
                            requestMove("hold", dodgeAnchor, 0.2)
                        end
                        dodgeAnchor = nil
                        consecutiveDodges = 0
                    end
                end
            end
        end
        task.wait(0.06) -- ~16Hz for split-second reactions
    end
end)

-- ============================================================
-- [v8] MAIN FARM LOOP — stand-and-fight with smart targeting
-- ============================================================
task.spawn(function()
    while running do
        if not isAlive() then
            waitAlive()
            currentTarget = nil
            task.wait(1)
        else
            local hum = getHum()
            local hrp = getHRP()
            if not hum or not hrp then task.wait(0.5) continue end

            -- recently dodged? wait a beat before repositioning
            if tick() - lastDodgeTime < C.SafeReturnTime then
                task.wait(0.1)
                continue
            end

            local enemy, d = selectTarget()

            if enemy and enemy:FindFirstChild("HumanoidRootPart") then
                local ePos = enemy.HumanoidRootPart.Position

                if d <= C.FarmDist then
                    -- COMBAT RANGE: stand and fight
                    -- hold position — only adjust if too close or too far from hold distance
                    local diff = d - C.HoldDist
                    if math.abs(diff) > 4 then
                        -- nudge toward/away from enemy to maintain hold distance
                        local dir = (hrp.Position - ePos)
                        local flatDir = Vector3.new(dir.X, 0, dir.Z)
                        if flatDir.Magnitude > 0.1 then
                            local holdPos = ePos + flatDir.Unit * C.HoldDist
                            requestMove("hold", holdPos, 0.2)
                        end
                    end
                    -- else: stay put, let kill aura + abilities do the work
                    task.wait(0.2)

                elseif d <= C.DetectRadius then
                    -- DETECTION RANGE: enemy is aggroed and approaching, hold position
                    -- only move if enemy is too far to engage but within detection
                    -- let the enemy come to us, but nudge slightly closer if it's taking too long
                    if d > C.FarmDist + 10 then
                        -- gentle approach: move to a point that's HoldDist from enemy
                        local dir = (ePos - hrp.Position)
                        local flatDir = Vector3.new(dir.X, 0, dir.Z)
                        if flatDir.Magnitude > 0.1 then
                            local approachPos = ePos - flatDir.Unit * C.HoldDist
                            requestMove("path", approachPos, 0.3)
                        end
                    end
                    task.wait(0.25)

                else
                    -- FAR AWAY: pathfind to next enemy cluster
                    pathTo(enemy, nil)
                end
            else
                -- no enemies — find next room
                currentTarget = nil
                local target = nextRoomPos()
                if target then
                    pathTo(nil, target)
                else
                    task.wait(1)
                end
            end
        end
        task.wait(0.15)
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
print("[ZF8] ZeroFarm v8 Active — Cascade UI")

_G.StopZF = function()
    running = false
    for _, c in pairs(conns) do
        if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
    end
    if speedConn then speedConn:Disconnect() end
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
    -- restore collision on stop
    local char = getChar()
    if char then
        for _, p in char:GetDescendants() do
            if p:IsA("BasePart") then p.CanCollide = true end
        end
    end
    if gyro then pcall(function() gyro:Destroy() end) end
    local hum = getHum()
    if hum then hum.WalkSpeed = 16 end
    if app then pcall(function() app:Destroy() end) end
    currentTarget = nil
    threats = {}
    threatData = {}
    print("[ZF8] Stopped")
end
