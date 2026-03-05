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
local IsEmergency    = false
local IsRespawning   = false

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
local CurrentSourceType    = nil
local CurrentSourceName    = nil

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
    local refPos = RootPart.Position
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

local function FindSafePosition()
    local function IsClear(pos)
        for bullet in pairs(BulletData) do
            if bullet.Parent and IsPointInBullet(pos, bullet) then return false end
        end
        return true
    end
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
    if not IsActive or IsDodging or IsEmergency then return end
    if FarmActive and not FarmDodgeReady then return end
    if EnemyFarmActive and not FarmDodgeReady then return end
    IsDodging = true
    local checkPos = LockedPosition or RootPart.Position
    if IsInUnsafeRegion(checkPos) or not IsInsideSafeZone(checkPos) then
        local safe = FindSafePosition()
        if safe then MoveTo(safe) end
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
        local lockPos = LockedPosition or RootPart.Position
        RootPart.AssemblyLinearVelocity  = Vector3.zero
        RootPart.AssemblyAngularVelocity = Vector3.zero
        if IsEmergency then
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
    task.wait(0.5)
    return ok
end

local function TeleportToEnemyIsland(enemyName)
    local islandName = EnemyLocations[enemyName]

    if islandName == nil then
        local msg = ("no island mapped for '%s' — skipping teleport"):format(enemyName)
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

    if islandName == "Void Mines" then
        Notify("void mines", "heading to Evil Island first", 4)
        TeleportToLocation("Evil Island")
        task.wait(2)
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

    task.wait(0.5)
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
        task.wait(2)
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
-- SOFT RESET
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
                        UpdateSafeZoneCenter()
                        LockedPosition  = SafeZoneCenter
                        RootPart.CFrame = CFrame.new(SafeZoneCenter)
                        Humanoid.AutoRotate = false
                    end
                else
                    UpdateSafeZoneCenter()
                    LockedPosition = SafeZoneCenter
                end
                if SafeZoneVisual then
                    SafeZoneVisual.Size   = Vector3.new(Config.SafeZoneWidth, Config.SafeZoneHeight, Config.SafeZoneDepth)
                    SafeZoneVisual.CFrame = CFrame.new(SafeZoneCenter)
                end
            end
            task.wait(0.05)
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
    LockedPosition = RootPart.Position
    RefreshSafeZoneVisual()
    FreezePlayer()
    StartRenderLock()
    WatchBulletsFolder()
    StartDodgeTargetLoop()
    StartDodgeLoop()
end

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
        task.wait(1.5)
    end

    local button = pad:FindFirstChild("Button")
    if not button then return false end

    local cd = button:FindFirstChild("ClickDetector")
    if not cd then return false end

    Notify("heading in", "starting fight with " .. bossName, 4)
    fireclickdetector(cd)
    task.wait(3)
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
local GOLD_FARM_BOSS  = "Alpha Destructive Overlord"

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

    if goldRequired > 0 and goldEarned < goldRequired then
        local stillNeed = goldRequired - goldEarned
        local goldBoss, goldPerBossKill, killsNeeded = FindBestGoldBoss(stillNeed)
        if not goldBoss then
            Notify("gold farming", ("need %d more gold but no suitable boss found"):format(stillNeed), 5)
        else
            Notify("gold farming", ("need %d more gold — killing %dx %s (%d/kill)"):format(
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
        if IsRespawning then task.wait(0.2); continue end

        local inv    = GetInventory()
        local gained = math.max(0, (inv[matName] or 0) - startHave)

        if gained >= needed then
            Notify("got it", ("+%dx %s — moving on"):format(gained, matName), 5)
            FarmTargetName    = nil
            CurrentTarget     = nil
            FarmDodgeReady    = false
            CurrentSourceType = nil
            CurrentSourceName = nil
            return true
        end

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
                if tool then tool.Parent = Workspace[LocalPlayer.Name] end
                if FarmActive then ActivateForFarm() end
            end
            task.wait(1)

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
                    if alpha >= 1 then stepConn:Disconnect() end
                end)
                while stepConn.Connected do task.wait(0.05) end
            end

            local invCheckDone = false
            local lastInvCheck = tick()
            task.spawn(function()
                while FarmActive and not invCheckDone do
                    task.wait(15)
                    if not FarmActive or invCheckDone then break end
                    local freshInv    = GetInventory()
                    local freshGained = math.max(0, (freshInv[matName] or 0) - startHave)
                    if freshGained >= needed then
                        Notify("got it", ("+%dx %s — moving on"):format(freshGained, matName), 5)
                        invCheckDone = true
                    else
                        local stillNeed = needed - freshGained
                        Notify("inventory check", ("have %d/%d %s, still need %d"):format(
                            freshGained, needed, matName, stillNeed), 4)
                    end
                    lastInvCheck = tick()
                end
            end)

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

                local primaryUp = PrimaryTargetExists(sourceName)

                if not primaryUp and hasFillers then
                    FarmTargetName = coLocationGroup
                    Notify("filling time", ("no %s up — farming co-location mobs"):format(sourceName), 3)

                    while FarmActive and not invCheckDone do
                        if PrimaryTargetExists(sourceName) then
                            Notify("primary spawned", sourceName .. " is up — switching back", 3)
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

                        local fillerDead = false
                        task.spawn(function()
                            KillAndWait(fillerEnemy)
                            fillerDead = true
                        end)
                        while not fillerDead and FarmActive do
                            if PrimaryTargetExists(sourceName) then
                                Notify("primary spawned", sourceName .. " is up — switching back", 3)
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

                    FarmTargetName = sourceName
                    FarmDodgeReady = false
                    CurrentTarget  = nil
                    LockedPosition = nil
                    Humanoid.AutoRotate = true
                    continue
                end

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

            invCheckDone = true

            if FarmActive then
                Notify("cleared", ("got all the %s we needed, resetting"):format(matName), 4)
                SoftReset()
                TeleportToLocation("Portal Room")
                if FarmActive then ActivateForFarm() end
            end

        elseif sourceType == "quest" then
            local ok = DoQuest(sourceName)
            if not ok then task.wait(3) end

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
        local args = { "Purchase", itemName, qty }
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
            local have = math.floor(simInv[name] or 0)
            local used = math.min(have, needed)
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

    local inv = GetInventory()
    inv[itemName] = 0
    local queue = BuildCraftQueue(itemName, qty, inv)

    if #queue == 0 then
        Notify("nothing to craft?", "queue was empty — maybe you already have it!", 5)
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

    Notify("all done!", ("%s x%d crafted — enjoy!"):format(itemName, qty), 8)
end

-- ============================================================
-- RUN FARM
-- ============================================================
local function RunFarm(itemName)
    if not CraftableItems[itemName] then
        Notify("huh?", itemName .. " isn't a craftable item", 6)
        return
    end
    local skipped = {}
    while FarmActive do
        if IsRespawning then task.wait(0.2); continue end
        local missing = GetMissingMaterials(itemName, TargetItemQty)
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
-- PREDICTIVE TEXT HELPERS
-- ============================================================
local function GetAllCraftableNames()
    local names = {}
    for name in pairs(CraftableItems) do
        table.insert(names, name)
    end
    return names
end

local function GetAllEnemyNames()
    local names = {}
    local seen  = {}
    for name in pairs(EnemyDropTables) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for name in pairs(BossDropTables) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for name in pairs(BossLocations) do
        if not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    return names
end

-- Returns the single best prediction for a typed query against a name list.
-- Returns nil if the query is empty, already an exact match, or no match exists.
local function GetBestPrediction(query, nameList)
    if query == "" then return nil end
    local lq = query:lower()
    -- Exact match — don't try to predict further
    for _, name in ipairs(nameList) do
        if name:lower() == lq then return nil end
    end
    -- Prefer names whose lowercase form starts with the query
    for _, name in ipairs(nameList) do
        if name:lower():sub(1, #lq) == lq then return name end
    end
    -- Fall back to substring match
    for _, name in ipairs(nameList) do
        if name:lower():find(lq, 1, true) then return name end
    end
    return nil
end

-- ============================================================
-- PREDICTIVE INPUT BUILDER
-- ============================================================
-- Creates a styled input frame with a ghost-text prediction label inside a
-- given parent Frame.  nameListFn is called once to build the completion list.
-- onConfirm(text) is called when the user presses Enter or clicks away with text.
local function CreatePredictiveInput(parent, placeholderText, nameListFn, onConfirm)
    local nameList = nameListFn()

    -- Outer container
    local container = Instance.new("Frame")
    container.Name              = "PredictiveInput_" .. placeholderText
    container.Size              = UDim2.new(1, -16, 0, 36)
    container.Position          = UDim2.new(0, 8, 0, 0)
    container.BackgroundColor3  = Color3.fromRGB(40, 40, 40)
    container.BorderSizePixel   = 0
    container.ClipsDescendants  = true
    container.Parent            = parent
    Instance.new("UICorner", container).CornerRadius = UDim.new(0, 6)

    -- Ghost label (shows full predicted name in gray)
    local ghostLabel = Instance.new("TextLabel")
    ghostLabel.Name                   = "Ghost"
    ghostLabel.Size                   = UDim2.new(1, -10, 1, 0)
    ghostLabel.Position               = UDim2.new(0, 10, 0, 0)
    ghostLabel.BackgroundTransparency = 1
    ghostLabel.TextColor3             = Color3.fromRGB(110, 110, 110)
    ghostLabel.TextSize               = 14
    ghostLabel.Font                   = Enum.Font.GothamMedium
    ghostLabel.Text                   = ""
    ghostLabel.TextXAlignment         = Enum.TextXAlignment.Left
    ghostLabel.TextTruncate           = Enum.TextTruncate.AtEnd
    ghostLabel.ZIndex                 = 2
    ghostLabel.Parent                 = container

    -- Actual TextBox on top
    local textBox = Instance.new("TextBox")
    textBox.Name                   = "Input"
    textBox.Size                   = UDim2.new(1, -10, 1, 0)
    textBox.Position               = UDim2.new(0, 10, 0, 0)
    textBox.BackgroundTransparency = 1
    textBox.TextColor3             = Color3.fromRGB(255, 255, 255)
    textBox.PlaceholderText        = placeholderText
    textBox.PlaceholderColor3      = Color3.fromRGB(100, 100, 100)
    textBox.TextSize               = 14
    textBox.Font                   = Enum.Font.GothamMedium
    textBox.Text                   = ""
    textBox.ClearTextOnFocus       = false
    textBox.TextXAlignment         = Enum.TextXAlignment.Left
    textBox.TextTruncate           = Enum.TextTruncate.AtEnd
    textBox.ZIndex                 = 3
    textBox.BackgroundColor3       = Color3.fromRGB(0, 0, 0)  -- needed for transparency
    textBox.Parent                 = container

    local currentPrediction = nil

    local function UpdateGhost(typed)
        currentPrediction = GetBestPrediction(typed, nameList)
        if currentPrediction and typed ~= "" then
            ghostLabel.Text = currentPrediction
        else
            ghostLabel.Text = ""
        end
    end

    local function Confirm(text)
        local trimmed = text:match("^%s*(.-)%s*$")
        if trimmed == "" then return end
        textBox.Text    = trimmed
        ghostLabel.Text = ""
        onConfirm(trimmed)
    end

    -- Update ghost every time the typed text changes
    textBox:GetPropertyChangedSignal("Text"):Connect(function()
        UpdateGhost(textBox.Text)
    end)

    -- Enter key: autocomplete if there's a prediction, otherwise confirm as-is
    textBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            if currentPrediction and textBox.Text ~= "" then
                -- Only autocomplete if the typed text isn't already the full name
                if textBox.Text:lower() ~= currentPrediction:lower() then
                    textBox.Text = currentPrediction
                end
            end
            Confirm(textBox.Text)
        end
        ghostLabel.Text = currentPrediction and textBox.Text ~= "" and currentPrediction or ""
    end)

    return container, textBox
end

-- ============================================================
-- AUTO FIRE SYSTEM
-- ============================================================
local WeaponStats = nil
pcall(function()
    WeaponStats = require(ReplicatedStorage:WaitForChild("WeaponStats"))
end)

local AutoFireActive  = false
local UseAbilities    = true
local autoFireThreads = {}

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

local function AF_GetAttackName(tool)
    return tool:GetAttribute("M1")
        or tool:GetAttribute("Q")
        or tool:GetAttribute("E")
        or tool:GetAttribute("R")
        or "Slash"
end

local function AF_IsInCharacter(tool)
    return tool.Parent == Character
end

local function AF_FireWithRemote(remote, attackName, pos)
    remote:FireServer(
        { key = "M1", attack = attackName },
        { MouseBehavior = "Default", MousePos = vector.create(pos.X, pos.Y, pos.Z) }
    )
end

local function AF_StopWithRemote(remote, pos)
    remote:FireServer(
        { key = "M1", attack = "stopAttack" },
        { MouseBehavior = "Default", MousePos = vector.create(pos.X, pos.Y, pos.Z) }
    )
end

local function AF_UsePotion(tool)
    local remote = tool:FindFirstChildOfClass("RemoteEvent")
    if remote then
        AF_FireWithRemote(remote, AF_GetAttackName(tool), RootPart.Position)
    elseif tool:GetAttribute("nsystem") then
        local modes = AF_GetModes(tool)
        local mode = modes and modes[1] or nil
        InputEvent:FireServer(tool, mode, RootPart.Position)
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

local AF_KeybindOrder = { "M1", "Q", "E", "R", "F" }

local function AF_FireMode(tool, remote, modeName, keybind)
    local pos = RootPart.Position
    if remote then
        local attackName = tool:GetAttribute(keybind) or modeName
        remote:FireServer(
            { key = keybind, attack = attackName },
            { MouseBehavior = "Default", MousePos = vector.create(pos.X, pos.Y, pos.Z) }
        )
        task.wait(0.05)
        local stopName = keybind == "M1" and "stopAttack" or ("stopAttack" .. keybind)
        remote:FireServer(
            { key = keybind, attack = stopName },
            { MouseBehavior = "Default", MousePos = vector.create(pos.X, pos.Y, pos.Z) }
        )
    else
        InputEvent:FireServer(tool, modeName, pos)
        task.wait(0.05)
        InputEvent:FireServer(tool, modeName, pos, true)
    end
end

local function AF_IsFlamethrower(tool)
    return tool:FindFirstChild("ShootUnion") ~= nil
end

local function AF_StartTool(tool)
    if autoFireThreads[tool] then return end
    autoFireThreads[tool] = true

    if tool:FindFirstChild("Liquid") then
        AF_StartPotionLoop(tool)
    end

    task.spawn(function()
        local remote    = tool:FindFirstChildOfClass("RemoteEvent")
        local isNsystem = tool:GetAttribute("nsystem")
        local isFlame   = AF_IsFlamethrower(tool)

        if not remote and not isNsystem then
            autoFireThreads[tool] = nil
            return
        end

        local modes = AF_GetModes(tool)

        -- FLAMETHROWER: nsystem + ShootUnion — hold M1, never release mid-fight
        if isFlame and isNsystem then
            local cd = AF_GetCooldown(tool, 0.1)
            local pos = RootPart.Position
            if modes and modes[1] then
                InputEvent:FireServer(tool, modes[1], pos)
            else
                InputEvent:FireServer(tool, nil, pos)
            end

            while AutoFireActive and AF_IsInCharacter(tool) do
                task.wait(cd)
                local currentPos = RootPart.Position
                if modes and modes[1] then
                    InputEvent:FireServer(tool, modes[1], currentPos)
                else
                    InputEvent:FireServer(tool, nil, currentPos)
                end
            end

            -- Release only when done
            if modes and modes[1] then
                InputEvent:FireServer(tool, modes[1], RootPart.Position, true)
            else
                InputEvent:FireServer(tool, nil, RootPart.Position, true)
            end

            autoFireThreads[tool] = nil
            return
        end

        while AutoFireActive and AF_IsInCharacter(tool) do
            local cd = AF_GetCooldown(tool, 0.5)

            if remote then
                local pos = RootPart.Position
                AF_FireWithRemote(remote, AF_GetAttackName(tool), pos)
                task.wait(cd)
                AF_StopWithRemote(remote, RootPart.Position)

                if UseAbilities and modes then
                    for i = 2, #modes do
                        if not AutoFireActive or not AF_IsInCharacter(tool) then break end
                        local keybind = AF_KeybindOrder[i]
                        if keybind and tool:GetAttribute(keybind) then
                            AF_FireMode(tool, remote, modes[i], keybind)
                            task.wait(cd)
                        end
                    end
                end

            elseif isNsystem then
                local pos = RootPart.Position
                if modes and modes[1] then
                    InputEvent:FireServer(tool, modes[1], pos)
                else
                    InputEvent:FireServer(tool, nil, pos)
                end
                task.wait(cd)
                if modes and modes[1] then
                    InputEvent:FireServer(tool, modes[1], pos, true)
                else
                    InputEvent:FireServer(tool, nil, pos, true)
                end

                if UseAbilities and modes then
                    for i = 2, #modes do
                        if not AutoFireActive or not AF_IsInCharacter(tool) then break end
                        AF_FireMode(tool, nil, modes[i], AF_KeybindOrder[i])
                        task.wait(cd)
                    end
                end
            end

            task.wait(0.05)
        end

        -- cleanup stop signals
        if remote then
            AF_StopWithRemote(remote, RootPart.Position)
            if modes then
                for i = 2, #modes do
                    local keybind = AF_KeybindOrder[i]
                    if keybind then
                        local stopName = "stopAttack" .. keybind
                        remote:FireServer(
                            { key = keybind, attack = stopName },
                            { MouseBehavior = "Default", MousePos = vector.create(RootPart.Position.X, RootPart.Position.Y, RootPart.Position.Z) }
                        )
                    end
                end
            end
        elseif isNsystem and modes then
            for i = 1, #modes do
                InputEvent:FireServer(tool, modes[i], RootPart.Position, true)
            end
        end

        autoFireThreads[tool] = nil
    end)
end

StartAutoFire = function()
    if AutoFireActive then return end
    AutoFireActive = true
    autoFireThreads = {}

    for _, tool in ipairs(LocalPlayer.Backpack:GetChildren()) do
        if tool:IsA("Tool") then
            tool.Parent = Character
        end
    end

    for _, tool in ipairs(Character:GetChildren()) do
        if tool:IsA("Tool") then
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
            IsEmergency = true
            task.spawn(function()
                Notify("low health!", "fleeing to safety to heal", 4)
                local safePos = RootPart.Position + Vector3.new(0, 700, 0)
                LockedPosition = safePos
                RootPart.CFrame = CFrame.new(safePos)
                RootPart.AssemblyLinearVelocity  = Vector3.zero
                RootPart.AssemblyAngularVelocity = Vector3.zero

                local holdConn
                holdConn = RunService.Heartbeat:Connect(function()
                    if not IsEmergency then holdConn:Disconnect(); return end
                    LockedPosition = safePos
                    RootPart.CFrame = CFrame.new(safePos)
                    RootPart.AssemblyLinearVelocity  = Vector3.zero
                    RootPart.AssemblyAngularVelocity = Vector3.zero
                end)

                repeat task.wait(0.5) until
                    not (IsActive or FarmActive or EnemyFarmActive)
                    or (Humanoid.Health / Humanoid.MaxHealth) >= 0.85

                holdConn:Disconnect()
                if IsActive or FarmActive or EnemyFarmActive then
                    Notify("health ok", "back to fighting", 3)
                end
                IsEmergency = false
            end)
        end
    end)
end

-- ============================================================
-- RESPAWN
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(newChar)
    IsRespawning = true
    IsEmergency  = false
    StopHealthMonitor()
    StopRenderLock()

    Character = newChar
    RootPart  = newChar:WaitForChild("HumanoidRootPart")
    Humanoid  = newChar:WaitForChild("Humanoid")

    if not FarmActive and not EnemyFarmActive then
        IsRespawning = false
        StartHealthMonitor()
        return
    end

    task.wait(2)

    IsActive       = false
    FarmDodgeReady = false
    IsDodging      = false
    LockedPosition = nil
    CurrentTarget  = nil
    for _, c in ipairs(Connections) do c:Disconnect() end; Connections = {}
    for b in pairs(BulletData) do UnregisterBullet(b) end; BulletData = {}
    if SafeZoneVisual then SafeZoneVisual:Destroy(); SafeZoneVisual = nil end

    StopAutoFire()
    task.wait(0.5)
    StartAutoFire()

    if CurrentSourceType == "enemy" then
        Notify("respawned", "heading back to " .. tostring(CurrentSourceName), 4)
        TeleportToEnemyIsland(CurrentSourceName)
        task.wait(1)
    elseif CurrentSourceType == "boss" then
        Notify("respawned", "heading back to boss fight", 4)
        TeleportToLocation("Portal Room")
        task.wait(1)
    elseif FarmActive or EnemyFarmActive then
        TeleportToLocation("Portal Room")
        task.wait(1)
    end

    ActivateForFarm()
    IsRespawning = false
    StartHealthMonitor()
end)

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

    local isBoss = BossDropTables[EnemyFarmTargetName] ~= nil or BossLocations[EnemyFarmTargetName] ~= nil

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

    if not IsActive then ActivateForFarm() end

    task.spawn(function()
        while EnemyFarmActive do
            FarmDodgeReady      = false
            CurrentTarget       = nil
            LockedPosition      = nil
            Humanoid.AutoRotate = true

            if isBoss then
                TeleportToLocation("Portal Room")
                task.wait(1)
                local ok = StartBossFight(EnemyFarmTargetName)
                if not ok then task.wait(3); continue end

                local boss = WaitForBoss(EnemyFarmTargetName, 30)
                if not boss then task.wait(3); continue end

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

            else
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
                    Notify("looking...", "can't find any target, reteleporting", 3)
                    task.wait(2)
                    continue
                end

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

-- ============================================================
-- TEXT PREDICTION HELPER (legacy, used by "did you mean?" notify)
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
-- RAYFIELD WINDOW
-- ============================================================
local Window = Rayfield:CreateWindow({
    Name                = "destined laziness",
    LoadingTitle        = "hang on...",
    LoadingSubtitle     = "getting things ready",
    ConfigurationSaving = { Enabled = false },
    Discord             = { Enabled = false },
    KeySystem           = false,
})

-- ============================================================
-- DODGE TAB
-- ============================================================
local DodgeTab = Window:CreateTab("AutoDodge", 4483362458)
DodgeTab:CreateToggle({
    Name = "lock onto nearest enemy", CurrentValue = false, Flag = "DodgeToggle",
    Callback = function(v) if v then Activate() else Deactivate() end end
})

DodgeTab:CreateDivider()

DodgeTab:CreateSlider({
    Name = "safe zone width", Range = {10, 200}, Increment = 1,
    CurrentValue = Config.SafeZoneWidth, Flag = "SafeZoneWidth",
    Callback = function(v) Config.SafeZoneWidth = v; RefreshSafeZoneVisual() end
})
DodgeTab:CreateSlider({
    Name = "safe zone height", Range = {5, 100}, Increment = 1,
    CurrentValue = Config.SafeZoneHeight, Flag = "SafeZoneHeight",
    Callback = function(v) Config.SafeZoneHeight = v; RefreshSafeZoneVisual() end
})
DodgeTab:CreateSlider({
    Name = "safe zone depth", Range = {10, 200}, Increment = 1,
    CurrentValue = Config.SafeZoneDepth, Flag = "SafeZoneDepth",
    Callback = function(v) Config.SafeZoneDepth = v; RefreshSafeZoneVisual() end
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

-- ============================================================
-- FARM TAB
-- ============================================================
local FarmTab = Window:CreateTab("AutoFarm", 4483362458)

-- ---- Target item predictive input ----
-- We get the internal Rayfield tab frame so we can inject our custom widget.
-- Rayfield tabs are ScreenGui > Frame children; we use a Section as an anchor.
local itemSection = FarmTab:CreateSection("target item")

task.defer(function()
    -- Find the Rayfield ScreenGui
    local rayfieldGui = LocalPlayer.PlayerGui:FindFirstChild("Rayfield")
    if not rayfieldGui then return end

    -- Locate the section we just created by its label text
    local function FindSectionFrame(labelText)
        for _, obj in ipairs(rayfieldGui:GetDescendants()) do
            if obj:IsA("TextLabel") and obj.Text == labelText then
                return obj.Parent
            end
        end
        return nil
    end

    -- Give Rayfield a frame to render into
    local sectionFrame = FindSectionFrame("target item")
    if not sectionFrame then return end

    -- Inject a small spacer so the input sits below the section label
    local spacer = Instance.new("Frame")
    spacer.Size              = UDim2.new(1, 0, 0, 44)
    spacer.BackgroundTransparency = 1
    spacer.Parent            = sectionFrame

    CreatePredictiveInput(spacer, "e.g. Fury Ruler Sword", GetAllCraftableNames, function(text)
        TargetItemName = text
        if CraftableItems[text] then
            Notify("item locked in", text, 3)
        else
            local suggestions = GetItemSuggestions(text)
            if #suggestions > 0 then
                Notify("did you mean?", table.concat(suggestions, "\n"), 6)
            else
                Notify("not found", text .. " isn't in the crafting list", 5)
            end
        end
    end)
end)

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

-- ---- Enemy farm predictive input ----
local enemySection = FarmTab:CreateSection("enemy to farm")

task.defer(function()
    local rayfieldGui = LocalPlayer.PlayerGui:FindFirstChild("Rayfield")
    if not rayfieldGui then return end

    local function FindSectionFrame(labelText)
        for _, obj in ipairs(rayfieldGui:GetDescendants()) do
            if obj:IsA("TextLabel") and obj.Text == labelText then
                return obj.Parent
            end
        end
        return nil
    end

    local sectionFrame = FindSectionFrame("enemy to farm")
    if not sectionFrame then return end

    local spacer = Instance.new("Frame")
    spacer.Size                   = UDim2.new(1, 0, 0, 44)
    spacer.BackgroundTransparency = 1
    spacer.Parent                 = sectionFrame

    CreatePredictiveInput(spacer, "e.g. Fury Destructive Overlord", GetAllEnemyNames, function(text)
        EnemyFarmTargetName = text
        if text ~= "" then
            Notify("enemy set", "will farm: " .. text, 3)
        end
    end)
end)

FarmTab:CreateToggle({
    Name = "autofarm enemy", CurrentValue = false, Flag = "EnemyFarmToggle",
    Callback = function(v) if v then StartEnemyFarm() else StopEnemyFarm() end end
})

Rayfield:OnUnload(function()
    StopFarm()
    StopEnemyFarm()
    Deactivate()
    if VisualFolder and VisualFolder.Parent then VisualFolder:Destroy() end
end)

print("[autofarm] loaded — good luck out there")
