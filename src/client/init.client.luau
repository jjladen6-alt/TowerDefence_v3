local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Shared = ReplicatedStorage:WaitForChild('Shared')
local Net = require(Shared:WaitForChild('Net'))

local function resolveRoundControllerModule(): ModuleScript
    local fromScript = script:FindFirstChild('RoundController')
    if fromScript and fromScript:IsA('ModuleScript') then
        return fromScript
    end

    local fromParent = script.Parent and script.Parent:FindFirstChild('RoundController')
    if fromParent and fromParent:IsA('ModuleScript') then
        return fromParent
    end

    local waitedFromScript = script:WaitForChild('RoundController', 5)
    if waitedFromScript and waitedFromScript:IsA('ModuleScript') then
        return waitedFromScript
    end

    local waitedFromParent = script.Parent and script.Parent:WaitForChild('RoundController', 5)
    if waitedFromParent and waitedFromParent:IsA('ModuleScript') then
        return waitedFromParent
    end

    error("[Client] Missing ModuleScript 'RoundController' under Client script or PlayerScripts")
end

local RoundController = require(resolveRoundControllerModule())
local TowerPlacementController = require(script:WaitForChild('TowerPlacementController'))
local TowerVisualController = require(script:WaitForChild('TowerVisualController'))
local HUDController = require(script:WaitForChild('HUDController'))

local roundController = RoundController.new(Net)
roundController:start()
local hudController = HUDController.new(Net)
hudController:start()
local towerPlacementController = TowerPlacementController.new(Net)
towerPlacementController:start()
local towerVisualController = TowerVisualController.new(Net)
towerVisualController:start()

print('[Client] Bootstrapped', Shared:GetFullName())
