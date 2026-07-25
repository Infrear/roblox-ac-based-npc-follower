--Services
local RS = game:GetService("RunService")
local RPS = game:GetService("ReplicatedStorage")
local PLRS = game:GetService("Players")
local TS = game:GetService("TweenService")

local plr = PLRS.LocalPlayer

-- raycast setup to keep npc above ground
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Calculates hip height distance from root part center to model bottom
-- rig - the NPC model instance
local function getHipHeight(rig)
	local rootPart = rig.PrimaryPart or rig:FindFirstChild("HumanoidRootPart")
	local fallback = rig:GetAttribute("HipHeightFallback") or 2.67

	if not rootPart then return fallback end

	local rootY = rootPart.Position.Y
	local lowestBottomY = rootY

	-- calculate lowest bottom point among all base parts in the rig
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") and part ~= rootPart then
			local partBottom = part.Position.Y - (part.Size.Y / 2)
			if partBottom < lowestBottomY then
				lowestBottomY = partBottom
			end
		end
	end

	local distanceToBottom = rootY - lowestBottomY

	-- sanity check floor fallback if mesh bounds haven't resolved yet
	if distanceToBottom < 2.2 then
		distanceToBottom = fallback
	end

	return distanceToBottom
end

local function setupNpc(character, npcModel)
	if not character then return end
	local plrRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not plrRoot then return end
	
	-- disable collision for smooth client-side cframe movement
	for _, desc in pairs(npcModel:GetChildren()) do
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
	local TURN_SPEED = 10 -- speed scale for smooth turning rotation
	local HIP_HEIGHT = getHipHeight(npcModel)

	-- task threshold constants
	local MAX_VERTICAL_OFFSET = 6.0 -- height difference threshold before y distance factors into magnitude
	local LANDING_DROP_THRESHOLD = 2 -- downward Y drop threshold to trigger landing animation & lerp
	local MAX_SAFE_FALL_DEPTH = 25.0 -- maximum safe downward drop depth before treating as deep fall/void
	local DEEP_FALL_RAY_LENGTH = 50.0 -- downward raycast depth for void detection
	local MAX_TELEPORT_RANGE = 60.0 -- maximum distance before triggering vanish teleport sequence
	local TELEPORT_WAIT_DELAY = 1.5 -- initial delay in seconds before attempting teleport
	local VERIFY_SAFE_DELAY = 0.5 -- verification delay to ensure target spot is not temporary
	local FADE_DURATION = 0.3 -- transparency fade duration in seconds
	local GRAVITY = 150.0 -- downward gravity acceleration scale for falling

	-- animation thresholds based on animation manager reference
	local SPEED_THRESHOLD = 0.75
	local RUN_THRESHOLD = 8.0

	local fallbackAnimStrings = {
		Idle = "http://www.roblox.com/asset/?id=507766388",
		Walk = "http://www.roblox.com/asset/?id=913376220",
		Run = "http://www.roblox.com/asset/?id=913376220",
		Jump = "http://www.roblox.com/asset/?id=507765000",
		Fall = "http://www.roblox.com/asset/?id=507767968",
		Land = "http://www.roblox.com/asset/?id=15719965221",
	}

	local animTracks = {}
	local hasWalkAnim = npcModel:FindFirstChild("Walk") ~= nil

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
	local isFalling = false
	local fallVelocity = 0
	local isLanding = false
	local landingTime = 0
	local lastYPosition = npcRoot.Position.Y

	-- active transparency tweens table following roblox-tween-management workflow
	local TES = {}

	-- Tweens all baseparts, decals, and textures in the model to target transparency
	-- model                       - model instance to fade
	-- targetTransparency          - target numeric transparency (0 to 1)
	-- duration                    - fade duration in seconds
	-- fallbacktoOgTransparency   - if true, restores stored original transparency attribute
	local function fadeModelTransparency(model, targetTransparency, duration, fallbacktoOgTransparency)
		local fadeTime = duration or FADE_DURATION
		local TI = TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("BasePart") or desc:IsA("Decal") or desc:IsA("Texture") then
				if not desc:GetAttribute("OgTransparency") then
					desc:SetAttribute("OgTransparency", desc.Transparency)
				end
				if TES[desc] and TES[desc].PlaybackState == Enum.PlaybackState.Playing then
					TES[desc]:Cancel()
				end
				TES[desc] = TS:Create(desc, TI, { Transparency = fallbacktoOgTransparency and desc:GetAttribute("OgTransparency") or targetTransparency })
				TES[desc]:Play()
			end
		end
		task.wait(fadeTime)
	end

	-- Plays a specific animation state with smooth transition time
	-- stateName      - "Idle", "Walk", "Run", or "Land"
	-- transitionTime - optional crossfade duration in seconds
	local function setAnimState(stateName, transitionTime)
		local fadeTime = transitionTime or 0.35
		if currentAnimState == stateName then return end
		currentAnimState = stateName
		for name, track in pairs(animTracks) do
			if name == stateName then
				if not track.IsPlaying then
					track:Play(fadeTime)
				end
			else
				if name ~= "Jump" and name ~= "Fall" then
					if track.IsPlaying then
						track:Stop(fadeTime)
					end
				end
			end
		end
	end

	-- Adjusts active animation playback speed according to current movement velocity
	-- speed - current movement speed in studs per second
	-- scale - speed scaling factor
	local function setAnimationSpeed(speed, scale)
		local currentTrack = animTracks[currentAnimState]
		if currentTrack and currentTrack.IsPlaying then
			currentTrack:AdjustSpeed(speed / scale)
		end
	end

	setAnimState("Idle", 0.1)

	-- state tracking for delayed teleport routine
	local isTeleporting = false
	local currentTeleportReason = nil
	local teleportToken = 0

	-- Checks if a position behind the player offers safe ground
	-- targetPos - player root position
	local function getSafeTeleportCFrame(targetPos)
		local teleportTarget = plrRoot.CFrame * CFrame.new(0, 0, 3)
		local teleRayOrigin = Vector3.new(teleportTarget.Position.X, targetPos.Y + 5, teleportTarget.Position.Z)
		local teleRayResult = workspace:Raycast(teleRayOrigin, Vector3.new(0, -25, 0), raycastParams)
		if teleRayResult then
			local safeY = teleRayResult.Position.Y + HIP_HEIGHT
			return CFrame.new(teleportTarget.Position.X, safeY, teleportTarget.Position.Z) * plrRoot.CFrame.Rotation
		end
		return nil
	end

	-- Checks if the path directly in front of the NPC is currently walkable towards the player
	local function checkPathAheadWalkable()
		local currentPos = npcRoot.Position
		local targetPos = plrRoot.Position
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local horizontalDist = (flatTarget - flatCurrent).Magnitude

		if horizontalDist <= 0.1 then return true end

		local dir = (flatTarget - flatCurrent).Unit

		-- sample multiple points along path towards player to prevent false positive ground reads near cliff edges
		local sampleDistance = math.min(horizontalDist, DISTANCE_START_FOLLOW)
		local stepSize = 1.5
		local steps = math.max(math.floor(sampleDistance / stepSize), 1)

		for i = 1, steps do
			local distAhead = i * stepSize
			local sampleX = currentPos.X + dir.X * distAhead
			local sampleZ = currentPos.Z + dir.Z * distAhead

			local rayOrigin = Vector3.new(sampleX, currentPos.Y + 5, sampleZ)
			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			if not rayResult then
				return false -- void detected along path
			end

			local dropDepth = currentPos.Y - rayResult.Position.Y
			if dropDepth > MAX_SAFE_FALL_DEPTH then
				return false -- deep fall detected along path
			end
		end

		return true
	end

	-- Executes the delayed teleport sequence with double-check verification and fade animations
	-- targetPos - player root position
	-- reason    - "OutOfRange" or "VoidOrDeepFall"
	local function triggerTeleportSequence(targetPos, reason)
		if isTeleporting then return end
		isTeleporting = true
		currentTeleportReason = reason
		teleportToken += 1
		local localToken = teleportToken

		-- phase 1: initial 1.5s delay while standing idle
		setAnimState("Idle", 0.35)
		task.wait(TELEPORT_WAIT_DELAY)

		if localToken ~= teleportToken then
			isTeleporting = false
			currentTeleportReason = nil
			return
		end

		-- check cancellation condition based on trigger reason
		if reason == "OutOfRange" then
			local curPlrPos = plrRoot.Position
			local curDist = (Vector3.new(curPlrPos.X, 0, curPlrPos.Z) - Vector3.new(npcRoot.Position.X, 0, npcRoot.Position.Z)).Magnitude
			if curDist <= MAX_TELEPORT_RANGE then
				isTeleporting = false
				currentTeleportReason = nil
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		elseif reason == "VoidOrDeepFall" then
			if checkPathAheadWalkable() then
				isTeleporting = false
				currentTeleportReason = nil
				local curPlrPos = plrRoot.Position
				local curDist = (Vector3.new(curPlrPos.X, 0, curPlrPos.Z) - Vector3.new(npcRoot.Position.X, 0, npcRoot.Position.Z)).Magnitude
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		end

		-- phase 2: check if initial safe spot exists behind player
		local safeCFrame = getSafeTeleportCFrame(targetPos)
		if not safeCFrame then
			isTeleporting = false
			currentTeleportReason = nil
			return
		end

		-- phase 3: verification delay (0.5s) to ensure target spot is not temporary
		task.wait(VERIFY_SAFE_DELAY)

		if localToken ~= teleportToken then
			isTeleporting = false
			currentTeleportReason = nil
			return
		end

		-- re-check cancellation condition after verification delay
		if reason == "OutOfRange" then
			local curPlrPos = plrRoot.Position
			local curDist = (Vector3.new(curPlrPos.X, 0, curPlrPos.Z) - Vector3.new(npcRoot.Position.X, 0, npcRoot.Position.Z)).Magnitude
			if curDist <= MAX_TELEPORT_RANGE then
				isTeleporting = false
				currentTeleportReason = nil
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		elseif reason == "VoidOrDeepFall" then
			if checkPathAheadWalkable() then
				isTeleporting = false
				currentTeleportReason = nil
				local curPlrPos = plrRoot.Position
				local curDist = (Vector3.new(curPlrPos.X, 0, curPlrPos.Z) - Vector3.new(npcRoot.Position.X, 0, npcRoot.Position.Z)).Magnitude
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		end

		-- phase 4: re-verify safe spot after verification delay
		local finalSafeCFrame = getSafeTeleportCFrame(plrRoot.Position)
		if not finalSafeCFrame then
			isTeleporting = false
			currentTeleportReason = nil
			return
		end

		-- phase 5: execute vanish (fade out) -> teleport -> reappear (fade in)
		fadeModelTransparency(npcModel, 1.0, FADE_DURATION)
		if localToken ~= teleportToken then
			fadeModelTransparency(npcModel, 0.0, FADE_DURATION, true)
			isTeleporting = false
			currentTeleportReason = nil
			return
		end

		npcModel:PivotTo(finalSafeCFrame)
		lastYPosition = finalSafeCFrame.Position.Y
		isFalling = false
		fallVelocity = 0

		fadeModelTransparency(npcModel, 0.0, FADE_DURATION, true)
		isTeleporting = false
		currentTeleportReason = nil
	end

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

		-- task 1: calculate horizontal distance with conditional vertical offset threshold
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local horizontalDist = (flatTarget - flatCurrent).Magnitude

		local yDiff = math.abs(targetPos.Y - currentPos.Y)
		local effectiveY = 0
		if yDiff > MAX_VERTICAL_OFFSET then
			effectiveY = yDiff - MAX_VERTICAL_OFFSET
		end

		local dist = math.sqrt(horizontalDist^2 + effectiveY^2)

		-- state update for follow distance threshold
		if not isFollowing and dist > DISTANCE_START_FOLLOW then
			isFollowing = true
		elseif isFollowing and dist <= DISTANCE_STOP_FOLLOW then
			isFollowing = false
		end

		-- out of range check: if player moves further than MAX_TELEPORT_RANGE, trigger teleport routine
		if dist > MAX_TELEPORT_RANGE then
			if not isTeleporting then
				task.spawn(triggerTeleportSequence, targetPos, "OutOfRange")
			end
			setAnimState("Idle", 0.35)
			return
		end

		-- if teleport is active, hold idle state unless cancellation criteria is met
		if isTeleporting then
			if currentTeleportReason == "OutOfRange" then
				if dist <= MAX_TELEPORT_RANGE then
					teleportToken += 1
					isTeleporting = false
					currentTeleportReason = nil
					if dist <= DISTANCE_STOP_FOLLOW then
						isFollowing = false
					end
				else
					setAnimState("Idle", 0.35)
					return
				end
			elseif currentTeleportReason == "VoidOrDeepFall" then
				if checkPathAheadWalkable() then
					teleportToken += 1
					isTeleporting = false
					currentTeleportReason = nil
					if dist <= DISTANCE_STOP_FOLLOW then
						isFollowing = false
					end
				else
					setAnimState("Idle", 0.35)
					return
				end
			else
				setAnimState("Idle", 0.35)
				return
			end
		end

		if isFollowing then
			-- calculate move direction on xz plane
			local dir = (flatTarget - flatCurrent).Unit
			local moveStep = dir * (MOVE_SPEED * dt)

			-- prevent overshooting target
			if moveStep.Magnitude > horizontalDist then
				moveStep = dir * horizontalDist
			end

			local currentSpeed = moveStep.Magnitude / math.max(dt, 0.001)

			local nextX = currentPos.X + moveStep.X
			local nextZ = currentPos.Z + moveStep.Z

			-- task 3: raycast ahead straight down at proposed position to check for void or deep fall
			local aheadRayOrigin = Vector3.new(nextX, currentPos.Y + 5, nextZ)
			local aheadRayResult = workspace:Raycast(aheadRayOrigin, Vector3.new(0, -DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			local isVoidOrDeepFall = false
			if not aheadRayResult then
				isVoidOrDeepFall = true
			else
				local dropDepth = currentPos.Y - aheadRayResult.Position.Y
				if dropDepth > MAX_SAFE_FALL_DEPTH then
					isVoidOrDeepFall = true
				end
			end

			if isVoidOrDeepFall then
				-- void/deep fall detected ahead: trigger delayed teleport routine while remaining idle
				if not isTeleporting then
					task.spawn(triggerTeleportSequence, targetPos, "VoidOrDeepFall")
				end
				setAnimState("Idle", 0.35)
				return
			end

			-- safe floor detected ahead
			local targetGroundY = aheadRayResult.Position.Y + HIP_HEIGHT
			local nextY = targetGroundY

			-- gravity fall lerp & land animation at end
			local yDrop = lastYPosition - targetGroundY
			if yDrop > LANDING_DROP_THRESHOLD and not isFalling and not isLanding then
				isFalling = true
				fallVelocity = 0
			end

			if isFalling then
				-- accelerate downward like gravity
				fallVelocity = fallVelocity + GRAVITY * dt
				nextY = lastYPosition - fallVelocity * dt

				-- check if ground reached
				if nextY <= targetGroundY then
					nextY = targetGroundY
					isFalling = false
					fallVelocity = 0

					-- play landing animation ONLY at the end upon ground contact
					isLanding = true
					landingTime = 0.35
					setAnimState("Land", 0.1)
				end
			elseif isLanding then
				landingTime = landingTime - dt
				if landingTime <= 0 then
					isLanding = false
				end
			else
				-- walk/run animation blending logic
				if hasWalkAnim then
					if currentSpeed > RUN_THRESHOLD then
						setAnimState("Run", 0.5)
						setAnimationSpeed(currentSpeed, 12.0)
					elseif currentSpeed > SPEED_THRESHOLD then
						setAnimState("Walk", 0.5)
						setAnimationSpeed(currentSpeed, 5.0)
					else
						setAnimState("Idle", 0.35)
					end
				else
					setAnimState("Run", 0.35)
					setAnimationSpeed(currentSpeed, MOVE_SPEED)
				end
			end

			lastYPosition = nextY
			local nextPos = Vector3.new(nextX, nextY, nextZ)
			local lookTarget = Vector3.new(targetPos.X, nextY, targetPos.Z)

			-- smooth turning rotation when moving to prevent sudden jerking
			local targetCFrame = CFrame.lookAt(nextPos, lookTarget)
			local currentCFrame = npcRoot.CFrame
			local lerpedRotation = currentCFrame.Rotation:Lerp(targetCFrame.Rotation, math.clamp(TURN_SPEED * dt, 0, 1))

			npcModel:PivotTo(CFrame.new(nextPos) * lerpedRotation)
		else
			setAnimState("Idle", 0.35)

			-- raycast check to maintain ground position while standing still without rotating
			local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 5, currentPos.Z)
			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), raycastParams)
			if rayResult then
				local targetY = rayResult.Position.Y + HIP_HEIGHT
				if math.abs(currentPos.Y - targetY) > 0.05 then
					local rotCFrame = npcRoot.CFrame - npcRoot.CFrame.Position
					npcModel:PivotTo(CFrame.new(currentPos.X, targetY, currentPos.Z) * rotCFrame)
					lastYPosition = targetY
				end
			end
		end
	end)
end

-- handle initial character spawn and respawns
if plr.Character then
	task.spawn(setupNpc, plr.Character, workspace.Rig)
end

plr.CharacterAdded:Connect(function(char)
	task.spawn(setupNpc, char, workspace.Rig)
end)