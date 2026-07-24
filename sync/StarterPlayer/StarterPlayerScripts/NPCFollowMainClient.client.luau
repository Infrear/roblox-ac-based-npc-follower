-- client script for npc pet follower using animationcontroller
local RS = game:GetService("RunService")
local RPS = game:GetService("ReplicatedStorage")
local PLRS = game:GetService("Players")

local plr = PLRS.LocalPlayer

-- raycast setup to keep npc above ground
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function getHipHeight(rig)
	local modelHeight = rig:GetExtentsSize().Y
	local modelCenterY = rig:GetModelCFrame().Position.Y
	local rootPartY = rig.PrimaryPart.Position.Y

	-- calculate the bottom world Y-coordinate of the model
	local modelBottomY = modelCenterY - (modelHeight / 2)

	-- calculate the distance from the RootPart center to the bottom
	local distanceToBottom = rootPartY - modelBottomY

	return distanceToBottom
end

local function setupNpc(character)
	if not character then return end
	local plrRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not plrRoot then return end

	-- clone rig from replicatedstorage
	--local rigTemplate = RPS:WaitForChild("Rig", 10)
	--if not rigTemplate then return end

	local npcModel = workspace.Rig

	-- disable collision for smooth client-side cframe movement
	for _, desc in pairs(npcModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
		end
	end

	-- exclude player character and npc from ground raycasts
	raycastParams.FilterDescendantsInstances = { character, npcModel }

	local ac = npcModel:WaitForChild("AnimationController")
	local npcRoot = npcModel.PrimaryPart or npcModel:WaitForChild("HumanoidRootPart")
	npcRoot.Anchored = true --> actually only anchor the root for smooth client-side cframe movement

	-- initial spawn position near player
	local initialPos = plrRoot.Position + Vector3.new(3, 0, 3)
	npcModel:PivotTo(CFrame.new(initialPos))

	local DISTANCE_START_FOLLOW = 10
	local DISTANCE_STOP_FOLLOW = 4
	local MOVE_SPEED = 12
	local HIP_HEIGHT = getHipHeight(npcModel)

	local fallbackAnimStrings = {
		Idle = "http://www.roblox.com/asset/?id=507766388",
		Run = "http://www.roblox.com/asset/?id=913376220",
		Jump = "http://www.roblox.com/asset/?id=507765000",
		Fall = "http://www.roblox.com/asset/?id=507767968",
	}

	local animTracks = {}
	for name, assetId in pairs(fallbackAnimStrings) do
		if npcModel:FindFirstChild(name) then
			animTracks[name] = ac.Animator:LoadAnimation(npcModel:FindFirstChild(name))
		else
			local anim = Instance.new("Animation")
			anim.Name = name
			anim.AnimationId = assetId
			anim.Parent = npcModel
			animTracks[name] = ac.Animator:LoadAnimation(anim)
		end
	end

	local isFollowing = false
	local currentAnimState = nil

	-- Helper function to set active animation state
	-- stateName - "Idle" or "Run"
	local function setAnimState(stateName)
		if currentAnimState == stateName then return end
		currentAnimState = stateName
		for name, track in pairs(animTracks) do
			if name == stateName then
				if not track.IsPlaying then
					track:Play()
				end
			else
				if track.IsPlaying then
					track:Stop()
				end
			end
		end
	end

	setAnimState("Idle")

	-- main render loop for client-side follower movement
	local connection
	connection = RS.RenderStepped:Connect(function(dt)
		if not npcModel or not npcModel.Parent or not character or not character.Parent then
			if connection then connection:Disconnect() end
			if npcModel then npcModel:Destroy() end
			return
		end

		local currentPos = npcRoot.Position
		local targetPos = plrRoot.Position

		-- calculate horizontal distance to player
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local dist = (flatTarget - flatCurrent).Magnitude

		-- state update for follow distance threshold
		if not isFollowing and dist > DISTANCE_START_FOLLOW then
			isFollowing = true
		elseif isFollowing and dist <= DISTANCE_STOP_FOLLOW then
			isFollowing = false
		end

		if isFollowing then
			setAnimState("Run")

			-- calculate move direction on xz plane
			local dir = (flatTarget - flatCurrent).Unit
			local moveStep = dir * (MOVE_SPEED * dt)

			-- prevent overshooting target
			if moveStep.Magnitude > dist then
				moveStep = dir * dist
			end

			local nextX = currentPos.X + moveStep.X
			local nextZ = currentPos.Z + moveStep.Z

			-- raycast down from height above npc to locate floor
			local rayOrigin = Vector3.new(nextX, currentPos.Y + 5, nextZ)
			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), raycastParams)

			local nextY = targetPos.Y
			if rayResult then
				nextY = rayResult.Position.Y + HIP_HEIGHT
			end

			local nextPos = Vector3.new(nextX, nextY, nextZ)
			local lookTarget = Vector3.new(targetPos.X, nextY, targetPos.Z)

			-- face towards player if moved significantly
			if (lookTarget - nextPos).Magnitude > 0.1 then
				npcModel:PivotTo(CFrame.lookAt(nextPos, lookTarget))
			else
				npcModel:PivotTo(CFrame.new(nextPos))
			end
		else
			setAnimState("Idle")

			-- raycast check to maintain ground position even while standing still
			local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 5, currentPos.Z)
			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), raycastParams)
			if rayResult then
				local targetY = rayResult.Position.Y + HIP_HEIGHT
				if math.abs(currentPos.Y - targetY) > 0.05 then
					local rotCFrame = npcRoot.CFrame - npcRoot.CFrame.Position
					npcModel:PivotTo(CFrame.new(currentPos.X, targetY, currentPos.Z) * rotCFrame)
				end
			end
		end
	end)
end

-- handle initial character spawn and respawns
if plr.Character then
	task.spawn(setupNpc, plr.Character)
end
plr.CharacterAdded:Connect(function(char)
	task.spawn(setupNpc, char)
end)