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
	if not rig then return 2.67 end

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

local FollowerNPC = {}
FollowerNPC.__index = FollowerNPC

-- config = { Animations = { Idle = "rbxassetid://...", Walk = "...", Run = "..." } }
function FollowerNPC.new(sourceModel: Model, config)
	config = config or {}
	local self = setmetatable({}, FollowerNPC)

	self.rig = sourceModel -- use passed-in model directly without cloning

	-- strip old humanoid if present so physics don't fight manual cframe movement
	local oldHumanoid = self.rig:FindFirstChildOfClass("Humanoid")
	if oldHumanoid then oldHumanoid:Destroy() end

	-- disable collision for smooth client-side cframe movement
	for _, desc in ipairs(self.rig:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = false
		end
	end

	self.controller = self.rig:FindFirstChildOfClass("AnimationController") or Instance.new("AnimationController")
	self.controller.Parent = self.rig
	self.animator = self.controller:FindFirstChildOfClass("Animator") or Instance.new("Animator", self.controller)

	-- stop any pre-existing playing animation tracks on animator
	for _, track in ipairs(self.animator:GetPlayingAnimationTracks()) do
		track:Stop(0.1)
	end

	self.rootPart = self.rig.PrimaryPart or self.rig:FindFirstChild("HumanoidRootPart")
	if self.rootPart then
		self.rootPart.Anchored = true
	end

	-- pdisconnect from clouds that have this rig attached to their float cycle
	if self.rig:FindFirstChild("FloatsAttachedTo") then
		for _, v in pairs(self.rig:FindFirstChild("FloatsAttachedTo"):GetChildren()) do
			if v:IsA("ValueBase") and v.Value and v.Value:IsA("ValueBase") and v.Value.Value and v.Value.Value == self.rig then
				--print(v.Value.Value)
				v.Value.Value = nil
			end
		end
	end

	-- task threshold constants
	self.DISTANCE_START_FOLLOW = 10
	self.DISTANCE_STOP_FOLLOW = 4
	self.MOVE_SPEED = 12
	self.TURN_SPEED = 10 -- speed scale for smooth turning rotation
	self.HIP_HEIGHT = self.rig:GetAttribute("HipHeightFallback") --getHipHeight(self.rig)

	-- debug visualization toggle
	self.DEBUG_MODE = false

	self.MAX_VERTICAL_OFFSET = 6.0 -- height difference threshold before y distance factors into magnitude
	self.LANDING_DROP_THRESHOLD = 2 -- downward Y drop threshold to trigger landing animation & lerp
	self.MAX_SAFE_FALL_DEPTH = 25.0 -- maximum safe downward drop depth before treating as deep fall/void
	self.DEEP_FALL_RAY_LENGTH = 50.0 -- downward raycast depth for void detection
	self.MAX_TELEPORT_RANGE = 60.0 -- maximum distance before triggering vanish teleport sequence
	self.TELEPORT_WAIT_DELAY = 1.5 -- initial delay in seconds before attempting teleport
	self.VERIFY_SAFE_DELAY = 0.5 -- verification delay to ensure target spot is not temporary
	self.FADE_DURATION = 0.3 -- transparency fade duration in seconds
	self.GRAVITY = 150.0 -- downward gravity acceleration scale for falling
	self.CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH = 15.0 -- extra length for cautious double check raycast
	self.FORWARD_EDGE_BUFFER = 2.5 -- forward look-ahead distance in studs to detect ledges before stepping over
	self.MAX_LOOK_UP_ANGLE = math.rad(80)     -- must exceed this to START the pause
	self.MIN_LOOK_UP_EXIT_ANGLE = math.rad(60) -- must drop below THIS to be considered resolved

	-- animation thresholds based on animation manager reference
	self.SPEED_THRESHOLD = 0.75
	self.RUN_THRESHOLD = 8.0

	local fallbackAnimStrings = {
		Idle = "http://www.roblox.com/asset/?id=507766388",
		Walk = "http://www.roblox.com/asset/?id=913376220",
		Run = "http://www.roblox.com/asset/?id=913376220",
		Jump = "http://www.roblox.com/asset/?id=507765000",
		Fall = "http://www.roblox.com/asset/?id=507767968",
		Land = "http://www.roblox.com/asset/?id=15719965221",
	}

	self.animTracks = {}
	local animConfig = config.Animations or {}

	for name, fallbackAssetId in pairs(fallbackAnimStrings) do
		local animId = animConfig[name] or (self.rig:FindFirstChild(name) and self.rig:FindFirstChild(name).AnimationId) or fallbackAssetId
		local anim = Instance.new("Animation")
		anim.Name = name
		anim.AnimationId = animId
		self.animTracks[name] = self.animator:LoadAnimation(anim)
	end

	self.hasWalkAnim = self.animTracks["Walk"] ~= nil
	self.isFollowing = false
	self.currentAnimState = nil
	self.isFalling = false
	self.fallVelocity = 0
	self.isLanding = false
	self.landingTime = 0
	self.lastYPosition = self.rootPart and self.rootPart.Position.Y or 0
	self.lastRayVisTime = 0
	self.isVoidOrDeepFall = false

	-- state tracking for delayed teleport routine
	self.isTeleporting = false
	self.currentTeleportReason = nil
	self.teleportToken = 0

	-- active transparency tweens table following roblox-tween-management workflow
	self.TES = {}
	self.renderConn = nil

	self:_setAnimState("Idle", 0.1)

	return self
end

-- Tweens all baseparts, decals, and textures in the model to target transparency
-- targetTransparency          - target numeric transparency (0 to 1)
-- duration                    - fade duration in seconds
-- fallbacktoOgTransparency   - if true, restores stored original transparency attribute
function FollowerNPC:FadeModelTransparency(targetTransparency, duration, fallbacktoOgTransparency)
	local fadeTime = duration or self.FADE_DURATION
	local TI = TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, desc in ipairs(self.rig:GetDescendants()) do
		if desc:IsA("BasePart") or desc:IsA("Decal") or desc:IsA("Texture") then
			if not desc:GetAttribute("OgTransparency") then
				desc:SetAttribute("OgTransparency", desc.Transparency)
			end
			if self.TES[desc] and self.TES[desc].PlaybackState == Enum.PlaybackState.Playing then
				self.TES[desc]:Cancel()
			end
			self.TES[desc] = TS:Create(desc, TI, { Transparency = fallbacktoOgTransparency and desc:GetAttribute("OgTransparency") or targetTransparency })
			self.TES[desc]:Play()
		end
	end
	task.wait(fadeTime)
end

-- Plays a specific animation state with smooth transition time
-- stateName      - "Idle", "Walk", "Run", or "Land"
-- transitionTime - optional crossfade duration in seconds
function FollowerNPC:_setAnimState(stateName, transitionTime)
	local fadeTime = transitionTime or 0.35
	if self.currentAnimState == stateName then return end
	self.currentAnimState = stateName
	for name, track in pairs(self.animTracks) do
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
function FollowerNPC:_setAnimationSpeed(speed, scale)
	local currentTrack = self.animTracks[self.currentAnimState]
	if currentTrack and currentTrack.IsPlaying then
		currentTrack:AdjustSpeed(speed / scale)
	end
end

function FollowerNPC:_getEffectiveDistance(posA, posB)
	local flatA = Vector3.new(posA.X, 0, posA.Z)
	local flatB = Vector3.new(posB.X, 0, posB.Z)
	local horizontalDist = (flatB - flatA).Magnitude

	local yDiff = math.abs(posB.Y - posA.Y)
	local effectiveY = 0
	if yDiff > self.MAX_VERTICAL_OFFSET then
		effectiveY = yDiff - self.MAX_VERTICAL_OFFSET
	end

	return math.sqrt(horizontalDist^2 + effectiveY^2)
end

-- Checks whether the player is currently near-vertically aligned with the NPC
-- (directly above or below) — the exact geometry that collapses the horizontal
-- direction vector to zero and breaks dir/rotation math downstream.
function FollowerNPC:_isLookingStraightUp(plrRoot, force)
	local currentPos = self.rootPart.Position
	local targetPos = plrRoot.Position
	local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
	local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
	local horizontalDist = (flatTarget - flatCurrent).Magnitude
	local yDiff = math.abs(targetPos.Y - currentPos.Y)

	if yDiff < 1 then return false end -- not enough vertical gap for this to be ambiguous

	local angle = math.atan2(yDiff, horizontalDist)
	return angle > (force or self.MAX_LOOK_UP_ANGLE)
end

-- Checks if a position behind the player offers safe ground
-- targetPos - player root position
function FollowerNPC:_getSafeTeleportCFrame(plrRoot, targetPos)
	local offsets = {
		CFrame.new(0, 0, 3),
		CFrame.new(3, 0, 0),
		CFrame.new(-3, 0, 0),
		CFrame.new(0, 0, -3),
	}

	for _, offsetCFrame in ipairs(offsets) do
		local teleportTarget = plrRoot.CFrame * offsetCFrame
		local teleRayOrigin = Vector3.new(teleportTarget.Position.X, targetPos.Y + 5, teleportTarget.Position.Z)
		local teleRayResult = workspace:Raycast(teleRayOrigin, Vector3.new(0, -self.DEEP_FALL_RAY_LENGTH, 0), raycastParams)

		if teleRayResult then
			local safeY = teleRayResult.Position.Y + self.HIP_HEIGHT

			if math.abs(safeY - targetPos.Y) < self.MAX_SAFE_FALL_DEPTH then
				local flatCurrent = Vector3.new(teleportTarget.Position.X, 0, teleportTarget.Position.Z)
				local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
				local horizontalDist = (flatTarget - flatCurrent).Magnitude
				local yDiff = math.abs(targetPos.Y - safeY)

				if yDiff < 1 or math.atan2(yDiff, horizontalDist) <= self.MIN_LOOK_UP_EXIT_ANGLE then
					return CFrame.new(teleportTarget.Position.X, safeY, teleportTarget.Position.Z) * plrRoot.CFrame.Rotation
				end
			end
		end
	end

	return nil
end

-- Checks if the path directly in front of the NPC is currently walkable towards the player
function FollowerNPC:_checkPathAheadWalkable(plrRoot)
	local currentPos = self.rootPart.Position
	local targetPos = plrRoot.Position
	local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
	local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
	local horizontalDist = (flatTarget - flatCurrent).Magnitude

	if horizontalDist <= 0.1 then return true end

	local dir = (flatTarget - flatCurrent).Unit

	-- sample multiple points along path towards player to prevent false positive ground reads near cliff edges
	local sampleDistance = math.min(horizontalDist, self.DISTANCE_START_FOLLOW)
	local stepSize = 1.5
	local steps = math.max(math.floor(sampleDistance / stepSize), 1)

	for i = 1, steps do
		local distAhead = i * stepSize
		local sampleX = currentPos.X + dir.X * distAhead
		local sampleZ = currentPos.Z + dir.Z * distAhead

		local rayOrigin = Vector3.new(sampleX, currentPos.Y + 5, sampleZ)
		local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -self.DEEP_FALL_RAY_LENGTH, 0), raycastParams)

		if not rayResult then
			return false -- void detected along path
		end

		local dropDepth = currentPos.Y - rayResult.Position.Y
		if dropDepth > self.MAX_SAFE_FALL_DEPTH then
			return false -- deep fall detected along path
		end
	end

	return true
end

-- Executes the delayed teleport sequence with double-check verification and fade animations
-- targetPos - player root position
-- reason    - "OutOfRange" or "VoidOrDeepFall"
function FollowerNPC:_triggerTeleportSequence(plrRoot, targetPos, reason)
	if self.isTeleporting then return end
	self.isTeleporting = true
	self.currentTeleportReason = reason
	self.teleportToken += 1
	local localToken = self.teleportToken

	-- phase 1: initial 1.5s delay while standing idle
	self:_setAnimState("Idle", 0.35)
	task.wait(self.TELEPORT_WAIT_DELAY)

	-- check cancellation condition based on trigger reason
	if localToken ~= self.teleportToken then
		return
	end

	if reason == "OutOfRange" then
		local curPlrPos = plrRoot.Position
		local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
		if curDist <= self.MAX_TELEPORT_RANGE then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	elseif reason == "VoidOrDeepFall" then
		if self:_checkPathAheadWalkable(plrRoot) then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			local curPlrPos = plrRoot.Position
			local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	elseif reason == "LookingStraightUp" then
		if not self:_isLookingStraightUp(plrRoot) then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			local curPlrPos = plrRoot.Position
			local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	end

	-- phase 2: check if initial safe spot exists behind player
	local safeCFrame = self:_getSafeTeleportCFrame(plrRoot, targetPos)
	if not safeCFrame then
		self.isTeleporting = false
		self.currentTeleportReason = nil
		return
	end

	-- phase 3: verification delay (0.5s) to ensure target spot is not temporary
	task.wait(self.VERIFY_SAFE_DELAY)

	if localToken ~= self.teleportToken then
		return
	end

	-- re-check cancellation condition after verification delay
	if reason == "OutOfRange" then
		local curPlrPos = plrRoot.Position
		local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
		if curDist <= self.MAX_TELEPORT_RANGE then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	elseif reason == "VoidOrDeepFall" then
		if self:_checkPathAheadWalkable(plrRoot) then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			local curPlrPos = plrRoot.Position
			local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	elseif reason == "LookingStraightUp" then
		if not self:_isLookingStraightUp(plrRoot) then
			self.isTeleporting = false
			self.currentTeleportReason = nil
			local curPlrPos = plrRoot.Position
			local curDist = self:_getEffectiveDistance(self.rootPart.Position, curPlrPos)
			if curDist <= self.DISTANCE_STOP_FOLLOW then
				self.isFollowing = false
			end
			return
		end
	end

	-- phase 4: re-verify safe spot after verification delay
	local finalSafeCFrame = self:_getSafeTeleportCFrame(plrRoot, plrRoot.Position)
	if not finalSafeCFrame then
		self.isTeleporting = false
		self.currentTeleportReason = nil
		return
	end

	-- phase 5: execute vanish (fade out) -> teleport -> reappear (fade in)
	self:FadeModelTransparency(1.0, self.FADE_DURATION)
	if localToken ~= self.teleportToken then
		self:FadeModelTransparency(0.0, self.FADE_DURATION, true)
		return
	end

	self.rig:PivotTo(finalSafeCFrame)
	self.lastYPosition = finalSafeCFrame.Position.Y
	self.isFalling = false
	self.fallVelocity = 0

	self:FadeModelTransparency(0.0, self.FADE_DURATION, true)
	self.isTeleporting = false
	self.currentTeleportReason = nil
end

function FollowerNPC:_updateGrounding(dt, targetX, targetZ, overrideRayResult)
	local currentPos = self.rootPart.Position
	local rayResult = overrideRayResult

	if not rayResult then
		local rayOrigin = Vector3.new(targetX, currentPos.Y + 5, targetZ)
		rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -self.DEEP_FALL_RAY_LENGTH, 0), raycastParams)
	end

	local targetGroundY = rayResult and (rayResult.Position.Y + self.HIP_HEIGHT) or currentPos.Y
	local nextY = targetGroundY

	-- gravity fall lerp & land animation at end
	local yDrop = self.lastYPosition - targetGroundY
	if yDrop > self.LANDING_DROP_THRESHOLD and not self.isFalling and not self.isLanding then
		self.isFalling = true
		self.fallVelocity = 0
	end

	if self.isFalling then
		-- accelerate downward like gravity
		self.fallVelocity = self.fallVelocity + self.GRAVITY * dt
		nextY = self.lastYPosition - self.fallVelocity * dt

		-- check if ground reached
		if nextY <= targetGroundY then
			nextY = targetGroundY
			self.isFalling = false
			self.fallVelocity = 0

			-- play landing animation ONLY at the end upon ground contact
			self.isLanding = true
			self.landingTime = 0.35
			self:_setAnimState("Land", 0.1)
		end
	elseif self.isLanding then
		self.landingTime = self.landingTime - dt
		if self.landingTime <= 0 then
			self.isLanding = false
		end
	end

	self.lastYPosition = nextY
	return nextY
end

function FollowerNPC:StartFollowing(getTargetPosition)
	if self.renderConn then return end

	local char = plr.Character or plr.CharacterAdded:Wait()
	local plrRoot = char:WaitForChild("HumanoidRootPart", 10)
	if not plrRoot then return end

	-- exclude player character and npc from ground raycasts
	raycastParams:AddToFilter(char)
	raycastParams:AddToFilter(self.rig)

	-- main render loop for client-side follower movement
	self.renderConn = RS.RenderStepped:Connect(function(dt)
		if not self.rig or not self.rig.Parent or not char or not char.Parent then
			self:Stop()
			return
		end

		local getPosResult = getTargetPosition and getTargetPosition()
		local targetPos = getPosResult or plrRoot.Position
		local currentPos = self.rootPart.Position

		-- task 1: calculate horizontal distance with conditional vertical offset threshold
		local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
		local flatTarget = Vector3.new(targetPos.X, 0, targetPos.Z)
		local horizontalDist = (flatTarget - flatCurrent).Magnitude

		local dist = self:_getEffectiveDistance(currentPos, targetPos)

		-- state update for follow distance threshold
		if not self.isFollowing and dist > self.DISTANCE_START_FOLLOW then
			self.isFollowing = true
		elseif self.isFollowing and dist <= self.DISTANCE_STOP_FOLLOW then
			self.isFollowing = false
		end

		-- out of range check: if player moves further than MAX_TELEPORT_RANGE, trigger teleport routine
		if dist > self.MAX_TELEPORT_RANGE then
			if not self.isTeleporting then
				task.spawn(function()
					self:_triggerTeleportSequence(plrRoot, targetPos, "OutOfRange")
				end)
			end
			self:_setAnimState("Idle", 0.35)
			local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
			self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
			return
		end

		-- if teleport is active, hold idle state unless cancellation criteria is met
		if self.isTeleporting then
			if self.currentTeleportReason == "OutOfRange" then
				if dist <= self.MAX_TELEPORT_RANGE then
					self.teleportToken += 1
					self.isTeleporting = false
					self.currentTeleportReason = nil
					if dist <= self.DISTANCE_STOP_FOLLOW then
						self.isFollowing = false
					end
				else
					self:_setAnimState("Idle", 0.35)
					local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
					self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
					return
				end
			elseif self.currentTeleportReason == "VoidOrDeepFall" then
				if self:_checkPathAheadWalkable(plrRoot) then
					self.teleportToken += 1
					self.isTeleporting = false
					self.currentTeleportReason = nil
					if dist <= self.DISTANCE_STOP_FOLLOW then
						self.isFollowing = false
					end
				else
					self:_setAnimState("Idle", 0.35)
					local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
					self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
					return
				end
			elseif self.currentTeleportReason == "LookingStraightUp" then
				if not self:_isLookingStraightUp(plrRoot, self.MIN_LOOK_UP_EXIT_ANGLE) then
					self.teleportToken += 1
					self.isTeleporting = false
					self.currentTeleportReason = nil
					if dist <= self.DISTANCE_STOP_FOLLOW then
						self.isFollowing = false
					end
				else
					self:_setAnimState("Idle", 0.35)
					local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
					self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
					return
				end
			end
		end

		if self.isFollowing then
			if self:_isLookingStraightUp(plrRoot) then
				if not self.isTeleporting then
					task.spawn(function()
						self:_triggerTeleportSequence(plrRoot, targetPos, "LookingStraightUp")
					end)
				end
				self:_setAnimState("Idle", 0.35)
				local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
				self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
				return
			end

			-- calculate move direction on xz plane
			local dir = (flatTarget - flatCurrent).Unit
			local moveStep = dir * (self.MOVE_SPEED * dt)

			-- prevent overshooting target
			if moveStep.Magnitude > horizontalDist then
				moveStep = dir * horizontalDist
			end

			local currentSpeed = moveStep.Magnitude / math.max(dt, 0.001)

			local nextX = currentPos.X + moveStep.X
			local nextZ = currentPos.Z + moveStep.Z

			-- task 3: raycast ahead straight down at proposed position to check for void or deep fall
			-- original raycast for ground position calculation & hysteresis
			local aheadRayOrigin = Vector3.new(nextX + (self.isVoidOrDeepFall and (moveStep.X * self.CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH) or 0), currentPos.Y + 5, nextZ + (self.isVoidOrDeepFall and (moveStep.Z * self.CAUTIOUS_DOUBLE_CHECK_EXTRA_LENGTH) or 0))
			local aheadRayResult = workspace:Raycast(aheadRayOrigin, Vector3.new(0, -self.DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			-- second raycast projected ahead along movement vector for ledge buffer check
			local forwardCheckOrigin = Vector3.new(nextX + dir.X * self.FORWARD_EDGE_BUFFER, currentPos.Y + 5, nextZ + dir.Z * self.FORWARD_EDGE_BUFFER)
			local forwardCheckResult = workspace:Raycast(forwardCheckOrigin, Vector3.new(0, -self.DEEP_FALL_RAY_LENGTH, 0), raycastParams)

			local origIsVoid = not aheadRayResult or ((currentPos.Y - aheadRayResult.Position.Y) > self.MAX_SAFE_FALL_DEPTH)
			local forwardIsVoid = not forwardCheckResult or ((currentPos.Y - forwardCheckResult.Position.Y) > self.MAX_SAFE_FALL_DEPTH)

			if origIsVoid or forwardIsVoid then
				self.isVoidOrDeepFall = true
			else
				self.isVoidOrDeepFall = false
			end

			if self.isVoidOrDeepFall then
				-- void/deep fall detected ahead: trigger delayed teleport routine while remaining idle
				if not self.isTeleporting then
					task.spawn(function()
						self:_triggerTeleportSequence(plrRoot, targetPos, "VoidOrDeepFall")
					end)
				end
				self:_setAnimState("Idle", 0.35)
				local nextY = self:_updateGrounding(dt, currentPos.X, currentPos.Z)
				self.rig:PivotTo(CFrame.new(currentPos.X, nextY, currentPos.Z) * (self.rootPart.CFrame - self.rootPart.CFrame.Position))
				return
			end

			-- safe floor detected ahead
			local nextY = self:_updateGrounding(dt, nextX, nextZ, aheadRayResult)

			-- walk/run animation blending logic
			if not self.isFalling and not self.isLanding then
				if self.hasWalkAnim then
					if currentSpeed > self.RUN_THRESHOLD then
						self:_setAnimState("Run", 0.5)
						self:_setAnimationSpeed(currentSpeed, 12.0)
					elseif currentSpeed > self.SPEED_THRESHOLD then
						self:_setAnimState("Walk", 0.5)
						self:_setAnimationSpeed(currentSpeed, 5.0)
					else
						self:_setAnimState("Idle", 0.35)
					end
				else
					self:_setAnimState("Run", 0.35)
					self:_setAnimationSpeed(currentSpeed, self.MOVE_SPEED)
				end
			end

			self.lastYPosition = nextY
			local nextPos = Vector3.new(nextX, nextY, nextZ)
			local lookTarget = Vector3.new(targetPos.X, nextY, targetPos.Z)

			local horizontalDelta = lookTarget - nextPos
			local currentCFrame = self.rootPart.CFrame
			local lerpedRotation

			if horizontalDelta.Magnitude > 0.01 then
				local targetCFrame = CFrame.lookAt(nextPos, lookTarget)
				lerpedRotation = currentCFrame.Rotation:Lerp(targetCFrame.Rotation, math.clamp(self.TURN_SPEED * dt, 0, 1))
			else
				-- horizontally on top of / directly under the target — no valid direction
				-- to face, so just hold whatever rotation we already had this frame
				lerpedRotation = currentCFrame.Rotation
			end

			self.rig:PivotTo(CFrame.new(nextPos) * lerpedRotation)
		else
			self:_setAnimState("Idle", 0.35)

			-- raycast check to maintain ground position while standing still without rotating
			local rayOrigin = Vector3.new(currentPos.X, currentPos.Y + 5, currentPos.Z)
			local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -20, 0), raycastParams)
			if rayResult then
				local targetY = rayResult.Position.Y + self.HIP_HEIGHT
				if math.abs(currentPos.Y - targetY) > 0.05 then
					local rotCFrame = self.rootPart.CFrame - self.rootPart.CFrame.Position
					self.rig:PivotTo(CFrame.new(currentPos.X, targetY, currentPos.Z) * rotCFrame)
					self.lastYPosition = targetY
				end
			end
		end
	end)
end

function FollowerNPC:Stop()
	if self.renderConn then
		self.renderConn:Disconnect()
		self.renderConn = nil
	end
	self.teleportToken += 1
	self.isTeleporting = false
	self.currentTeleportReason = nil
	self:_setAnimState("Idle", 0.35)
end

function FollowerNPC:Destroy()
	self:Stop()
	for _, tween in pairs(self.TES) do
		if tween and tween.PlaybackState == Enum.PlaybackState.Playing then
			tween:Cancel()
		end
	end
	self.TES = {}
end

return FollowerNPC