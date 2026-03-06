-- ============================================================
-- SERVICES
-- ============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InputEvent = ReplicatedStorage
    :WaitForChild("Luka's Additional Remotes")
    :WaitForChild("InputEvent")

local LocalPlayer = Players.LocalPlayer
local Character   = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local RootPart    = Character:WaitForChild("HumanoidRootPart")
local Humanoid    = Character:WaitForChild("Humanoid")

-- ============================================================
-- LOAD TABLES
-- ============================================================
local MainTables  = loadstring(game:HttpGet("https://raw.githubusercontent.com/locallyinsane/destinedlaziness/refs/heads/main/MainTables"))()
local MobTables   = loadstring(game:HttpGet("https://raw.githubusercontent.com/locallyinsane/destinedlaziness/refs/heads/main/MobTables"))()
local QuestTables = loadstring(game:HttpGet("https://raw.githubusercontent.com/locallyinsane/destinedlaziness/refs/heads/main/QuestTables"))()

local CraftableItems      = MainTables  and MainTables.CraftableItems        or {}
local EnemyDropTables     = MobTables   and MobTables.EnemyDropTables        or {}
local BossDropTables      = MobTables   and MobTables.BossDropTables         or {}
local EnemyLocations      = MobTables   and MobTables.EnemyLocations         or {}
local BossLocations       = MobTables   and MobTables.BossLocations          or {}
local Quests              = QuestTables and QuestTables.Quests               or {}
local QuestNPCLocations   = QuestTables and QuestTables.QuestNPCLocations    or {}

-- ============================================================
-- RAYFIELD
-- ============================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- ============================================================
-- HELPER
-- ============================================================
local function Notify(title, content, duration)
    Rayfield:Notify({
        Title    = title,
        Content  = content,
        Duration = duration or 4,
        Image    = 4483362458,
    })
end

-- ============================================================
-- CONFIG
-- ============================================================
local Config = {
    SafeZoneWidth      = 55,
    SafeZoneHeight     = 15,
    SafeZoneDepth      = 55,
    SafeZoneYOffset    = 10,
    NpcSearchRange     = 400,
    BulletTrackDist    = 300,
    SafetyMargin       = 3,
    UnsafeRegionY      = 500,
    CheckInterval      = 0,
    MaxTeleportRadius  = 80,
}

-- ============================================================
-- SHARED STATE
-- ============================================================
local IsActive       = false
local CurrentTarget  = nil
local SafeZoneCenter = Vector3.new()
local LockedPosition = nil
local BulletData     = {}
local Connections    = {}
local RenderConn     = nil
local IsDodging      = false
local IsEmergency    = false -- true while player is in low-health flee mode
local IsRespawning   = false -- true while waiting for character to fully reload after death

local VisualFolder = Workspace:FindFirstChild("__AutoDodgeVisuals")
    or Instance.new("Folder", Workspace)
VisualFolder.Name = "__AutoDodgeVisuals"

-- ============================================================
-- FARM STATE
-- ============================================================
local FarmActive           = false
local FarmTargetName       = nil
local TargetItemName       = ""
local TargetItemQty        = 1
local FarmStartInv         = {}
local FarmTargetLoopActive = false
local DodgeLoopActive      = false
local FarmDodgeReady       = false
local FarmFromScratch      = false
local ActiveFromScratch    = false
local CurrentSourceType    = nil  -- "enemy" | "boss" | "quest" � set by FarmMaterial
local CurrentSourceName    = nil  -- the enemy/boss/quest name currently being farmed

-- ============================================================
-- ENEMY FARM STATE
-- ============================================================
local EnemyFarmActive     = false
local EnemyFarmTargetName = ""

-- ============================================================
-- TARGETING FUNCTIONS
-- ============================================================

local function GetDodgeTarget()
    local MobFolder = Workspace:FindFirstChild("MobFolder")
    if not MobFolder then return nil end
    local best, bestDist = nil, math.huge
    local refPos = RootPart.Position  -- always measure from where the player actually is
    for _, obj in ipairs(MobFolder:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name == "HumanoidRootPart" then
            local model = obj.Parent
            if model and not model.Name:lower():find("dummy") then
                local hum = model:FindFirstChildWhichIsA("Humanoid")
                if hum and hum.Health > 0 then
                    local dist = (obj.Position - refPos).Magnitude
                    if dist <= Config.NpcSearchRange and dist < bestDist then
                        bestDist = dist
                        best     = model
                    end
                end
            end
        end
    end
    return best
end

-- Returns true if `name` matches the current FarmTargetName,
-- which may be a plain string OR a table of strings.
local function IsValidFarmTarget(name)
    if not FarmTargetName then return false end
    if type(FarmTargetName) == "string" then
        return name == FarmTargetName
    end
    for _, n in ipairs(FarmTargetName) do
        if name == n then return true end
    end
    return false
end

local function GetFarmTarget()
    if not FarmTargetName then return nil end
    local MobFolder = Workspace:FindFirstChild("MobFolder")
    if not MobFolder then return nil end
    for _, obj in ipairs(MobFolder:GetChildren()) do
        local ok, result = pcall(function()
            if IsValidFarmTarget(obj.Name) then
                local hum = obj:FindFirstChildWhichIsA("Humanoid")
                if hum and hum.Health > 0 then return obj end
            end
            return nil
        end)
        if ok and result then return result end
    end
    for _, obj in ipairs(MobFolder:GetDescendants()) do
        local ok, result = pcall(function()
            if obj:IsA("Model") and IsValidFarmTarget(obj.Name) then
                local hum = obj:FindFirstChildWhichIsA("Humanoid")
                if hum and hum.Health > 0 then return obj end
            end
            return nil
        end)
        if ok and result then return result end
    end
    return nil
end

-- Returns a list of all enemy names that share the same island as `enemyName`
-- AND appear in EnemyDropTables (i.e. are farmable regular enemies).
local function GetCoLocationEnemies(enemyName)
    local island = EnemyLocations[enemyName]
    if not island or island == "" then return { enemyName } end
    local group = {}
    for name, loc in pairs(EnemyLocations) do
        if loc == island and EnemyDropTables[name] then
            table.insert(group, name)
        end
    end
    if #group == 0 then return { enemyName } end
    return group
end

-- Returns true if at least one alive mob matching primaryName exists in MobFolder.
local function PrimaryTargetExists(primaryName)
    local MobFolder = Workspace:FindFirstChild("MobFolder")
    if not MobFolder then return false end
    for _, obj in ipairs(MobFolder:GetDescendants()) do
        local ok, found = pcall(function()
            if (obj:IsA("Model") or obj.Parent == MobFolder) and obj.Name == primaryName then
                local hum = obj:FindFirstChildWhichIsA("Humanoid")
                return hum and hum.Health > 0
            end
            return false
        end)
        if ok and found then return true end
    end
    return false
end

-- Searches MobFolder for any alive mob whose name is in the provided name list.
local function GetAnyTargetFromList(nameList)
    local MobFolder = Workspace:FindFirstChild("MobFolder")
    if not MobFolder then return nil end
    local nameSet = {}
    for _, n in ipairs(nameList) do nameSet[n] = true end
    for _, obj in ipairs(MobFolder:GetChildren()) do
        local ok, result = pcall(function()
            if nameSet[obj.Name] then
                local hum = obj:FindFirstChildWhichIsA("Humanoid")
                if hum and hum.Health > 0 then return obj end
            end
            return nil
        end)
        if ok and result then return result end
    end
    for _, obj in ipairs(MobFolder:GetDescendants()) do
        local ok, result = pcall(function()
            if obj:IsA("Model") and nameSet[obj.Name] then
                local hum = obj:FindFirstChildWhichIsA("Humanoid")
                if hum and hum.Health > 0 then return obj end
            end
            return nil
        end)
        if ok and result then return result end
    end
    return nil
end

-- ============================================================
-- SHARED TARGET HELPERS
-- ============================================================
local function IsTargetAlive(model)
    if not model then return false end
    local ok, result = pcall(function()
        if not model.Parent then return false end
        local hum = model:FindFirstChildWhichIsA("Humanoid")
        if not hum or hum.Health <= 0 then return false end
        return model:FindFirstChild("HumanoidRootPart") ~= nil
    end)
    return ok and result == true
end

local function GetTargetPosition()
    if not CurrentTarget then return nil end
    local root = CurrentTarget:FindFirstChild("HumanoidRootPart")
    return root and root.Position or nil
end

local function UpdateSafeZoneCenter()
    local pos = GetTargetPosition()
    if pos then
        SafeZoneCenter = pos + Vector3.new(0, Config.SafeZoneYOffset + Config.SafeZoneHeight / 2, 0)
    end
end

-- ============================================================
-- OBB COLLISION
-- ============================================================
local function IsPointInBullet(point, bullet)
    local cf      = bullet.CFrame
    local size    = bullet.Size
    local local_p = cf:PointToObjectSpace(point)
    local hX = size.X / 2 + Config.SafetyMargin
    local hY = Config.UnsafeRegionY / 2
    local hZ = size.Z / 2 + Config.SafetyMargin
    return math.abs(local_p.X) <= hX
       and math.abs(local_p.Y) <= hY
       and math.abs(local_p.Z) <= hZ
end

-- ============================================================
-- SAFE ZONE
-- ============================================================
local function IsInsideSafeZone(pos)
    local hW = Config.SafeZoneWidth  / 2
    local hH = Config.SafeZoneHeight / 2
    local hD = Config.SafeZoneDepth  / 2
    return pos.X >= SafeZoneCenter.X - hW and pos.X <= SafeZoneCenter.X + hW
       and pos.Y >= SafeZoneCenter.Y - hH and pos.Y <= SafeZoneCenter.Y + hH
       and pos.Z >= SafeZoneCenter.Z - hD and pos.Z <= SafeZoneCenter.Z + hD
end

local function IsInUnsafeRegion(pos)
    for bullet in pairs(BulletData) do
        if bullet.Parent and IsPointInBullet(pos, bullet) then return true end
    end
    return false
end

local function IsClear(pos)
    for bullet in pairs(BulletData) do
        if bullet.Parent and IsPointInBullet(pos, bullet) then return false end
    end
    return true
end

local function FindSafePosition()
    local hW = Config.SafeZoneWidth  / 2
    local hH = Config.SafeZoneHeight / 2
    local hD = Config.SafeZoneDepth  / 2
    for _ = 1, 50 do
        local c = Vector3.new(
            SafeZoneCenter.X + (math.random() * 2 - 1) * hW,
            SafeZoneCenter.Y + (math.random() * 2 - 1) * hH,
            SafeZoneCenter.Z + (math.random() * 2 - 1) * hD
        )
        if IsClear(c) then return c end
    end
    if IsClear(SafeZoneCenter) then return SafeZoneCenter end
    for _, mult in ipairs({ 1.5, 2.0, 3.0, 5.0 }) do
        for _ = 1, 40 do
            local c = Vector3.new(
                SafeZoneCenter.X + (math.random() * 2 - 1) * hW * mult,
                SafeZoneCenter.Y + (math.random() * 2 - 1) * hH * mult,
                SafeZoneCenter.Z + (math.random() * 2 - 1) * hD * mult
            )
            local flat = Vector3.new(c.X - SafeZoneCenter.X, 0, c.Z - SafeZoneCenter.Z)
            if flat.Magnitude <= Config.MaxTeleportRadius and IsClear(c) then return c end
        end
    end
    return nil
end

-- Like FindSafePosition but searches around a given center point instead of
-- SafeZoneCenter. Used during emergency flee where the player is high in the
-- air far from the normal safe zone.
local function FindSafePositionAround(center)
    local radius = 60
    for _ = 1, 80 do
        local c = Vector3.new(
            center.X + (math.random() * 2 - 1) * radius,
            center.Y + (math.random() * 2 - 1) * radius,
            center.Z + (math.random() * 2 - 1) * radius
        )
        if IsClear(c) then return c end
    end
    return nil
end

-- ============================================================
-- VISUALS
-- ============================================================
local function CreateVisualBox(size, center, color)
    local p        = Instance.new("Part")
    p.Size         = size
    p.CFrame       = CFrame.new(center)
    p.Anchored     = true
    p.CanCollide   = false
    p.CanTouch     = false
    p.CanQuery     = false
    p.Transparency = 1
    p.Color        = color
    p.Material     = Enum.Material.Neon
    p.CastShadow   = false
    p.Parent       = VisualFolder
    return p
end

local SafeZoneVisual = nil
local function RefreshSafeZoneVisual()
    if SafeZoneVisual then SafeZoneVisual:Destroy() end
    if not IsActive then return end
    SafeZoneVisual = CreateVisualBox(
        Vector3.new(Config.SafeZoneWidth, Config.SafeZoneHeight, Config.SafeZoneDepth),
        SafeZoneCenter, Color3.fromRGB(50, 255, 100)
    )
end

local function SyncBulletVisual(bullet)
    local data = BulletData[bullet]
    if not data or not data.visual then return end
    local s = bullet.Size
    data.visual.Size   = Vector3.new(s.X + Config.SafetyMargin * 2, Config.UnsafeRegionY, s.Z + Config.SafetyMargin * 2)
    data.visual.CFrame = bullet.CFrame
end

-- ============================================================
-- BULLET TRACKING
-- ============================================================
local function RegisterBullet(bullet)
    if BulletData[bullet] then return end
    if not bullet:IsA("BasePart") then return end
    if (bullet.Position - RootPart.Position).Magnitude > Config.BulletTrackDist then return end
    local s      = bullet.Size
    local visual = CreateVisualBox(
        Vector3.new(s.X + Config.SafetyMargin * 2, Config.UnsafeRegionY, s.Z + Config.SafetyMargin * 2),
        bullet.Position, Color3.fromRGB(255, 60, 60)
    )
    visual.CFrame = bullet.CFrame
    local data = { visual = visual }
    data.sizeConn = bullet:GetPropertyChangedSignal("Size"):Connect(function()
        if BulletData[bullet] then SyncBulletVisual(bullet) end
    end)
    data.posConn = bullet:GetPropertyChangedSignal("CFrame"):Connect(function()
        if BulletData[bullet] then SyncBulletVisual(bullet) end
    end)
    BulletData[bullet] = data
end

local function UnregisterBullet(bullet)
    local data = BulletData[bullet]
    if not data then return end
    if data.sizeConn then data.sizeConn:Disconnect() end
    if data.posConn  then data.posConn:Disconnect()  end
    if data.visual   then data.visual:Destroy()      end
    BulletData[bullet] = nil
end

local BulletsFolder = nil
local function WatchBulletsFolder()
    BulletsFolder = Workspace:FindFirstChild("Bullets")
    if not BulletsFolder then
        local wc
        wc = Workspace.ChildAdded:Connect(function(child)
            if child.Name == "Bullets" then
                wc:Disconnect(); BulletsFolder = child; WatchBulletsFolder()
            end
        end)
        table.insert(Connections, wc)
        return
    end
    for _, b in ipairs(BulletsFolder:GetChildren()) do task.spawn(RegisterBullet, b) end
    local ac = BulletsFolder.ChildAdded:Connect(function(b)   task.spawn(RegisterBullet,   b) end)
    local rc = BulletsFolder.ChildRemoved:Connect(function(b) task.spawn(UnregisterBullet, b) end)
    table.insert(Connections, ac)
    table.insert(Connections, rc)
end

-- ============================================================
-- DODGE ENGINE
-- ============================================================
local function MoveTo(pos)
    LockedPosition = pos
    RootPart.CFrame = CFrame.new(pos)
    RootPart.AssemblyLinearVelocity  = Vector3.zero
    RootPart.AssemblyAngularVelocity = Vector3.zero
end

local function DodgeIfNeeded()
    if not IsActive or IsDodging then return end
    if FarmActive and not FarmDodgeReady then return end
    if EnemyFarmActive and not FarmDodgeReady then return end
    -- No target yet means nothing is shooting at us; don't touch the player's position.
    if not IsTargetAlive(CurrentTarget) then return end
    IsDodging = true
    local checkPos = LockedPosition or RootPart.Position

    if IsEmergency then
        -- Emergency mode: the climb loop moves the player every 0.5s which is
        -- enough to outrun most attacks. Nothing extra needed here.
        IsDodging = false
        return
    else
        if IsInUnsafeRegion(checkPos) or not IsInsideSafeZone(checkPos) then
            local safe = FindSafePosition()
            if safe then MoveTo(safe) end
        end
    end
    IsDodging = false
end

local function StartDodgeLoop()
    if DodgeLoopActive then return end
    DodgeLoopActive = true
    task.spawn(function()
        while IsActive do
            DodgeIfNeeded()
            task.wait(Config.CheckInterval)
        end
        DodgeLoopActive = false
    end)
end

-- ============================================================
-- RENDER LOCK
-- ============================================================
local function StartRenderLock()
    if RenderConn then RenderConn:Disconnect() end
    RenderConn = RunService.RenderStepped:Connect(function()
        if not IsActive then return end
        if FarmActive and not FarmDodgeReady then return end
        if EnemyFarmActive and not FarmDodgeReady then return end
        -- Don't touch the player's position until we have a live target.
        -- Without this, the render lock freezes the player at 0,0,0 (the
        -- uninitialized SafeZoneCenter) before any enemies have spawned.
        if not IsEmergency and not IsTargetAlive(CurrentTarget) then return end
        local lockPos = LockedPosition or RootPart.Position
        RootPart.AssemblyLinearVelocity  = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
        if IsEmergency then
            -- hold the emergency flee position, don't rotate toward target
            RootPart.CFrame = CFrame.new(lockPos)
            return
        end
        local targetPos = GetTargetPosition()
        if targetPos then
            local dir = targetPos - lockPos
            if dir.Magnitude > 0.01 then
                RootPart.CFrame = CFrame.new(lockPos, lockPos + dir)
                return
            end
        end
        RootPart.CFrame = CFrame.new(lockPos)
    end)
end

local function StopRenderLock()
    if RenderConn then RenderConn:Disconnect(); RenderConn = nil end
end

-- ============================================================
-- ============================================================
-- FREEZE / UNFREEZE
-- ============================================================
local function FreezePlayer()
    Humanoid.AutoRotate = false
    LockedPosition = RootPart.Position
end

local function UnfreezePlayer()
    Humanoid.AutoRotate = true
    LockedPosition = nil
end

-- ============================================================
-- TELEPORT HELPERS
-- ============================================================

local function TeleportToLocation(locationName)
    local ok, err = pcall(function()
        local frame = LocalPlayer.PlayerGui.GuiShop.TeleportersMainFrame.TeleportersFrame
        local button = frame:FindFirstChild(locationName)
        if not button then
            error(("button '%s' not found in TeleportersFrame"):format(locationName))
        end
        firesignal(button.MouseButton1Up)
        firesignal(button.MouseButton1Click)
        firesignal(button.MouseButton1Down)
    end)
    if not ok then
        warn(("[TeleportToLocation] failed for '%s': %s"):format(locationName, tostring(err)))
    end
    task.wait(0.35)
    return ok
end

local function TeleportToEnemyIsland(enemyName)
    local islandName = EnemyLocations[enemyName]

    if islandName == nil then
        local msg = ("no island mapped for '%s' � skipping teleport"):format(enemyName)
        warn("[AutoFarm] " .. msg)
        Notify("no island found", msg, 5)
        return false
    end

    if islandName == "" then
        local msg = ("island for '%s' is unknown, can't teleport"):format(enemyName)
        warn("[AutoFarm] " .. msg)
        Notify("unknown island", msg, 5)
        return false
    end

    -- Void Mines requires teleporting to Evil Island first, then touching the Void Teleporter
    if islandName == "Void Mines" then
        Notify("void mines", "heading to Evil Island first", 4)
        TeleportToLocation("Evil Island")
        task.wait(1.25)
        local ok, err = pcall(function()
            local voidTele = Workspace:WaitForChild("Ascension Trial Maps")
                :WaitForChild("Ascensia Isles")
                :WaitForChild("Void Teleporter")
                :WaitForChild("Tele")
            RootPart.CFrame = voidTele.CFrame + Vector3.new(0, 4, 0)
        end)
        if not ok then
            warn("[AutoFarm] Void Teleporter failed: " .. tostring(err))
            Notify("void teleport failed", tostring(err), 5)
            return false
        end
        task.wait(2)
        return true
    end

    local ok, err = pcall(function()
        local frame = LocalPlayer.PlayerGui.GuiShop.TeleportersMainFrame.TeleportersFrame
        local button = frame:FindFirstChild(islandName)
        if not button then
            error(("button '%s' not found in TeleportersFrame"):format(islandName))
        end
        firesignal(button.MouseButton1Up)
        firesignal(button.MouseButton1Click)
        firesignal(button.MouseButton1Down)
    end)

    if not ok then
        local msg = ("cant teleport to %s: %s"):format(islandName, tostring(err))
        warn("[AutoFarm] " .. msg)
        Notify("teleport failed", msg, 5)
        return false
    end

    task.wait(0.35)
    return true
end

-- ============================================================
-- TELEPORT TO TARGET
-- ============================================================
local function TeleportToTarget(model)
    local ok, err = pcall(function()
        local root = model:FindFirstChild("HumanoidRootPart")
        if not root then return end
        SafeZoneCenter  = root.Position + Vector3.new(0, Config.SafeZoneYOffset + Config.SafeZoneHeight / 2, 0)
        LockedPosition  = SafeZoneCenter
        RootPart.CFrame = CFrame.new(SafeZoneCenter)
        CurrentTarget   = model
    end)
    if not ok then
        warn("[AutoFarm] TeleportToTarget failed: " .. tostring(err))
    end
end

-- ============================================================
-- KILL AND WAIT
-- ============================================================
local function KillAndWait(model, onDeath)
    local confirmedDead = false
    local start         = tick()
    while tick() - start < 120 do
        local ok, state = pcall(function()
            local hum = model:FindFirstChildWhichIsA("Humanoid")
            if hum and hum.Health <= 0 then return "dead_health" end
            if not model.Parent           then return "dead_removed" end
            return "alive"
        end)
        if not ok or state == "dead_health" or state == "dead_removed" then
            confirmedDead = true
            if onDeath then pcall(onDeath) end
            break
        end
        task.wait(0.2)
    end
    if confirmedDead then
        task.wait(1.25)
    end
    return confirmedDead
end

-- ============================================================
-- AFTER BOSS TELEPORT TABLE
-- ============================================================
local AfterBossTeleports = {
    ["Abaddon"]                     = "Evil Island",
    ["Bobby"]                       = "Admin Island",
    ["Pearl the Omega"]             = "Admin Island",
    ["Rainbow Zack"]                = "Admin Island",
    ["Supreme Gamer"]               = "Admin Island",
    ["Matt the Ruler of Fedoras"]   = "Admin Island",
}

local function ReturnAfterBoss(bossName)
    local dest = AfterBossTeleports[bossName] or "Portal Room"
    TeleportToLocation(dest)
end

-- ============================================================
-- SOFT RESET (respawn without full deactivate)
-- ============================================================
local function SoftReset()
    IsActive = false
    StopRenderLock()
    for _, c in ipairs(Connections) do c:Disconnect() end; Connections = {}
    for b in pairs(BulletData) do UnregisterBullet(b) end; BulletData = {}
    if SafeZoneVisual then SafeZoneVisual:Destroy(); SafeZoneVisual = nil end
    FarmDodgeReady  = false
    CurrentTarget   = nil
    LockedPosition  = nil
    Humanoid.AutoRotate = true
    task.wait(0.5)
end

-- Forward declare auto-fire and farm entry points so Deactivate/Activate
-- can reference them before the full definitions appear below.
local StartAutoFire
local StopAutoFire
local ActivateForFarm

-- ============================================================
-- ACTIVATE / DEACTIVATE
-- ============================================================
local function Deactivate()
    if not IsActive then return end
    IsActive             = false
    IsDodging            = false
    IsEmergency          = false
    FarmDodgeReady       = false
    FarmTargetLoopActive = false
    DodgeLoopActive      = false
    StopAutoFire()
    StopRenderLock()
    for _, c in ipairs(Connections) do c:Disconnect() end
    Connections = {}
    for bullet in pairs(BulletData) do UnregisterBullet(bullet) end
    BulletData = {}
    if SafeZoneVisual then SafeZoneVisual:Destroy(); SafeZoneVisual = nil end
    UnfreezePlayer()
    VisualFolder:ClearAllChildren()
    CurrentTarget = nil
end

-- ============================================================
-- TARGET LOOPS
-- ============================================================
local function StartDodgeTargetLoop()
    task.spawn(function()
        while IsActive and not FarmActive do
            if not IsEmergency then
                if not IsTargetAlive(CurrentTarget) then
                    CurrentTarget = GetDodgeTarget()
                    if CurrentTarget then
                        -- Only teleport and update zone when we actually found a target.
                        -- Without this guard, SafeZoneCenter is still Vector3(0,0,0) and
                        -- the render lock would instantly teleport the player there.
                        UpdateSafeZoneCenter()
                        LockedPosition  = SafeZoneCenter
                        RootPart.CFrame = CFrame.new(SafeZoneCenter)
                        Humanoid.AutoRotate = false
                    end
                    -- No target found yet: leave LockedPosition at the player's
                    -- current position so they stay put until enemies spawn.
                else
                    UpdateSafeZoneCenter()
                    LockedPosition = SafeZoneCenter
                end
                if SafeZoneVisual then
                    SafeZoneVisual.Size   = Vector3.new(Config.SafeZoneWidth, Config.SafeZoneHeight, Config.SafeZoneDepth)
                    -- Only show the visual where a target actually is
                    if CurrentTarget then
                        SafeZoneVisual.CFrame = CFrame.new(SafeZoneCenter)
                    end
                end
            end
            task.wait(0.025)
        end
    end)
end

local function StartFarmTargetLoop()
    if FarmTargetLoopActive then return end
    FarmTargetLoopActive = true
    task.spawn(function()
        local lastEngageNotify = 0
        while IsActive and (FarmActive or EnemyFarmActive) do
            local alive = IsTargetAlive(CurrentTarget)
            if not alive then
                if FarmDodgeReady then
                    FarmDodgeReady      = false
                    LockedPosition      = nil
                    Humanoid.AutoRotate = true
                end
                CurrentTarget = GetFarmTarget()
            end
            if IsTargetAlive(CurrentTarget) and not FarmDodgeReady then
                FarmDodgeReady      = true
                Humanoid.AutoRotate = false
                if not IsEmergency then
                    UpdateSafeZoneCenter()
                    LockedPosition = SafeZoneCenter
                end
                if tick() - lastEngageNotify > 5 then
                    Notify("mob found", "fighting " .. CurrentTarget.Name, 2)
                    lastEngageNotify = tick()
                end
            end
            if FarmDodgeReady and not IsEmergency then UpdateSafeZoneCenter() end
            if SafeZoneVisual then
                SafeZoneVisual.Size   = Vector3.new(Config.SafeZoneWidth, Config.SafeZoneHeight, Config.SafeZoneDepth)
                SafeZoneVisual.CFrame = CFrame.new(SafeZoneCenter)
            end
            task.wait(0.05)
        end
        FarmDodgeReady       = false
        FarmTargetLoopActive = false
    end)
end

local function Activate()
    if IsActive then return end
    IsActive = true
    StartAutoFire()
    -- Lock the player at their current position until a target is found.
    -- Also seed SafeZoneCenter here so it is never Vector3(0,0,0) if anything
    -- reads it before the first enemy spawns.
    LockedPosition  = RootPart.Position
    SafeZoneCenter  = RootPart.Position
    RefreshSafeZoneVisual()
    FreezePlayer()
    StartRenderLock()
    WatchBulletsFolder()
    StartDodgeTargetLoop()
    StartDodgeLoop()
end

-- Define ActivateForFarm (and assign to the forward-declared upvalue)
ActivateForFarm = function()
    if IsActive then return end
    IsActive       = true
    FarmDodgeReady = false
    StartAutoFire()
    UpdateSafeZoneCenter()
    RefreshSafeZoneVisual()
    StartRenderLock()
    WatchBulletsFolder()
    StartFarmTargetLoop()
    StartDodgeLoop()
end

-- ============================================================
-- BOSS FIGHT
-- ============================================================
local function StartBossFight(bossName)
    local bossLocation = BossLocations[bossName] or "Portal Room"
    TeleportToLocation(bossLocation)
    task.wait(1)

    local pad = nil

    if bossLocation == "Portal Room" then
        local portalRoom = Workspace:FindFirstChild("Portal Room")
        if not portalRoom then
            Notify("hm", "couldn't find Portal Room", 4)
            return false
        end
        local bossTeleporters = portalRoom:FindFirstChild("Boss Teleporters")
        if not bossTeleporters then
            Notify("hm", "Boss Teleporters folder is missing", 5)
            return false
        end
        local padName = bossName .. " Teleporter"
        pad = bossTeleporters:FindFirstChild(padName)
        if not pad then
            for _, child in ipairs(bossTeleporters:GetChildren()) do
                if child.Name:lower() == padName:lower() then
                    pad = child; break
                end
            end
        end
    elseif bossLocation == "Admin Island" then
        -- workspace["Ascension Trial Maps"]["Admin Tower Island"].BossTransports["[FirstWord] Boss Transporter"]
        local trialMaps = Workspace:FindFirstChild("Ascension Trial Maps")
        if not trialMaps then
            Notify("hm", "Ascension Trial Maps not found", 5)
            return false
        end
        local adminIsland = trialMaps:FindFirstChild("Admin Tower Island")
        if not adminIsland then
            Notify("hm", "Admin Tower Island not found", 5)
            return false
        end
        local bossTransports = adminIsland:FindFirstChild("BossTransports")
        if not bossTransports then
            Notify("hm", "BossTransports not found in Admin Tower Island", 5)
            return false
        end
        local firstName = bossName:match("^(%S+)")
        local padName   = firstName .. " Boss Transporter"
        pad = bossTransports:FindFirstChild(padName)
        if not pad then
            for _, child in ipairs(bossTransports:GetChildren()) do
                if child.Name:lower() == padName:lower() then
                    pad = child; break
                end
            end
        end
    else
        local trialMaps = Workspace:FindFirstChild("Ascension Trial Maps")
        if not trialMaps then
            Notify("hm", "Ascension Trial Maps not found", 5)
            return false
        end
        local padName = bossName .. " Teleporter"
        for _, child in ipairs(trialMaps:GetDescendants()) do
            if child.Name:lower() == padName:lower() then
                pad = child; break
            end
        end
    end

    if not pad then
        Notify("no pad found", "couldn't find a teleporter for " .. bossName, 5)
        return false
    end

    local padBase, bestVol = nil, 0
    for _, part in ipairs(pad:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "Button" then
            local vol = part.Size.X * part.Size.Y * part.Size.Z
            if vol > bestVol then bestVol = vol; padBase = part end
        end
    end
    if padBase then
        RootPart.CFrame = padBase.CFrame + Vector3.new(0, 4, 0)
        task.wait(0.4)
    end

    -- Button path varies by boss type:
    -- Admin Island: pad.Portal.Button.ClickDetector
    -- Others:       pad.Button.ClickDetector
    local button = nil
    local cd     = nil

    local portal = pad:FindFirstChild("Portal")
    if portal then
        local portalButton = portal:FindFirstChild("Button")
        if portalButton then
            button = portalButton
            cd     = portalButton:FindFirstChild("ClickDetector")
        end
    end

    if not cd then
        button = pad:FindFirstChild("Button")
        if button then
            cd = button:FindFirstChild("ClickDetector")
        end
    end

    if not cd then
        -- last resort: search all descendants
        cd = pad:FindFirstChildWhichIsA("ClickDetector", true)
    end

    if not cd then return false end

    Notify("heading in", "starting fight with " .. bossName, 1)
    fireclickdetector(cd)
    task.wait(2)
    return true
end

-- ============================================================
-- WAIT FOR BOSS TO SPAWN
-- ============================================================
local function WaitForBoss(bossName, timeout)
    local start = tick()
    while tick() - start < (timeout or 30) do
        local MobFolder = Workspace:FindFirstChild("MobFolder")
        if MobFolder then
            for _, obj in ipairs(MobFolder:GetChildren()) do
                local ok, found = pcall(function()
                    if obj.Name:lower():find(bossName:lower()) then
                        local hum = obj:FindFirstChildWhichIsA("Humanoid")
                        if hum and hum.Health > 0 then return obj end
                    end
                    return nil
                end)
                if ok and found then
                    task.wait(2)
                    local hum = found:FindFirstChildWhichIsA("Humanoid")
                    if found.Parent and hum and hum.Health > 0 then
                        return found
                    end
                end
            end
        end
        task.wait(0.5)
    end
    return nil
end

-- ============================================================
-- INVENTORY
-- ============================================================
local function GetInventory()
    local buckets = {}
    for _, v in pairs(getgc(true)) do
        if type(v) == "table" then
            local name   = rawget(v, "Name")
            local amount = rawget(v, "Amount")
            if type(name) == "string" and amount ~= nil then
                local n = tonumber(amount)
                if n then
                    if not buckets[name] then buckets[name] = {} end
                    table.insert(buckets[name], n)
                end
            end
        end
    end
    local inv = {}
    for name, vals in pairs(buckets) do
        local maxVal = 0
        for _, v in ipairs(vals) do
            if v > maxVal then maxVal = v end
        end
        inv[name] = maxVal
    end
    return inv
end

-- ============================================================
-- CRAFTING TREE RESOLVER
-- ============================================================
local function ResolveCraftingTree(itemName, qty, resolved, visited, inv)
    resolved = resolved or {}
    visited  = visited  or {}
    inv      = inv      or {}
    qty      = qty      or 1
    if visited[itemName] then return resolved end
    visited[itemName] = true
    local recipe = CraftableItems[itemName]
    if not recipe then
        resolved[itemName] = (resolved[itemName] or 0) + qty
        visited[itemName]  = nil
        return resolved
    end
    local alreadyHave = inv[itemName] or 0
    local stillNeed   = math.max(0, qty - alreadyHave)
    if stillNeed <= 0 then
        visited[itemName] = nil
        return resolved
    end
    inv[itemName] = math.max(0, alreadyHave - qty)
    for ingredient, amount in pairs(recipe) do
        if ingredient ~= "GoldCost" and ingredient ~= "Tier" and ingredient ~= "Rarity" then
            local amountNum = tonumber(amount)
            if not amountNum then
                continue
            end
            local needed = amountNum * stillNeed
            if CraftableItems[ingredient] then
                ResolveCraftingTree(ingredient, needed, resolved, visited, inv)
            else
                resolved[ingredient] = (resolved[ingredient] or 0) + needed
            end
        end
    end
    visited[itemName] = nil
    return resolved
end

-- ============================================================
-- DROP SOURCE FINDER
-- ============================================================
local function FindDropSource(itemName)
    -- Quest rewards take priority
    for questName, data in pairs(Quests) do
        if data.Rewards then
            for rewardName in pairs(data.Rewards) do
                if rewardName == itemName then
                    return "quest", questName
                end
            end
        end
    end
    for enemyName, data in pairs(EnemyDropTables) do
        if data.Drops then
            for _, drop in ipairs(data.Drops) do
                local item = drop.item
                if type(item) == "string" and item == itemName then
                    return "enemy", enemyName
                elseif type(item) == "table" then
                    for _, v in ipairs(item) do
                        if v == itemName then return "enemy", enemyName end
                    end
                end
            end
        end
    end
    for bossName, data in pairs(BossDropTables) do
        if data.Drops then
            for _, drop in ipairs(data.Drops) do
                local item = drop.item
                if type(item) == "string" and item == itemName then
                    return "boss", bossName
                elseif type(item) == "table" then
                    for _, v in ipairs(item) do
                        if v == itemName then return "boss", bossName end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- ============================================================
-- QUEST SOURCE HELPERS
-- ============================================================

local function GetQuestRequirements(questName)
    local q = Quests[questName]
    return q and q.Requirements or nil
end

local function TeleportToQuestNPC(questName)
    local island = QuestNPCLocations[questName]
    if island == nil then
        warn(("[Quest] no location mapped for '%s'"):format(questName))
    elseif island == "nil" or island == "" then
        warn(("[Quest] location for '%s' is intentionally blank, skipping island teleport"):format(questName))
    else
        Notify("heading to npc", ("going to %s for %s"):format(island, questName), 4)
        TeleportToLocation(island)
        task.wait(1.5)
    end

    local npcModel = nil

    local npcsFolder = Workspace:FindFirstChild("NPCs")
    if npcsFolder then
        npcModel = npcsFolder:FindFirstChild(questName)
    end

    if not npcModel then
        local trialMaps = Workspace:FindFirstChild("Ascension Trial Maps")
        if trialMaps then
            for _, obj in ipairs(trialMaps:GetDescendants()) do
                if obj:IsA("Model") and obj.Name == questName then
                    npcModel = obj
                    break
                end
            end
        end
    end

    if not npcModel then
        Notify("npc not found", ("can't find NPC: %s"):format(questName), 5)
        return nil
    end

    local npcRoot = npcModel:FindFirstChild("HumanoidRootPart")
    if not npcRoot then
        Notify("npc root missing", questName, 4)
        return nil
    end

    RootPart.CFrame = npcRoot.CFrame * CFrame.new(0, 0, 4)
    task.wait(0.5)

    return npcModel
end

local function AcceptQuest(questName)
    local ok, err = pcall(function()
        local args = { "StartQuest", questName }
        Workspace:WaitForChild("Remote"):WaitForChild("QuestEvent"):FireServer(unpack(args))
    end)
    if not ok then
        warn(("[Quest] AcceptQuest failed for '%s': %s"):format(questName, tostring(err)))
    end
    return ok
end

local function HandInQuest(questName)
    local ok, err = pcall(function()
        local args = { questName }
        Workspace:WaitForChild("Remote"):WaitForChild("QuestRepeat"):FireServer(unpack(args))
    end)
    if not ok then
        warn(("[Quest] HandInQuest failed for '%s': %s"):format(questName, tostring(err)))
    end
    return ok
end

-- ============================================================
-- QUEST FARMING
-- ============================================================
local EXP_QUEST_ENEMY = "Fury Destructive Overlord"
local EXP_QUEST_KILLS = 2
local GOLD_FARM_BOSS = "Alpha Destructive Overlord"

local function FindBestGoldBoss(goldNeeded)
    local data = BossDropTables[GOLD_FARM_BOSS]
    local goldPerKill = data and tonumber(data.Gold) or 0
    if goldPerKill <= 0 then
        warn(("[AutoFarm] %s has no Gold entry in BossDropTables"):format(GOLD_FARM_BOSS))
        return nil, 0, 0
    end
    local kills = math.ceil(goldNeeded / goldPerKill)
    return GOLD_FARM_BOSS, goldPerKill, kills
end

local function DoQuest(questName)
    local reqs = GetQuestRequirements(questName)
    if not reqs then
        Notify("no reqs?", ("quest '%s' has no requirements"):format(questName), 5)
        return false
    end

    Notify("quest time", ("starting: %s"):format(questName), 5)

    local npcModel = TeleportToQuestNPC(questName)
    if not npcModel then return false end
    AcceptQuest(questName)
    task.wait(1)

    local goldRequired = 0
    for target, amount in pairs(reqs) do
        if target == "Gold" then
            goldRequired = tonumber(amount) or 0
        end
    end

    local goldEarned = 0

    for target, amount in pairs(reqs) do
        if not FarmActive then return false end
        if target == "Gold" then continue end

        local killTarget = target
        local killAmt    = tonumber(amount) or 1

        if target == "Exp" then
            killTarget = EXP_QUEST_ENEMY
            killAmt    = EXP_QUEST_KILLS
            Notify("exp quest", ("killing %dx %s for exp"):format(killAmt, killTarget), 4)
        else
            Notify("quest kill", ("need %dx %s"):format(killAmt, target), 4)
        end

        local srcType, srcName = nil, nil
        for enemyName in pairs(EnemyDropTables) do
            if enemyName == killTarget then srcType = "enemy"; srcName = killTarget; break end
        end
        if not srcType then
            for bossName in pairs(BossDropTables) do
                if bossName == killTarget then srcType = "boss"; srcName = killTarget; break end
            end
        end

        if not srcType then
            Notify("can't find enemy", ("no source for quest target: %s"):format(killTarget), 5)
        else
            local killed = 0
            while FarmActive and killed < killAmt do
                if srcType == "boss" then
                    FarmDodgeReady = false; CurrentTarget = nil; LockedPosition = nil; Humanoid.AutoRotate = true
                    local ok = StartBossFight(srcName)
                    if not ok then task.wait(3); continue end
                    local boss = WaitForBoss(srcName, 30)
                    if not boss then task.wait(3); continue end
                    TeleportToTarget(boss)
                    task.wait(0.5)
                    if not IsActive and FarmActive then ActivateForFarm() end
                    local dead = KillAndWait(boss)
                    FarmDodgeReady = false; CurrentTarget = nil; LockedPosition = nil; Humanoid.AutoRotate = true
                    if dead then
                        killed = killed + 1
                        local bossGold = tonumber(BossDropTables[srcName] and BossDropTables[srcName].Gold) or 0
                        goldEarned = goldEarned + bossGold
                        ReturnAfterBoss(srcName)
                        SoftReset()
                        local tool = LocalPlayer.Backpack:FindFirstChild("Solar Beacon")
                        if tool then tool.Parent = Workspace[LocalPlayer.Name] end
                        if FarmActive then ActivateForFarm() end
                    end
                    task.wait(1)

                else
                    FarmTargetName = srcName
                    local tpOk = TeleportToEnemyIsland(srcName)
                    if not tpOk then
                        warn(("[Quest] no island for '%s'"):format(srcName))
                    end

                    if srcName == "Firecrystal Guard" then
                        task.wait(1)
                        local goal    = Vector3.new(40830, 2080, -610)
                        local dist    = (RootPart.Position - goal).Magnitude
                        local dur     = math.max(1, dist / 200)
                        local startP  = RootPart.Position
                        local elapsed = 0
                        local conn
                        conn = RunService.Heartbeat:Connect(function(dt)
                            elapsed = elapsed + dt
                            local a = math.min(elapsed / dur, 1)
                            local t = a * a * (3 - 2 * a)
                            RootPart.CFrame = CFrame.new(startP:Lerp(goal, t))
                            RootPart.AssemblyLinearVelocity  = Vector3.zero
                            RootPart.AssemblyAngularVelocity = Vector3.zero
                            if a >= 1 then conn:Disconnect() end
                        end)
                        while conn.Connected do task.wait(0.05) end
                    end

                    local searchStart = tick()
                    local enemy = nil
                    while tick() - searchStart < 15 do
                        enemy = GetFarmTarget()
                        if enemy then break end
                        task.wait(0.5)
                    end

                    if not enemy then
                        Notify("no enemy", ("can't find %s, retrying"):format(srcName), 4)
                        task.wait(3)
                        continue
                    end

                    TeleportToTarget(enemy)
                    task.wait(0.5)
                    if not IsActive and FarmActive then ActivateForFarm() end

                    local dead = KillAndWait(enemy)
                    FarmDodgeReady = false; CurrentTarget = nil; LockedPosition = nil; Humanoid.AutoRotate = true
                    task.wait(0.5)

                    if dead then killed = killed + 1 end
                end
            end
        end
    end

    -- Handle remaining gold shortfall
    if goldRequired > 0 and goldEarned < goldRequired then
        local stillNeed = goldRequired - goldEarned
        local goldBoss, goldPerBossKill, killsNeeded = FindBestGoldBoss(stillNeed)
        if not goldBoss then
            Notify("gold farming", ("need %d more gold but no suitable boss found"):format(stillNeed), 5)
        else
            Notify("gold farming", ("need %d more gold � killing %dx %s (%d/kill)"):format(
                stillNeed, killsNeeded, goldBoss, goldPerBossKill), 5)
            local killed = 0
            while FarmActive and killed < killsNeeded do
                FarmDodgeReady = false; CurrentTarget = nil; LockedPosition = nil; Humanoid.AutoRotate = true
                TeleportToLocation("Portal Room")
                task.wait(1)
                local ok = StartBossFight(goldBoss)
                if not ok then task.wait(3); continue end
                local boss = WaitForBoss(goldBoss, 30)
                if not boss then task.wait(3); continue end
                TeleportToTarget(boss)
                task.wait(0.5)
                if not IsActive and FarmActive then ActivateForFarm() end
                local dead = KillAndWait(boss)
                FarmDodgeReady = false; CurrentTarget = nil; LockedPosition = nil; Humanoid.AutoRotate = true
                if dead then
                    killed = killed + 1
                    ReturnAfterBoss(goldBoss)
                    SoftReset()
                    local tool = LocalPlayer.Backpack:FindFirstChild("Solar Beacon")
                    if tool then tool.Parent = Workspace[LocalPlayer.Name] end
                    if FarmActive then ActivateForFarm() end
                end
                task.wait(1)
            end
        end
    end

    Notify("handing in", questName, 3)
    TeleportToQuestNPC(questName)
    HandInQuest(questName)
    task.wait(1)

    FarmTargetName = nil
    return true
end

-- ============================================================
-- MISSING MATERIALS
-- ============================================================
local function GetMissingMaterials(itemName, qty)
    qty = math.max(1, tonumber(qty) or 1)
    local inv     = GetInventory()
    local invCopy = {}
    if not ActiveFromScratch then
        for k, v in pairs(inv) do invCopy[k] = v end
    end
    invCopy[itemName] = 0
    local needed  = ResolveCraftingTree(itemName, qty, nil, nil, invCopy)
    local missing = {}
    for mat, q in pairs(needed) do
        local qtyNum = tonumber(q)
        if qtyNum then
            local have = ActiveFromScratch and 0 or (inv[mat] or 0)
            if have < qtyNum then missing[mat] = qtyNum - have end
        end
    end
    return missing
end

-- ============================================================
-- FARM MATERIAL
-- ============================================================
local function FarmMaterial(matName, needed, sourceType, sourceName)
    if not tonumber(needed) then return false end
    needed = tonumber(needed)

    FarmTargetName    = sourceName
    CurrentSourceType = sourceType
    CurrentSourceName = sourceName
    FarmStartInv      = GetInventory()
    local startHave   = FarmStartInv[matName] or 0

    Notify("on it", ("need %dx %s from %s"):format(needed, matName, sourceName), 5)

    while FarmActive do
        -- Pause all farm activity while the character is respawning
        if IsRespawning then task.wait(0.2); continue end

        local inv    = GetInventory()
        local gained = math.max(0, (inv[matName] or 0) - startHave)

        if gained >= needed then
            Notify("got it", ("+%dx %s � moving on"):format(gained, matName), 5)
            FarmTargetName    = nil
            CurrentTarget     = nil
            FarmDodgeReady    = false
            CurrentSourceType = nil
            CurrentSourceName = nil
            return true
        end

        -- BOSS PATH
        if sourceType == "boss" then
            FarmDodgeReady      = false
            CurrentTarget       = nil
            LockedPosition      = nil
            Humanoid.AutoRotate = true

            local ok = StartBossFight(sourceName)
            if not ok then task.wait(3); continue end

            local boss = WaitForBoss(sourceName, 30)
            if not boss then task.wait(3); continue end
            TeleportToTarget(boss)
            task.wait(0.5)
            if not IsActive and FarmActive then ActivateForFarm() end

            local killed = KillAndWait(boss)
            FarmDodgeReady      = false
            CurrentTarget       = nil
            LockedPosition      = nil
            Humanoid.AutoRotate = true

            if killed then
                ReturnAfterBoss(sourceName)
                SoftReset()

                local tool = LocalPlayer.Backpack:FindFirstChild("Solar Beacon")
                if tool then
                    tool.Parent = Workspace[LocalPlayer.Name]
                end

                if FarmActive then ActivateForFarm() end
            end
            task.wait(1)

        -- REGULAR ENEMY PATH
        elseif sourceType == "enemy" then
            local tpOk = TeleportToEnemyIsland(sourceName)
            if not tpOk then
                warn(("[AutoFarm] proceeding without island teleport for '%s'"):format(sourceName))
            end

            if sourceName == "Firecrystal Guard" then
                task.wait(1)
                local goal     = Vector3.new(40830, 2080, -610)
                local distance = (RootPart.Position - goal).Magnitude
                local duration = math.max(1, distance / 200)
                local start    = RootPart.Position
                local elapsed  = 0
                local stepConn
                stepConn = RunService.Heartbeat:Connect(function(dt)
                    elapsed = elapsed + dt
                    local alpha = math.min(elapsed / duration, 1)
                    local t = alpha * alpha * (3 - 2 * alpha)
                    RootPart.CFrame = CFrame.new(start:Lerp(goal, t))
                    RootPart.AssemblyLinearVelocity  = Vector3.zero
                    RootPart.AssemblyAngularVelocity = Vector3.zero
                    if alpha >= 1 then
                        stepConn:Disconnect()
                    end
                end)
                while stepConn.Connected do task.wait(0.05) end
            end

            -- Periodic inventory checker: every 15 seconds refresh how much
            -- of the material we actually have so drops that landed mid-fight
            -- are counted immediately and the loop exits as soon as we're done.
            local invCheckDone = false
            local lastInvCheck = tick()
            task.spawn(function()
                while FarmActive and not invCheckDone do
                    task.wait(8)
                    if not FarmActive or invCheckDone then break end
                    local freshInv    = GetInventory()
                    local freshGained = math.max(0, (freshInv[matName] or 0) - startHave)
                    if freshGained >= needed then
                        Notify("got it", ("+%dx %s � moving on"):format(freshGained, matName), 5)
                        invCheckDone = true
                    else
                        local stillNeed = needed - freshGained
                        Notify("inventory check", ("have %d/%d %s, still need %d"):format(
                            freshGained, needed, matName, stillNeed), 4)
                    end
                    lastInvCheck = tick()
                end
            end)

            -- Build the full co-location list once so filler lookup is cheap.
            local coLocationGroup = GetCoLocationEnemies(sourceName)
            local hasFillers      = #coLocationGroup > 1

            while FarmActive and not invCheckDone do
                if IsRespawning then task.wait(0.2); continue end

                local invCheck  = GetInventory()
                local gainedNow = math.max(0, (invCheck[matName] or 0) - startHave)
                if gainedNow >= needed then break end

                FarmDodgeReady      = false
                CurrentTarget       = nil
                LockedPosition      = nil
                Humanoid.AutoRotate = true

                -- Check if the primary target is currently alive.
                local primaryUp = PrimaryTargetExists(sourceName)

                if not primaryUp and hasFillers then
                    -- Swap FarmTargetName to the full co-location group so that
                    -- GetFarmTarget, StartFarmTargetLoop, and the safe zone all
                    -- behave exactly as if the filler were the real target.
                    FarmTargetName = coLocationGroup
                    Notify("filling time", ("no %s up � farming co-location mobs"):format(sourceName), 3)

                    -- Keep killing co-location mobs until the primary respawns.
                    while FarmActive and not invCheckDone do
                        -- As soon as the primary is back, break out and let the
                        -- outer loop handle it with FarmTargetName restored.
                        if PrimaryTargetExists(sourceName) then
                            Notify("primary spawned", (sourceName .. " is up � switching back"):format(), 3)
                            break
                        end

                        local fillerEnemy = GetFarmTarget()
                        if not fillerEnemy then
                            task.wait(0.5)
                            continue
                        end

                        TeleportToTarget(fillerEnemy)
                        task.wait(0.5)
                        if not IsActive and FarmActive then ActivateForFarm() end

                        -- Kill the filler but bail early if the primary spawns.
                        local fillerDead = false
                        task.spawn(function()
                            KillAndWait(fillerEnemy)
                            fillerDead = true
                        end)
                        while not fillerDead and FarmActive do
                            if PrimaryTargetExists(sourceName) then
                                Notify("primary spawned", (sourceName .. " is up � switching back"):format(), 3)
                                break
                            end
                            task.wait(0.5)
                        end

                        FarmDodgeReady      = false
                        CurrentTarget       = nil
                        LockedPosition      = nil
                        Humanoid.AutoRotate = true
                        task.wait(0.3)
                    end

                    -- Restore FarmTargetName to primary before continuing.
                    FarmTargetName = sourceName
                    FarmDodgeReady = false
                    CurrentTarget  = nil
                    LockedPosition = nil
                    Humanoid.AutoRotate = true
                    continue
                end

                -- Normal primary-target kill path.
                local searchStart = tick()
                local enemy       = nil
                while tick() - searchStart < 15 do
                    enemy = GetFarmTarget()
                    if enemy then break end
                    task.wait(0.5)
                end

                if not enemy then
                    Notify("looking around...", ("can't spot a %s nearby, retrying"):format(sourceName), 4)
                    task.wait(3)
                    if tpOk then TeleportToEnemyIsland(sourceName) end
                    continue
                end

                TeleportToTarget(enemy)
                task.wait(0.5)
                if not IsActive and FarmActive then ActivateForFarm() end

                KillAndWait(enemy)

                FarmDodgeReady      = false
                CurrentTarget       = nil
                LockedPosition      = nil
                Humanoid.AutoRotate = true
                task.wait(0.5)
            end

            invCheckDone = true -- stop the background checker if loop exited naturally

            if FarmActive then
                Notify("cleared", ("got all the %s we needed, resetting"):format(matName), 4)
                SoftReset()
                TeleportToLocation("Portal Room")
                if FarmActive then ActivateForFarm() end
            end

        -- QUEST PATH
        elseif sourceType == "quest" then
            local ok = DoQuest(sourceName)
            if not ok then
                task.wait(3)
            end

        else
            FarmTargetName = nil; CurrentTarget = nil; FarmDodgeReady = false
            return false
        end

        task.wait(0.5)
    end

    FarmTargetName    = nil
    CurrentTarget     = nil
    FarmDodgeReady    = false
    CurrentSourceType = nil
    CurrentSourceName = nil
    return false
end

-- ============================================================
-- CRAFTING PHASE
-- ============================================================

local function CraftItem(itemName, qty)
    qty = math.max(1, math.floor(tonumber(qty) or 1))
    local ok, err = pcall(function()
        local args = {
            "Purchase",
            itemName,
            qty,
        }
        Workspace:WaitForChild("Remote"):WaitForChild("ProtectFunction"):InvokeServer(unpack(args))
    end)
    if not ok then
        warn(("[Craft] failed to craft %dx %s: %s"):format(qty, itemName, tostring(err)))
    end
    return ok
end

local function BuildCraftQueue(itemName, qty, inv)
    qty = math.max(1, math.floor(tonumber(qty) or 1))
    inv = inv or {}

    local simInv = {}
    for k, v in pairs(inv) do simInv[k] = v end

    local order   = {}
    local visited = {}

    local function Visit(name, needed)
        if visited[name] then return end
        visited[name] = true

        local recipe = CraftableItems[name]
        if not recipe then
            local have  = math.floor(simInv[name] or 0)
            local used  = math.min(have, needed)
            simInv[name] = have - used
            visited[name] = nil
            return
        end

        local have    = math.floor(simInv[name] or 0)
        local toCraft = math.max(0, needed - have)

        if toCraft > 0 then
            for ingredient, amount in pairs(recipe) do
                if ingredient ~= "GoldCost" and ingredient ~= "Tier" and ingredient ~= "Rarity" then
                    local amountNum = tonumber(amount)
                    if amountNum then
                        Visit(ingredient, amountNum * toCraft)
                    end
                end
            end

            table.insert(order, { name = name, qty = toCraft })

            simInv[name] = (simInv[name] or 0) + toCraft
        end

        local nowHave = math.floor(simInv[name] or 0)
        simInv[name]  = math.max(0, nowHave - needed)

        visited[name] = nil
    end

    Visit(itemName, qty)
    return order
end

local function RunCraftingPhase(itemName, qty)
    Notify("crafting time!", ("building %s x%d now"):format(itemName, qty), 5)

    TeleportToLocation("Portal Room")
    task.wait(1)

    local inv   = GetInventory()
    -- Zero out the target item so BuildCraftQueue always crafts it,
    -- even if the player already owns one (or more) of it.
    inv[itemName] = 0
    local queue = BuildCraftQueue(itemName, qty, inv)

    if #queue == 0 then
        Notify("nothing to craft?", "queue was empty � maybe you already have it!", 5)
        return
    end

    print(("[Craft] queue for %s x%d (%d steps):"):format(itemName, qty, #queue))
    for i, entry in ipairs(queue) do
        print(("  [%d] %dx %s"):format(i, entry.qty, entry.name))
    end

    for _, entry in ipairs(queue) do
        if entry.qty > 0 then
            Notify("crafting", ("%dx %s"):format(entry.qty, entry.name), 3)
            CraftItem(entry.name, entry.qty)
            task.wait(0.6)
        end
    end

    Notify("all done!", ("%s x%d crafted � enjoy!"):format(itemName, qty), 8)
end

-- ============================================================
-- RUN FARM
-- ============================================================
local function RunFarm(itemName)
    if not CraftableItems[itemName] then
        Notify("huh?", itemName .. " isn't a craftable item", 6)
        return
    end
    local skipped = {}  -- materials with no drop source, ignored for the rest of this run
    while FarmActive do
        if IsRespawning then task.wait(0.2); continue end
        local missing = GetMissingMaterials(itemName, TargetItemQty)
        -- Remove anything we've already decided to skip
        for mat in pairs(skipped) do missing[mat] = nil end
        local any = false
        for _ in pairs(missing) do any = true; break end
        if not any then
            Notify("ready to craft!", ("you have everything for %s x%d"):format(itemName, TargetItemQty), 5)
            FarmActive = false
            Deactivate()
            RunCraftingPhase(itemName, TargetItemQty)
            return
        end
        for mat, qty in pairs(missing) do
            if not FarmActive then return end
            local srcType, srcName = FindDropSource(mat)
            if srcType then
                FarmMaterial(mat, qty, srcType, srcName)
            elseif CraftableItems[mat] then
                -- craftable sub-item, resolved on next pass
            else
                Notify("skipping", "no drop source for: " .. mat .. ", moving on", 4)
                skipped[mat] = true
                missing[mat] = nil
            end
            break
        end
        task.wait(0.5)
    end
end

-- ============================================================
-- START / STOP FARM
-- ============================================================
local function StartFarm()
    if TargetItemName == "" then
        Notify("hold on", "pick a target item first", 4)
        return
    end
    if FarmActive then return end

    ActiveFromScratch = FarmFromScratch

    local missing = GetMissingMaterials(TargetItemName, TargetItemQty)
    local parts   = {}
    for mat, qty in pairs(missing) do
        table.insert(parts, qty .. "x " .. mat)
    end
    if #parts > 0 then
        local content = table.concat(parts, ", ")
        if #content > 90 then content = content:sub(1, 87) .. "..." end
        Notify("still need", content, 8)
    end

    FarmActive = true
    if not IsActive then ActivateForFarm() end
    task.spawn(function() RunFarm(TargetItemName) end)
    local modeLabel = ActiveFromScratch and " (from scratch)" or ""
    Notify("farm started", ("going for %s x%d%s"):format(TargetItemName, TargetItemQty, modeLabel), 5)
end

local function StopFarm()
    FarmActive        = false
    FarmTargetName    = nil
    CurrentTarget     = nil
    FarmDodgeReady    = false
    ActiveFromScratch = false
    IsEmergency       = false
    IsRespawning      = false
    CurrentSourceType = nil
    CurrentSourceName = nil
    StopAutoFire()
    Deactivate()
    Notify("farm stopped", "called it off, back to normal", 3)
end

-- ============================================================
-- TEXT PREDICTION HELPER
-- ============================================================
local function GetItemSuggestions(query)
    if query == "" then return {} end
    local lq = query:lower()
    local exact, startsWith, contains = {}, {}, {}
    for name in pairs(CraftableItems) do
        local ln = name:lower()
        if ln == lq then
            table.insert(exact, name)
        elseif ln:sub(1, #lq) == lq then
            table.insert(startsWith, name)
        elseif ln:find(lq, 1, true) then
            table.insert(contains, name)
        end
    end
    local results = {}
    for _, v in ipairs(exact)      do table.insert(results, v) end
    for _, v in ipairs(startsWith) do table.insert(results, v) end
    for _, v in ipairs(contains)   do table.insert(results, v) end
    local out = {}
    for i = 1, math.min(3, #results) do out[i] = results[i] end
    return out
end

-- ============================================================
-- AUTO FIRE SYSTEM
-- ============================================================
local WeaponStats = nil
local ok_ws, err_ws = pcall(function()
    WeaponStats = require(ReplicatedStorage:WaitForChild("WeaponStats", 5))
end)
if not ok_ws or not WeaponStats then
    warn("[AF] WeaponStats failed to load: " .. tostring(err_ws) .. " -- using hardcoded attack names")
end

local AutoFireActive       = false
local UseAbilities         = true  -- when false, only M1 is fired; Q/E/R/F abilities are skipped
local autoFireThreads      = {}
local StandaloneFireActive = false  -- true when the standalone "use all weapons" toggle is on

local function AF_GetCooldown(tool, default)
    local cd = tool:FindFirstChild("Cooldowns")
    if cd then
        local uc = cd:FindFirstChild("UniqueCooldown")
        if uc then return uc.Value end
    end
    return default or 0.5
end

local function AF_GetModes(tool)
    if WeaponStats and WeaponStats.WeaponStats[tool.Name] then
        local stats = WeaponStats.WeaponStats[tool.Name]
        if stats.Modes then
            local modes = {}
            for _, mode in ipairs(stats.Modes) do
                if mode[1] then
                    table.insert(modes, mode[1])
                end
            end
            return modes
        end
    end
    return nil
end

-- Cache of discovered M1 attack names, seeded with known weapons.
-- New weapons are auto-discovered at runtime and added here so the scan
-- only happens once per weapon per session.
local AF_AttackNameCache = {
    ["Abyssrender"]        = "Cleave",
    ["Crimson Deadeye"]    = "Deadshot",
    ["Pearl's OG Scythe"]  = "AttackM1",
    ["Judgement"]          = "Sinful Banish",
}

-- Scans a tool's LocalScript/ModuleScript constants using getconstants()
-- (executor API) to find the M1 attack name string. This avoids reading
-- .Source which executors block with a scheduler error.
local function AF_ScanScriptForAttackName(tool)
    if not getconstants then return nil end
    -- Known attack name suffixes/patterns to reject
    local rejectPatterns = { "^stop", "^Add", "^Remove", "^Play", "^Motor", "^Idle" }
    for _, obj in ipairs(tool:GetDescendants()) do
        if obj:IsA("LocalScript") or obj:IsA("ModuleScript") then
            local ok, consts = pcall(getconstants, obj)
            if ok and consts then
                -- Walk every string constant in the script bytecode.
                -- The M1 attack name will appear as a plain string constant,
                -- is typically 3-30 chars, starts with a capital letter,
                -- contains only letters/spaces, and is NOT a lifecycle keyword.
                for _, v in ipairs(consts) do
                    if type(v) == "string"
                        and #v >= 3 and #v <= 40
                        and v:match("^%u[%a%s]+$")  -- starts uppercase, letters+spaces only
                        and v ~= "stopAttack"
                    then
                        local rejected = false
                        for _, pat in ipairs(rejectPatterns) do
                            if v:find(pat) then rejected = true; break end
                        end
                        if not rejected then
                            return v
                        end
                    end
                end
            end
        end
    end
    return nil
end
local function AF_GetAttackName(tool)
    -- 1. Return cached result immediately (avoids re-scanning every cycle)
    if AF_AttackNameCache[tool.Name] then
        return AF_AttackNameCache[tool.Name]
    end

    -- 2. Tool attribute set at runtime (NewBoomSystem weapons)
    local fromAttr = tool:GetAttribute("M1")
        or tool:GetAttribute("Q")
        or tool:GetAttribute("E")
        or tool:GetAttribute("R")
    if fromAttr then
        AF_AttackNameCache[tool.Name] = fromAttr
        return fromAttr
    end

    -- 3. WeaponStats module
    if WeaponStats and WeaponStats.WeaponStats[tool.Name] then
        local stats = WeaponStats.WeaponStats[tool.Name]
        if stats.Modes and stats.Modes[1] and stats.Modes[1][1] then
            local name = stats.Modes[1][1]
            AF_AttackNameCache[tool.Name] = name
            return name
        end
    end

    -- 4. Configuration module inside the tool
    local cfg = tool:FindFirstChild("Configuration")
    if cfg then
        local ok, result = pcall(require, cfg)
        if ok and type(result) == "table" then
            local m1 = result.M1 or result.AttackM1 or result.Attack
            if m1 then
                AF_AttackNameCache[tool.Name] = m1
                return m1
            end
        end
    end

    -- 5. Scan script bytecode constants via getconstants() (executor API, no .Source needed)
    local scanned = AF_ScanScriptForAttackName(tool)
    if scanned then
        warn("[AF] '" .. tool.Name .. "' attack name auto-discovered: " .. scanned)
        AF_AttackNameCache[tool.Name] = scanned
        return scanned
    end

    -- 6. Give up - warn so the name can be added to the cache manually
    warn("[AF] Unknown attack name for '" .. tool.Name .. "' - add it to AF_AttackNameCache")
    AF_AttackNameCache[tool.Name] = "Slash"
    return "Slash"
end

local function AF_IsInCharacter(tool)
    -- Roblox only lets one tool be "held" at a time; the rest get moved back
    -- to Backpack automatically. Keep firing as long as the tool still belongs
    -- to this player in any capacity (character OR backpack).
    return tool.Parent == Character or tool.Parent == LocalPlayer.Backpack
end

-- Returns the current target's HumanoidRootPart position, or the player's
-- own position as a fallback. All weapon fire functions use this so attacks
-- are always aimed at the enemy rather than at the player's feet.
local function AF_GetAimPos()
    if CurrentTarget then
        local root = CurrentTarget:FindFirstChild("HumanoidRootPart")
        if root then return root.Position end
    end
    return RootPart.Position
end

-- Returns the current MouseBehavior name the same way the real client does,
-- so the server receives the value it actually expects.
local function AF_MouseBehavior()
    local ok, name = pcall(function()
        return game:GetService("UserInputService").MouseBehavior.Name
    end)
    return (ok and name) or "Default"
end

local function AF_FireWithRemote(remote, attackName, pos, includeMouseBehavior)
    remote:FireServer(
        { key = "M1", attack = attackName },
        { MouseBehavior = AF_MouseBehavior(), MousePos = vector.create(pos.X, pos.Y, pos.Z) }
    )
end

local function AF_StopWithRemote(remote, pos, includeMouseBehavior)
    remote:FireServer(
        { key = "M1", attack = "stopAttack" },
        { MouseBehavior = AF_MouseBehavior(), MousePos = vector.create(pos.X, pos.Y, pos.Z) }
    )
end

local function AF_UsePotion(tool)
    local remote = tool:FindFirstChildOfClass("RemoteEvent")
    if remote then
        AF_FireWithRemote(remote, AF_GetAttackName(tool), AF_GetAimPos())
    elseif tool:GetAttribute("nsystem") then
        local modes = AF_GetModes(tool)
        local mode = modes and modes[1] or nil
        InputEvent:FireServer(tool, mode, AF_GetAimPos())
    end
end

local function AF_StartPotionLoop(tool)
    task.spawn(function()
        AF_UsePotion(tool)
        while AutoFireActive and AF_IsInCharacter(tool) do
            task.wait(30.2)
            if not AutoFireActive or not AF_IsInCharacter(tool) then break end
            AF_UsePotion(tool)
        end
    end)
end

local function AF_FireMode(tool, remote, modeName, keybind)
    local pos = AF_GetAimPos()
    local mb  = AF_MouseBehavior()
    if remote then
        local attackName = tool:GetAttribute(keybind) or modeName
        remote:FireServer(
            { key = keybind, attack = attackName },
            { MouseBehavior = mb, MousePos = vector.create(pos.X, pos.Y, pos.Z) }
        )
        task.wait(0.05)
        local stopName = keybind == "M1" and "stopAttack" or ("stopAttack" .. keybind)
        remote:FireServer(
            { key = keybind, attack = stopName },
            { MouseBehavior = mb, MousePos = vector.create(pos.X, pos.Y, pos.Z) }
        )
    else
        InputEvent:FireServer(tool, modeName, pos)
        task.wait(0.05)
        InputEvent:FireServer(tool, modeName, pos, true)
    end
end

local AF_KeybindOrder = { "M1", "Q", "E", "R", "F" }

local function AF_StartTool(tool)
    if autoFireThreads[tool] then return end
    autoFireThreads[tool] = true

    if tool:FindFirstChild("Liquid") then
        AF_StartPotionLoop(tool)
    end

    -- -- The Galaxy's Embrace: uses its own ClickEvent remote ------------------
    if tool.Name == "The Galaxy's Embrace" then
        local clickEvent = tool:FindFirstChild("ClickEvent")
        if not clickEvent then
            autoFireThreads[tool] = nil
            return
        end
        task.spawn(function()
            while AutoFireActive and AF_IsInCharacter(tool) do
                if not StandaloneFireActive then
                    if not IsTargetAlive(CurrentTarget) or not FarmDodgeReady then
                        task.wait(0.1)
                        continue
                    end
                end
                if tool.Parent ~= Character then
                    tool.Parent = Character
                    task.wait(0.05)
                end
                local pos = AF_GetAimPos()
                pcall(function()
                    clickEvent:FireServer(
                        Vector3.new(pos.X, pos.Y, pos.Z),
                        "attack1"
                    )
                end)
                local cd = AF_GetCooldown(tool, 0.5)
                task.wait(cd)
            end
            autoFireThreads[tool] = nil
        end)
        return
    end
    -- -------------------------------------------------------------------------

    task.spawn(function()
        local isNewBoom = tool:GetAttribute("NewBoomSystem") ~= nil
        local isNsystem = tool:GetAttribute("nsystem")
        local remote    = tool:FindFirstChild("AttackEvent")
                       or tool:FindFirstChild("Event")
                       or (isNewBoom and tool:FindFirstChildOfClass("RemoteEvent"))
                       or nil

        -- DEBUG
        print(("[AF] '"..tool.Name.."' isNewBoom="..tostring(isNewBoom).." isNsystem="..tostring(isNsystem).." remote="..tostring(remote and remote.Name or "NIL")))
        for _, c in ipairs(tool:GetChildren()) do
            if c:IsA("RemoteEvent") then print(("[AF]   child remote: "..c.Name)) end
        end

        if not remote and not isNsystem then
            print(("[AF] SKIP '"..tool.Name.."' - no remote and not nsystem"))
            autoFireThreads[tool] = nil
            return
        end

        local modes = AF_GetModes(tool)
        print(("[AF] '"..tool.Name.."' modes="..(modes and #modes or 0).." attackName="..AF_GetAttackName(tool)))

        while AutoFireActive and AF_IsInCharacter(tool) do
            -- In standalone mode we fire immediately without needing a farm target.
            -- In farm/dodge mode we wait until we are positioned at a live target.
            if not StandaloneFireActive then
                if not IsTargetAlive(CurrentTarget) or not FarmDodgeReady then
                    task.wait(0.1)
                    continue
                end
            end

            local cd = AF_GetCooldown(tool, 0.5)

            -- Always make sure the tool is in the character before firing;
            -- Roblox moves it back to Backpack when another tool is equipped.
            if tool.Parent ~= Character then
                tool.Parent = Character
                task.wait(0.05)
            end

            if remote then
                local pos = AF_GetAimPos()
                local attackName = AF_GetAttackName(tool)
                print(("[AF] FIRE '"..tool.Name.."' attack='"..attackName.."' remote='"..remote.Name.."' pos="..tostring(pos)))
                AF_FireWithRemote(remote, attackName, pos, isNewBoom)
                task.wait(0.05)
                AF_StopWithRemote(remote, AF_GetAimPos(), isNewBoom)

                -- Only fire abilities for true NewBoomSystem weapons.
                -- Custom-script weapons use non-standard keybinds (Z/X/C etc.)
                -- that we can't generically replicate, so we skip them.
                if isNewBoom and UseAbilities and modes then
                    for i = 2, #modes do
                        if not AutoFireActive or not AF_IsInCharacter(tool) then break end
                        local keybind = AF_KeybindOrder[i]
                        if keybind and tool:GetAttribute(keybind) then
                            AF_FireMode(tool, remote, modes[i], keybind)
                        end
                    end
                end

            elseif isNsystem then
                -- M1 start, tiny gap, then stop
                local pos = AF_GetAimPos()
                if modes and modes[1] then
                    InputEvent:FireServer(tool, modes[1], pos)
                else
                    InputEvent:FireServer(tool, nil, pos)
                end
                task.wait(0.05)
                if modes and modes[1] then
                    InputEvent:FireServer(tool, modes[1], pos, true)
                else
                    InputEvent:FireServer(tool, nil, pos, true)
                end

                -- Fire abilities back-to-back immediately after M1
                if UseAbilities and modes then
                    for i = 2, #modes do
                        if not AutoFireActive or not AF_IsInCharacter(tool) then break end
                        AF_FireMode(tool, nil, modes[i], AF_KeybindOrder[i])
                    end
                end
            end

            -- Only wait the cooldown once per full attack cycle
            task.wait(cd)
        end

        -- cleanup stop signals
        if remote then
            AF_StopWithRemote(remote, AF_GetAimPos(), isNewBoom)
            if isNewBoom and modes then
                for i = 2, #modes do
                    local keybind = AF_KeybindOrder[i]
                    if keybind then
                        local stopName = "stopAttack" .. keybind
                        local p = AF_GetAimPos()
                        local mb = AF_MouseBehavior()
                        remote:FireServer(
                            { key = keybind, attack = stopName },
                            { MouseBehavior = mb, MousePos = vector.create(p.X, p.Y, p.Z) }
                        )
                    end
                end
            end
        elseif isNsystem and modes then
            for i = 1, #modes do
                InputEvent:FireServer(tool, modes[i], AF_GetAimPos(), true)
            end
        end

        autoFireThreads[tool] = nil
    end)
end

-- Equip every backpack item by moving it into the character, then start firing.
StartAutoFire = function()
    if AutoFireActive then return end
    AutoFireActive = true
    autoFireThreads = {}

    print("[AF] StartAutoFire called")
    for _, tool in ipairs(LocalPlayer.Backpack:GetChildren()) do
        if tool:IsA("Tool") then
            print("[AF] equipping from backpack: "..tool.Name)
            tool.Parent = Character
        end
    end

    for _, tool in ipairs(Character:GetChildren()) do
        if tool:IsA("Tool") then
            print("[AF] starting tool: "..tool.Name)
            AF_StartTool(tool)
        end
    end

    local conn
    conn = Character.ChildAdded:Connect(function(child)
        if AutoFireActive and child:IsA("Tool") then
            AF_StartTool(child)
        end
    end)
    autoFireThreads["__conn"] = conn
end

StopAutoFire = function()
    if not AutoFireActive then return end
    AutoFireActive = false
    if autoFireThreads["__conn"] then
        autoFireThreads["__conn"]:Disconnect()
    end
    autoFireThreads = {}
end

-- ============================================================
-- STANDALONE FIRE (no farming, just use all weapons)
-- ============================================================
local function StartStandaloneFire()
    if StandaloneFireActive then return end
    StandaloneFireActive = true
    StartAutoFire()
    Notify("weapons active", "firing all weapons", 3)
end

local function StopStandaloneFire()
    if not StandaloneFireActive then return end
    StandaloneFireActive = false
    -- Only stop AutoFire if farming isn't also running
    if not FarmActive and not EnemyFarmActive and not IsActive then
        StopAutoFire()
    end
    Notify("weapons stopped", "all weapons holstered", 3)
end

-- ============================================================
-- HEALTH MONITOR
-- ============================================================
local HealthMonitorConn = nil

local function StopHealthMonitor()
    if HealthMonitorConn then
        HealthMonitorConn:Disconnect()
        HealthMonitorConn = nil
    end
end

local function StartHealthMonitor()
    StopHealthMonitor()
    HealthMonitorConn = Humanoid.HealthChanged:Connect(function(newHealth)
        if IsEmergency then return end
        if not (IsActive or FarmActive or EnemyFarmActive) then return end
        local maxHp = Humanoid.MaxHealth
        if maxHp <= 0 then return end
        if newHealth / maxHp < 0.30 then
            -- Set flag immediately so target loops stop overwriting LockedPosition
            IsEmergency = true
            -- Do the actual flee work in a separate thread so this callback
            -- never yields (avoiding signal-callback re-entrancy issues)
            task.spawn(function()
                Notify("low health!", "fleeing upward to heal", 4)

                -- Save the position we fled from so we can return after healing
                local returnPos = LockedPosition or RootPart.Position

                -- Initial burst: jump 150 studs immediately for quick safety
                local burstPos = RootPart.Position + Vector3.new(0, 150, 0)
                LockedPosition = burstPos
                RootPart.CFrame = CFrame.new(burstPos)
                RootPart.AssemblyLinearVelocity  = Vector3.zero
                RootPart.AssemblyAngularVelocity = Vector3.zero
                task.wait(0.5)

                -- Then climb 20 studs every 0.5s until health recovers to 85%.
                -- Moving continuously means attacks can't track a stationary target.
                while IsEmergency and (IsActive or FarmActive or EnemyFarmActive) do
                    if (Humanoid.Health / Humanoid.MaxHealth) >= 0.85 then
                        break
                    end
                    local nextPos = RootPart.Position + Vector3.new(0, 100, 0)
                    LockedPosition = nextPos
                    RootPart.CFrame = CFrame.new(nextPos)
                    RootPart.AssemblyLinearVelocity  = Vector3.zero
                    RootPart.AssemblyAngularVelocity = Vector3.zero
                    task.wait(0.5)
                end

                IsEmergency = false

                if IsActive or FarmActive or EnemyFarmActive then
                    Notify("health ok", "teleporting back to fight", 3)
                    -- Return to the pre-flee position so targeting resumes correctly
                    LockedPosition = returnPos
                    RootPart.CFrame = CFrame.new(returnPos)
                    RootPart.AssemblyLinearVelocity  = Vector3.zero
                    RootPart.AssemblyAngularVelocity = Vector3.zero
                end
            end)
        end
    end)
end

-- ============================================================
-- RESPAWN
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(newChar)
    -- Snapshot which toggles were on BEFORE we clear any state
    local wasDodgeActive     = IsActive
    local wasFarmActive      = FarmActive
    local wasEnemyFarmActive = EnemyFarmActive
    local wasStandalone      = StandaloneFireActive

    -- Halt all loops immediately so they don't use stale refs
    IsRespawning = true
    IsEmergency  = false
    StopHealthMonitor()
    StopRenderLock()

    -- Update character refs as soon as the new body parts exist
    Character = newChar
    RootPart  = newChar:WaitForChild("HumanoidRootPart")
    Humanoid  = newChar:WaitForChild("Humanoid")

    -- If no toggle was on there's nothing to resume
    if not wasDodgeActive and not wasFarmActive and not wasEnemyFarmActive and not wasStandalone then
        IsRespawning = false
        StartHealthMonitor()
        return
    end

    -- Wait for the character to fully load and for Roblox to place it
    -- at the correct spawn position before we do anything
    task.wait(2)

    -- Clean up any leftover state from before death
    IsActive       = false
    FarmDodgeReady = false
    IsDodging      = false
    LockedPosition = nil
    CurrentTarget  = nil
    for _, c in ipairs(Connections) do c:Disconnect() end; Connections = {}
    for b in pairs(BulletData) do UnregisterBullet(b) end; BulletData = {}
    if SafeZoneVisual then SafeZoneVisual:Destroy(); SafeZoneVisual = nil end

    -- Restart autofire with the new character's tools
    StopAutoFire()
    task.wait(0.5)
    StartAutoFire()

    -- Teleport back to wherever we were farming before death
    if CurrentSourceType == "enemy" then
        Notify("respawned", "heading back to " .. tostring(CurrentSourceName), 4)
        TeleportToEnemyIsland(CurrentSourceName)
        task.wait(1)
    elseif CurrentSourceType == "boss" then
        Notify("respawned", "heading back to boss fight", 4)
        TeleportToLocation("Portal Room")
        task.wait(1)
    elseif wasFarmActive or wasEnemyFarmActive then
        TeleportToLocation("Portal Room")
        task.wait(1)
    end

    -- Re-activate the appropriate systems based on what was on before death
    if wasFarmActive or wasEnemyFarmActive then
        ActivateForFarm()
    elseif wasDodgeActive then
        -- Pure auto-dodge was on: restart it directly
        Activate()
    end

    -- Only now let the farm loops proceed
    IsRespawning = false

    StartHealthMonitor()
end)

-- Start the health monitor for the initial character load
StartHealthMonitor()

-- ============================================================
-- ENEMY FARM
-- ============================================================
local function StartEnemyFarm()
    if EnemyFarmTargetName == "" then
        Notify("hold on", "type an enemy name first", 4)
        return
    end
    if EnemyFarmActive then return end
    EnemyFarmActive = true
    FarmTargetName  = EnemyFarmTargetName

    -- Determine if the target is a boss or a regular enemy.
    local isBoss = BossDropTables[EnemyFarmTargetName] ~= nil or BossLocations[EnemyFarmTargetName] ~= nil

    -- For regular enemies, find all enemies that share the same island.
    -- This lets us kill any available mob on that island rather than waiting
    -- for one specific name to respawn.
    local coGroup = {}
    if not isBoss then
        coGroup = GetCoLocationEnemies(EnemyFarmTargetName)
        FarmTargetName = coGroup
        if #coGroup > 1 then
            local names = table.concat(coGroup, ", ")
            Notify("co-location group", ("targeting %d enemies: %s"):format(#coGroup, #names > 80 and names:sub(1,77).."..." or names), 6)
        end
    else
        FarmTargetName = EnemyFarmTargetName
    end

    Notify("enemy farm started", "killing " .. EnemyFarmTargetName .. " repeatedly", 4)

    -- Boot up the same dodge/render infrastructure used by AutoFarm
    if not IsActive then ActivateForFarm() end

    task.spawn(function()
        while EnemyFarmActive do
            FarmDodgeReady      = false
            CurrentTarget       = nil
            LockedPosition      = nil
            Humanoid.AutoRotate = true

            -- ------------------------------------------------
            -- BOSS PATH
            -- ------------------------------------------------
            if isBoss then
                local ok = StartBossFight(EnemyFarmTargetName)
                if not ok then task.wait(3); continue end

                local boss = WaitForBoss(EnemyFarmTargetName, 30)
                if not boss then task.wait(3); continue end

                -- Set CurrentTarget BEFORE activating so StartFarmTargetLoop
                -- picks it up and drives the safe-zone tracking automatically.
                TeleportToTarget(boss)
                task.wait(0.5)
                if not IsActive and EnemyFarmActive then ActivateForFarm() end

                local dead = KillAndWait(boss, function()
                    FarmDodgeReady      = false
                    CurrentTarget       = nil
                    LockedPosition      = nil
                    Humanoid.AutoRotate = true
                end)
                FarmDodgeReady      = false
                CurrentTarget       = nil
                LockedPosition      = nil
                Humanoid.AutoRotate = true

                if dead then
                    ReturnAfterBoss(EnemyFarmTargetName)
                    SoftReset()
                    local tool = LocalPlayer.Backpack:FindFirstChild("Solar Beacon")
                    if tool then tool.Parent = Workspace[LocalPlayer.Name] end
                    if EnemyFarmActive then ActivateForFarm() end
                end
                task.wait(1)

            -- ------------------------------------------------
            -- REGULAR ENEMY PATH
            -- ------------------------------------------------
            else
                -- Teleport using the primary enemy's island (all co-located
                -- enemies share it, so one teleport covers the whole group).
                local tpOk = TeleportToEnemyIsland(EnemyFarmTargetName)
                if not tpOk then
                    warn(("[EnemyFarm] no island for '%s', attempting anyway"):format(EnemyFarmTargetName))
                end

                local searchStart = tick()
                local enemy = nil
                while tick() - searchStart < 15 do
                    enemy = GetFarmTarget()
                    if enemy then break end
                    task.wait(0.5)
                end

                if not enemy then
                    Notify("looking...", ("can't find any target, reteleporting"):format(EnemyFarmTargetName), 3)
                    task.wait(2)
                    continue
                end

                -- Set CurrentTarget BEFORE activating so StartFarmTargetLoop
                -- picks it up and drives the safe-zone tracking automatically.
                TeleportToTarget(enemy)
                task.wait(0.5)
                if not IsActive and EnemyFarmActive then ActivateForFarm() end

                KillAndWait(enemy)

                FarmDodgeReady      = false
                CurrentTarget       = nil
                LockedPosition      = nil
                Humanoid.AutoRotate = true
                task.wait(0.5)
            end
        end

        FarmTargetName = nil
    end)
end

local function StopEnemyFarm()
    EnemyFarmActive     = false
    FarmTargetName      = nil
    CurrentTarget       = nil
    FarmDodgeReady      = false
    IsEmergency         = false
    IsRespawning        = false
    CurrentSourceType   = nil
    CurrentSourceName   = nil
    Humanoid.AutoRotate = true
    StopAutoFire()
    Deactivate()
    Notify("enemy farm stopped", "back to normal", 3)
end


local Window = Rayfield:CreateWindow({
    Name                = "destined laziness",
    LoadingTitle        = "hang on...",
    LoadingSubtitle     = "getting things ready",
    ConfigurationSaving = { Enabled = false },
    Discord             = { Enabled = false },
    KeySystem           = false,
})

-- ---- DODGE TAB ----
local DodgeTab = Window:CreateTab("AutoDodge", 4483362458)

DodgeTab:CreateToggle({
    Name = "use all weapons", CurrentValue = false, Flag = "StandaloneFireToggle",
    Callback = function(v) if v then StartStandaloneFire() else StopStandaloneFire() end end
})

DodgeTab:CreateDivider()

DodgeTab:CreateToggle({
    Name = "lock onto nearest enemy", CurrentValue = false, Flag = "DodgeToggle",
    Callback = function(v) if v then Activate() else Deactivate() end end
})

DodgeTab:CreateDivider()

DodgeTab:CreateSlider({
    Name = "safe zone width", Range = {10, 200}, Increment = 1,
    CurrentValue = Config.SafeZoneWidth, Flag = "SafeZoneWidth",
    Callback = function(v)
        Config.SafeZoneWidth = v
        RefreshSafeZoneVisual()
    end
})

DodgeTab:CreateSlider({
    Name = "safe zone height", Range = {5, 100}, Increment = 1,
    CurrentValue = Config.SafeZoneHeight, Flag = "SafeZoneHeight",
    Callback = function(v)
        Config.SafeZoneHeight = v
        RefreshSafeZoneVisual()
    end
})

DodgeTab:CreateSlider({
    Name = "safe zone depth", Range = {10, 200}, Increment = 1,
    CurrentValue = Config.SafeZoneDepth, Flag = "SafeZoneDepth",
    Callback = function(v)
        Config.SafeZoneDepth = v
        RefreshSafeZoneVisual()
    end
})

DodgeTab:CreateSlider({
    Name = "safe zone y offset", Range = {0, 50}, Increment = 1,
    CurrentValue = Config.SafeZoneYOffset, Flag = "SafeZoneYOffset",
    Callback = function(v)
        Config.SafeZoneYOffset = v
        UpdateSafeZoneCenter()
        RefreshSafeZoneVisual()
    end
})

-- ---- FARM TAB ----
local FarmTab = Window:CreateTab("AutoFarm", 4483362458)

local ItemInput = FarmTab:CreateInput({
    Name = "target item", CurrentValue = "", PlaceholderText = "e.g. Fury Ruler Sword", NumbersOnly = false,
    Callback = function(v)
        TargetItemName = v
        if v == "" then return end
        if CraftableItems[v] then
            Notify("item locked in", v, 3)
        else
            local suggestions = GetItemSuggestions(v)
            if #suggestions > 0 then
                Notify("did you mean?", table.concat(suggestions, "\n"), 6)
            else
                Notify("not found", v .. " isn't in the crafting list", 5)
            end
        end
    end
})

FarmTab:CreateInput({
    Name = "how many?", CurrentValue = "1", PlaceholderText = "1", NumbersOnly = true,
    Callback = function(v)
        local n = math.floor(tonumber(v) or 1)
        TargetItemQty = math.max(1, n)
        if TargetItemName ~= "" then
            Notify("quantity set", TargetItemName .. " x" .. TargetItemQty, 3)
        end
    end
})

FarmTab:CreateDivider()

FarmTab:CreateToggle({
    Name = "use abilities (Q/E/R/F)", CurrentValue = true, Flag = "UseAbilitiesToggle",
    Callback = function(v) UseAbilities = v end
})

FarmTab:CreateToggle({
    Name = "start autofarm", CurrentValue = false, Flag = "FarmToggle",
    Callback = function(v) if v then StartFarm() else StopFarm() end end
})

FarmTab:CreateToggle({
    Name = "farm from scratch (ignore existing inventory)", CurrentValue = false, Flag = "FarmFromScratchToggle",
    Callback = function(v)
        FarmFromScratch = v
        if v then
            Notify("from scratch", "ignoring everything in your inventory", 3)
        else
            Notify("using inventory", "existing materials will count toward the goal", 3)
        end
    end
})

FarmTab:CreateDivider()

FarmTab:CreateButton({ Name = "what am I missing?", Callback = function()
    if TargetItemName == "" then
        Notify("no item selected", "type a target item first", 3); return
    end
    local missing = GetMissingMaterials(TargetItemName, TargetItemQty)
    local parts, any = {}, false
    for mat, qty in pairs(missing) do
        table.insert(parts, qty .. "x " .. mat)
        any = true
    end
    if not any then
        Notify("you're good!", "got everything for " .. TargetItemName, 4)
    else
        local content = table.concat(parts, ", ")
        if #content > 90 then content = content:sub(1, 87) .. "..." end
        Notify("still missing", content, 8)
    end
end })

FarmTab:CreateButton({ Name = "print full crafting tree", Callback = function()
    if TargetItemName == "" then warn("[Farm] no item selected"); return end
    local tree = ResolveCraftingTree(TargetItemName)
    print("[Farm] full tree for: " .. TargetItemName)
    for mat, qty in pairs(tree) do print(("  %dx %s"):format(qty, mat)) end
end })

FarmTab:CreateButton({ Name = "print my inventory", Callback = function()
    local inv   = GetInventory()
    local count = 0
    for name, amt in pairs(inv) do
        print(("[Inv] %s x%d"):format(name, amt))
        count = count + 1
    end
    Notify("inventory", count .. " unique items found", 4)
end })

FarmTab:CreateButton({ Name = "craft now (skip farming)", Callback = function()
    if TargetItemName == "" then
        Notify("no item selected", "type a target item first", 3); return
    end
    task.spawn(function()
        RunCraftingPhase(TargetItemName, TargetItemQty)
    end)
end })

FarmTab:CreateDivider()

FarmTab:CreateInput({
    Name = "enemy to farm", CurrentValue = "", PlaceholderText = "e.g. Fury Destructive Overlord", NumbersOnly = false,
    Callback = function(v)
        EnemyFarmTargetName = v
        if v ~= "" then
            Notify("enemy set", "will farm: " .. v, 3)
        end
    end
})

FarmTab:CreateToggle({
    Name = "autofarm enemy", CurrentValue = false, Flag = "EnemyFarmToggle",
    Callback = function(v) if v then StartEnemyFarm() else StopEnemyFarm() end end
})

Rayfield:OnUnload(function()
    StopFarm()
    StopEnemyFarm()
    StopStandaloneFire()
    Deactivate()
    if VisualFolder and VisualFolder.Parent then VisualFolder:Destroy() end
end)

print("[autofarm] loaded � good luck out there")
