-- Services
local PLRS = game:GetService("Players")

local FollowerNPC = require(script:WaitForChild("FollowerNPC"))

local plr = PLRS.LocalPlayer
local currentFollower = nil

local function setupNpc(char)
	if currentFollower then
		currentFollower:Destroy()
		currentFollower = nil
	end

	local rig = workspace:WaitForChild("Rig")
	if not rig then
		warn("no rig")
		return
	else
		if not rig.PrimaryPart or not rig:FindFirstChild("HumanoidRootPart") then
			repeat wait() until rig.PrimaryPart or rig:FindFirstChild("HumanoidRootPart") -- lwk wait for it to load in
		end
	end

	local config = {
		Animations = {}
	}

	currentFollower = FollowerNPC.new(rig, config)
	currentFollower:StartFollowing()
end

-- handle the initial character spawn when they first join
if plr.Character then
	task.spawn(setupNpc, plr.Character)
end

-- handle every time the player dies and respawns
plr.CharacterAdded:Connect(function(char)
	task.spawn(setupNpc, char)
end)