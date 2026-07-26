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
raycastParams.FilterDescendantsInstances = {}

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

	-- sanity check floor fallback if mesh bounds havent resolved yet
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
	raycastParams:AddToFilter(character)
	raycastParams:AddToFilter(npcModel)

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

	-- debug visualization toggle
	local DEBUG_MODE = true

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
	local CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH = 15.0 -- extra length for cautious double check raycast
	local MAX_LOOK_UP_ANGLE = math.rad(80)     -- must exceed this to START the pause
	local MIN_LOOK_UP_EXIT_ANGLE = math.rad(60) -- must drop below THIS to be considered resolved

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
	local lastRayVisTime = 0
	local isVoidOrDeepFall = false
	local rayColor = Color3.new(255, 255, 0)

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

	-- Visualizes the ahead raycast hit point and ray line with neon yellow fading parts
	-- rayOrigin - origin vector of raycast
	-- rayResult - RaycastResult instance or nil
	local function visualizeAheadRay(rayOrigin, rayResult)
		if not DEBUG_MODE then return end
		local now = os.clock()
		if now - lastRayVisTime < 0.12 then return end
		lastRayVisTime = now

		local hitPos = rayResult and rayResult.Position or (rayOrigin - Vector3.new(0, DEEP_FALL_RAY_LENGTH, 0))
		local rayVector = hitPos - rayOrigin
		local dist = rayVector.Magnitude
		if dist < 0.1 then return end

		local folder = workspace:FindFirstChild("RayDebugFolder")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "RayDebugFolder"
			folder.Parent = workspace
		end

		-- vertical line pointing down from origin to hit position
		local linePart = Instance.new("Part")
		linePart.Name = "DebugRayLine"
		linePart.Size = Vector3.new(0.08, dist, 0.08)
		linePart.CFrame = CFrame.lookAt(rayOrigin + rayVector * 0.5, hitPos) * CFrame.Angles(math.pi / 2, 0, 0)
		linePart.Material = Enum.Material.Neon
		linePart.Color = (not isVoidOrDeepFall)  and Color3.fromRGB(255, 255, 0) or Color3.new(1)
		linePart.Anchored = true
		linePart.CanCollide = false
		linePart.CanQuery = false
		linePart.CanTouch = false
		linePart.AudioCanCollide = false
		linePart.Transparency = 1
		linePart.Parent = folder

		-- sphere part at hit position
		local hitPart = Instance.new("Part")
		hitPart.Name = "DebugRayHit"
		hitPart.Shape = Enum.PartType.Ball
		hitPart.Size = Vector3.new(0.6, 0.6, 0.6)
		hitPart.Position = hitPos
		hitPart.Material = Enum.Material.Neon
		hitPart.Color = (not isVoidOrDeepFall) and Color3.fromRGB(255, 255, 0) or Color3.new(1)
		hitPart.Anchored = true
		hitPart.CanCollide = false
		hitPart.CanQuery = false
		hitPart.CanTouch = false
		hitPart.AudioCanCollide = false
		hitPart.Transparency = 1
		hitPart.Parent = folder

		task.spawn(function()
			local fadeInTI = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local fadeOutTI = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

			TS:Create(linePart, fadeInTI, { Transparency = 0.3 }):Play()
			TS:Create(hitPart, fadeInTI, { Transparency = 0 }):Play()

			task.wait(0.5)

			TS:Create(linePart, fadeOutTI, { Transparency = 1 }):Play()
			local outTween = TS:Create(hitPart, fadeOutTI, { Transparency = 1 })
			outTween:Play()
			outTween.Completed:Wait()

			linePart:Destroy()
			hitPart:Destroy()
		end)
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

	local function getEffectiveDistance(posA, posB)
		local flatA = Vector3.new(posA.X, 0, posA.Z)
		local flatB = Vector3.new(posB.X, 0, posB.Z)
		local horizontalDist = (flatB - flatA).Magnitude

		local yDiff = math.abs(posB.Y - posA.Y)
		local effectiveY = 0
		if yDiff > MAX_VERTICAL_OFFSET then
			effectiveY = yDiff - MAX_VERTICAL_OFFSET
		end

		return math.sqrt(horizontalDist^2 + effectiveY^2)
	end

	setAnimState("Idle", 0.1)

	-- Checks whether the player is currently near-vertically aligned with the NPC
	-- (directly above or below), the exact geometry that collapses the horizontal
	-- direction vector to zero and breaks dir/rotation math downstream.
	local function isLookingStraightUp(force)
		local currentPos = npcRoot.Position
		local targetPos = plrRoot.Position
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local horizontalDist = (flatTarget - flatCurrent).Magnitude
		local yDiff = math.abs(targetPos.Y - currentPos.Y)

		if yDiff < 1 then return false end -- not enough vertical gap for this to be ambiguous

		local angle = math.atan2(yDiff, horizontalDist)
		return angle > (force or MAX_LOOK_UP_ANGLE)
	end

	-- state tracking for delayed teleport routine
	local isTeleporting = false
	local currentTeleportReason = nil
	local teleportToken = 0

	-- Checks if a position behind the player offers safe ground
	-- targetPos - player root position
	local function getSafeTeleportCFrame(targetPos)
		-- test multiple offsets: behind, right, left, front, modify to ur liking ngl, i prefer only behind
		local offsets = {
			CFrame.new(0, 0, 3),   
			CFrame.new(3, 0, 0),   
			CFrame.new(-3, 0, 0),  
			CFrame.new(0, 0, -3),  
		}

		for _, offsetCFrame in ipairs(offsets) do
			local teleportTarget = plrRoot.CFrame * offsetCFrame
			local teleRayOrigin = Vector3.new(teleportTarget.Position.X, targetPos.Y + 5, teleportTarget.Position.Z)
			local teleRayResult = workspace:Raycast(teleRayOrigin, Vector3.new(0, -DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			if teleRayResult then
				local safeY = teleRayResult.Position.Y + HIP_HEIGHT

				-- check #1 is this a safe fall depth relative to the player?
				if math.abs(safeY - targetPos.Y) < MAX_SAFE_FALL_DEPTH then

					-- check #2 will this spot trigger the "looking straight up" bug
					local flatCurrent = Vector3.new(teleportTarget.Position.X, 0, teleportTarget.Position.Z)
					local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
					local horizontalDist = (flatTarget - flatCurrent).Magnitude
					local yDiff = math.abs(targetPos.Y - safeY)

					-- approve if on similar Y-level OR if the angle is comfortably below the threshold
					if yDiff < 1 or math.atan2(yDiff, horizontalDist) <= MIN_LOOK_UP_EXIT_ANGLE then
						return CFrame.new(teleportTarget.Position.X, safeY, teleportTarget.Position.Z) * plrRoot.CFrame.Rotation
					end
				end
			end
		end

		-- if all spots are invalid (e.g., player is falling in the void), just drop them right on top of the player
		--return CFrame.new(targetPos.X, targetPos.Y + HIP_HEIGHT, targetPos.Z) * plrRoot.CFrame.Rotation
		-- actually nah I wanna make bro wait instead for now, maybe ill renable this later but for now, nah
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
			-- Simply exit; do NOT overwrite isTeleporting or currentTeleportReason
			return
		end

		-- check cancellation condition based on trigger reason
		if reason == "OutOfRange" then
			local curPlrPos = plrRoot.Position
			local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
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
				local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		elseif reason == "LookingStraightUp" then
			if not isLookingStraightUp() then
				isTeleporting = false
				currentTeleportReason = nil
				local curPlrPos = plrRoot.Position
				local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
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
			-- js exit; do NOT overwrite isTeleporting or currentTeleportReason
			return
		end

		-- re-check cancellation condition after verification delay
		if reason == "OutOfRange" then
			local curPlrPos = plrRoot.Position
			local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
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
				local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
				if curDist <= DISTANCE_STOP_FOLLOW then
					isFollowing = false
				end
				return
			end
		elseif reason == "LookingStraightUp" then
			if not isLookingStraightUp() then
				isTeleporting = false
				currentTeleportReason = nil
				local curPlrPos = plrRoot.Position
				local curDist = getEffectiveDistance(npcRoot.Position, curPlrPos)
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
			return -- let the new thread handle the global variables
		end

		npcModel:PivotTo(finalSafeCFrame)
		lastYPosition = finalSafeCFrame.Position.Y
		isFalling = false
		fallVelocity = 0

		fadeModelTransparency(npcModel, 0.0, FADE_DURATION, true)
		isTeleporting = false
		currentTeleportReason = nil
	end

	-- idle gravity logic
	-- dt - (delta) time elapsed since last frame
	local function applyIdleGravity(dt)
		local currentPos = npcRoot.Position
		local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 5, currentPos.Z)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -DEEP_FALL_RAY_LENGTH, 0), raycastParams)

		if rayResult then
			local targetGroundY = rayResult.Position.Y + HIP_HEIGHT
			local yDrop = currentPos.Y - targetGroundY

			if yDrop > 0.1 then
				if not isFalling then
					isFalling = true
					fallVelocity = 0
				end

				-- calculate gravity while standing still
				fallVelocity = fallVelocity + GRAVITY * dt
				local nextY = currentPos.Y - fallVelocity * dt

				if nextY <= targetGroundY then
					nextY = targetGroundY
					isFalling = false
					fallVelocity = 0
					setAnimState("Land", 0.1)
				end

				-- preserve current rotation, only update Y
				local rotCFrame = npcRoot.CFrame - npcRoot.CFrame.Position
				npcModel:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * rotCFrame)
				lastYPosition = nextY
			end
		end
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

		-- calculate horizontal distance with conditional vertical offset threshold
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local horizontalDist = (flatTarget - flatCurrent).Magnitude

		local yDiff = math.abs(targetPos.Y - currentPos.Y)
		local effectiveY = 0
		if yDiff > MAX_VERTICAL_OFFSET then
			effectiveY = yDiff - MAX_VERTICAL_OFFSET
		end

		local dist = getEffectiveDistance(currentPos, targetPos)

		-- state update for follow distance threshold
		if not isFollowing and dist > DISTANCE_START_FOLLOW then
			isFollowing = true
		elseif isFollowing and dist <= DISTANCE_STOP_FOLLOW then
			isFollowing = false
		end

		-- out of range check, if player moves further than MAX_TELEPORT_RANGE, trigger teleport routine
		if dist > MAX_TELEPORT_RANGE then
			if not isTeleporting then
				task.spawn(triggerTeleportSequence, targetPos, "OutOfRange")
			end
			setAnimState("Idle", 0.35)
			applyIdleGravity(dt)
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
					applyIdleGravity(dt)
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
					applyIdleGravity(dt)
					return
				end
			elseif currentTeleportReason == "LookingStraightUp" then
				if not isLookingStraightUp(MIN_LOOK_UP_EXIT_ANGLE) then
					teleportToken += 1
					isTeleporting = false
					currentTeleportReason = nil
					if dist <= DISTANCE_STOP_FOLLOW then
						isFollowing = false
					end
				else
					setAnimState("Idle", 0.35)
					applyIdleGravity(dt)
					return
				end
			end
		end

		if isFollowing then
			if isLookingStraightUp() then
				if not isTeleporting then
					task.spawn(triggerTeleportSequence, targetPos, "LookingStraightUp")
				end
				setAnimState("Idle", 0.35)
				applyIdleGravity(dt)
				return
			end

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

			-- raycast ahead straight down at proposed position to check for void or deep fall
			local aheadRayOrigin = Vector3.new(nextX + (isVoidOrDeepFall and (moveStep.X * CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH) or 0), currentPos.Y + 5, nextZ + (isVoidOrDeepFall and (moveStep.Z * CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH) or 0))
			local aheadRayResult = workspace:Raycast(aheadRayOrigin, Vector3.new(0, -DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			-- debug visualization of ahead raycast hit point and downward line
			visualizeAheadRay(aheadRayOrigin, aheadRayResult)

			if isVoidOrDeepFall then
				rayColor = Color3.new(1, 0.5)
			end

			if not aheadRayResult then
				isVoidOrDeepFall = true
				rayColor = Color3.new(1)
			else
				local dropDepth = currentPos.Y - aheadRayResult.Position.Y
				if dropDepth > MAX_SAFE_FALL_DEPTH then
					isVoidOrDeepFall = true
					rayColor = Color3.new(1)
				else
					isVoidOrDeepFall = false
				end
			end

			if isVoidOrDeepFall then
				-- void/deep fall detected ahead: trigger delayed teleport routine while remaining idle
				if not isTeleporting then
					task.spawn(triggerTeleportSequence, targetPos, "VoidOrDeepFall")
				end
				setAnimState("Idle", 0.35)
				applyIdleGravity(dt)
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

			local horizontalDelta = lookTarget - nextPos
			local currentCFrame = npcRoot.CFrame
			local lerpedRotation

			if horizontalDelta.Magnitude > 0.01 then
				local targetCFrame = CFrame.lookAt(nextPos, lookTarget)
				lerpedRotation = currentCFrame.Rotation:Lerp(targetCFrame.Rotation, math.clamp(TURN_SPEED * dt, 0, 1))
			else
				-- horizontally on top of / directly under the target, no valid direction
				-- to face, so just hold whatever rotation we already had this frame
				lerpedRotation = currentCFrame.Rotation
			end

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
	task.spawn(setupNpc, plr.Character, workspace:WaitForChild("Rig"))
end

plr.CharacterAdded:Connect(function(char)
	task.spawn(setupNpc, char, workspace:WaitForChild("Rig"))
end)
