--[[
    DQR ZeroFarm v7 — Cascade UI Edition
    Security audit PoC autofarm for Dungeon Quest Reborn

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
    Barriers     = true,
    NoStun       = true,
    NerfEnemies  = true,
    RetreatPct   = 0.4,
    AbilityCD    = 0.15,
    RepathMin    = 0.35,
    MoveTimeout  = 1.5,
    ArriveRadius = 5,
    StuckRetry   = 0.6,
    TargetEscape = 14,
    LeadTime     = 0.35,
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

local player = Players.LocalPlayer
local remotes = Rep:WaitForChild("remotes")
local running = true
local conns = {}

-- ============================================================
-- CASCADE UI
-- ============================================================
local cascade = loadstring(game:HttpGetAsync(
    "https://github.com/cascadeui/Cascade/releases/latest/download/dist.luau"
), "dist.luau")()

local minimizeKey = Enum.KeyCode.RightControl

local app = cascade.New({
    WindowPill = true,
    Theme = cascade.Themes.Dark,
    Accent = cascade.Accents.Blue,
})

local window = app:Window({
    Title = "ZeroFarm",
    Subtitle = "DQR Autofarm v7",
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
    toggle(form, "Auto Dodge", "Sidestep left/right away from projectile hitboxes.", "AutoDodge")
    toggle(form, "Nerf Enemies", "Set moveSpeed=0, attackSpeed=999 on enemies (client-side).", "NerfEnemies")
    toggle(form, "No Stun", "Remove stunned tag and PlatformStand.", "NoStun")
    toggle(form, "Auto Start", "Auto ready-up and start dungeons.", "AutoStart")
    toggle(form, "Barrier Bypass", "Remove room barrier collision.", "Barriers")

    do
        local row = form:Row({ SearchIndex = "WalkSpeed" })
        row:Left():TitleStack({ Title = "WalkSpeed", Subtitle = "16 = default, 20-25 safe, higher risks detection." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.Speed,
            ValueChanged = function(_, v) C.Speed = math.clamp(v, 0, 50) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Retreat HP" })
        row:Left():TitleStack({ Title = "Retreat HP %", Subtitle = "Flee from enemies when health drops below this." })
        row:Right():Slider({
            Value = C.RetreatPct,
            ValueChanged = function(_, v) C.RetreatPct = v end,
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
            ValueChanged = function(_, v) C.FarmDist = math.clamp(v, 5, 80) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Orbit Distance" })
        row:Left():TitleStack({ Title = "Orbit Distance", Subtitle = "Circle-strafe radius around enemies (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.OrbitDist,
            ValueChanged = function(_, v) C.OrbitDist = math.clamp(v, 5, 60) end,
        })
    end

    do
        local row = form:Row({ SearchIndex = "Dodge Range" })
        row:Left():TitleStack({ Title = "Dodge Range", Subtitle = "Threat detection radius for projectile dodge (studs)." })
        row:Right():Stepper({
            Fielded = true,
            Value = C.DodgeRange,
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

-- ============================================================
-- HELPERS
-- ============================================================
local function getChar() return player.Character end
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

-- ============================================================
-- MOVEMENT ARBITER
-- ============================================================
local MOVE_PRIORITY = { dodge = 4, retreat = 3, orbit = 2, path = 1 }
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
    return out
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

-- ============================================================
-- ORBIT
-- ============================================================
local orbitAngle = 0
local function getOrbitPos(enemyPos)
    orbitAngle = orbitAngle + 0.35
    if orbitAngle > math.pi * 2 then orbitAngle = 0 end
    return enemyPos + Vector3.new(
        math.cos(orbitAngle) * C.OrbitDist,
        0,
        math.sin(orbitAngle) * C.OrbitDist
    )
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

        local _, d = nearest()
        if d <= C.FarmDist then return exit("arrived") end
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
-- BARRIERS
-- ============================================================
local function clearBarriers()
    local dun = workspace:FindFirstChild("dungeon")
    if not dun then return end
    for _, room in dun:GetChildren() do
        local b = room:FindFirstChild("barrier")
        if b then
            for _, p in b:GetDescendants() do
                if p:IsA("BasePart") then p.CanCollide = false; p.Transparency = 1 end
            end
        end
    end
end

task.spawn(function()
    while running do
        if C.Barriers then clearBarriers() end
        task.wait(2)
    end
end)

-- ============================================================
-- SPEED
-- ============================================================
conns.speed = RunS.Heartbeat:Connect(function()
    if not running or not isAlive() then return end
    local hum = getHum()
    if hum and C.Speed > 0 then hum.WalkSpeed = C.Speed end
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

conns.charAdded = player.CharacterAdded:Connect(function()
    gyro = nil
    intent.owner = "none"
    intent.pos = nil
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
-- ENEMY NERF
-- ============================================================
task.spawn(function()
    while running do
        if C.NerfEnemies then
            for _, enemy in getAllEnemies() do
                pcall(function()
                    if enemy:FindFirstChild("moveSpeed") then enemy.moveSpeed.Value = 0 end
                    if enemy:FindFirstChild("attackSpeed") then enemy.attackSpeed.Value = 999 end
                end)
            end
        end
        task.wait(1)
    end
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
    for _, t in player.Backpack:GetChildren() do
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
-- AUTO DODGE
-- ============================================================
local DANGER = {
    hitbox=1, hitBox=1, damagepart=1, trappart=1, lavaline=1,
    groundflame=1, flamecyclone=1, iceradius=1, memorydamagezone=1,
    charmark=1, cubepylon=1, electrictower=1, freezeplayerpart=1,
    precast=1, flamelash=1, sweepingflame=1, longline=1,
    spreadline=1, lineshot=1, circlehit=1, shurikenhit=1,
    hammerbothit=1, flamingshuriken=1,
}
local threats = {}

conns.ptAdd = workspace.DescendantAdded:Connect(function(d)
    if d:IsA("BasePart") and DANGER[d.Name] then threats[d] = true end
end)
conns.ptRem = workspace.DescendantRemoving:Connect(function(d)
    threats[d] = nil
end)

task.spawn(function()
    while running do
        if C.AutoDodge and isAlive() then
            local hrp = getHRP()
            if hrp then
                local pos = hrp.Position
                local closestThreat, closestDist = nil, C.DodgeRange

                for p in pairs(threats) do
                    if p.Parent then
                        local ok, d2 = pcall(function() return (pos - p.Position).Magnitude end)
                        if ok and d2 < closestDist then closestThreat, closestDist = p, d2 end
                    else
                        threats[p] = nil
                    end
                end

                for _, v in workspace:GetChildren() do
                    if v:IsA("Model") then
                        local hb = v:FindFirstChild("hitBox")
                        if hb and hb:IsA("BasePart") then
                            local ok, d2 = pcall(function() return (pos - hb.Position).Magnitude end)
                            if ok and d2 < closestDist then closestThreat, closestDist = hb, d2 end
                        end
                    end
                end

                if closestThreat then
                    local away = pos - closestThreat.Position
                    if away.Magnitude > 0.1 then
                        local flat = Vector3.new(away.X, 0, away.Z).Unit
                        local side = (tick() % 2 < 1) and 1 or -1
                        local perpDir = Vector3.new(-flat.Z * side, 0, flat.X * side)
                        local dodgeDir = (perpDir * 0.7 + flat * 0.3).Unit
                        requestMove("dodge", pos + dodgeDir * 18, 0.3)
                    end
                    task.wait(0.15)
                end
            end
        end
        task.wait(0.1)
    end
end)

-- ============================================================
-- MAIN FARM LOOP
-- ============================================================
task.spawn(function()
    while running do
        if not isAlive() then
            waitAlive()
            task.wait(1)
        else
            local hum = getHum()
            local hrp = getHRP()
            if not hum or not hrp then task.wait(0.5) continue end

            local hpPct = hum.Health / hum.MaxHealth

            if hpPct < C.RetreatPct then
                local enemy = nearest()
                if enemy and enemy:FindFirstChild("HumanoidRootPart") then
                    local away = hrp.Position - enemy.HumanoidRootPart.Position
                    if away.Magnitude > 0 then
                        requestMove("retreat", hrp.Position + away.Unit * 35, 0.4)
                    end
                end
                task.wait(0.4)
            else
                local enemy, d = nearest()
                if enemy and enemy:FindFirstChild("HumanoidRootPart") then
                    local ePos = enemy.HumanoidRootPart.Position
                    if d <= C.FarmDist then
                        requestMove("orbit", getOrbitPos(ePos), 0.2)
                        task.wait(0.12)
                    elseif d <= C.FarmDist * 2 then
                        local ehrp = enemy.HumanoidRootPart
                        local predicted = ehrp.Position + flatVel(ehrp) * C.LeadTime
                        local dir = (predicted - hrp.Position)
                        if dir.Magnitude > 0.1 then
                            requestMove("orbit", predicted - dir.Unit * C.OrbitDist, 0.25)
                        end
                        task.wait(0.25)
                    else
                        pathTo(enemy, nil)
                    end
                else
                    local target = nextRoomPos()
                    if target then pathTo(nil, target) else task.wait(1) end
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
print("[ZF7] ZeroFarm v7 Active — Cascade UI")

_G.StopZF = function()
    running = false
    for _, c in pairs(conns) do
        if typeof(c) == "RBXScriptConnection" then c:Disconnect() end
    end
    if gyro then pcall(function() gyro:Destroy() end) end
    local hum = getHum()
    if hum then hum.WalkSpeed = 16 end
    pcall(function() app:Destroy() end)
    print("[ZF7] Stopped")
end
