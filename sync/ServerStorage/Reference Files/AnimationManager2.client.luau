-- Services
local RPS = game:GetService("ReplicatedStorage")

-- Constants
local SPEED_THRESHOLD = 0.75
local RUN_THRESHOLD = 8

local JUMP_ANIM_TIME = 0
local JUMP_ANIM_DURATION = 0.31

local FALL_TRANSITION_TIME = 0.2

local currentlyPlayingEmote = false

-- Dependancies
local plr = game.Players.LocalPlayer
repeat wait() until plr.Character ~= nil
local char = plr.Character

local found = char:WaitForChild("Animate", 5)
if found then
	found:Destroy()
end

local Storage = RPS:WaitForChild("ClientStorage")
local f1, f2, f3, f4, f5 = script:WaitForChild("PlayAnim"), script:WaitForChild("SetPose"), script:WaitForChild("LoadDefaults"), script:WaitForChild("LoadAnimationPack"), script:WaitForChild("ToggleAllOverworldAnims")
local ev = script:WaitForChild("Update")
local hum = char:WaitForChild("Humanoid")
local amitor = hum:WaitForChild("Animator")
local pose = "Idle"


local anims = script.Anims

local currentAnim = nil
local currentAnimObject = nil
local currentAnimObject2 = nil
local overworldAnimsPaused = false

math.randomseed(tick())

-- Local Functions
function loadDefaults()
	for i, v in pairs(Storage:WaitForChild("Animations").AnimationPacks.Default:GetChildren()) do
		local found = anims:FindFirstChild(v.Name)
		if found then
			v:Clone().Parent = found.Parent
			found.Parent = RPS
			coroutine.wrap(function()
				task.wait(10)
				found:Destroy()
			end)()
		end
	end
end

function loadAnimationPack(pack)
	--local mine = {}
	for i, v in pairs(pack:GetChildren()) do
		local found = anims:FindFirstChild(v.Name)
		if found then
			v:Clone().Parent = found.Parent
			found.Parent = RPS
			--table.insert(mine, found)
			--found.Name = "_trash_"
			coroutine.wrap(function()
				task.wait(10)
				found:Destroy()
			end)()
		else
			v:Clone().Parent = anims
		end
		--table.insert(mine, v)
	end
	
	if not pack:FindFirstChild("Tertiary") then
		if anims:FindFirstChild("Tertiary") then
			anims:FindFirstChild("Tertiary"):Destroy()
		end
	end
	--for i, v in pairs(anims:GetChildren()) do
	--	if table.find(mine, v) then continue end
	--	--v.Name = "_trash_"
	--	coroutine.wrap(function()
	--		task.wait(10)
	--		v:Destroy()
	--	end)()
	--end
end

function getAnim(anim)
	return anims:FindFirstChild(anim)
end

function stopAllAnims()
	for i,v in pairs(amitor:GetPlayingAnimationTracks()) do
		v:Stop()
	end
end

function toggleAllOverworldAnims(on, animToPlay)
	if not on then
		overworldAnimsPaused = true
		stopAllAnims()
	else
		overworldAnimsPaused = false
		if animToPlay then
			playAnim(animToPlay, 0)
		else
			playAnim("Idle", 0)
		end
	end
end

--local function switchToAnim(anim, animName, transitionTime--[[, hum]]anoid)
--	-- switch animation		
--	if (anim ~= currentAnimInstance) then

--		if (currentAnimObject ~= nil) then
--			currentAnimObject:Stop(transitionTime)
--			currentAnimObject:Destroy()
--		end

--		if (runAnimTrack ~= nil) then
--			runAnimTrack:Stop(transitionTime)
--			runAnimTrack:Destroy()
--			if userNoUpdateOnLoop == true then
--				runAnimTrack = nil
--			end
--		end

--		currentAnimSpeed = 1.0

--		-- load it to the humanoid; get AnimationTrack
--		currentAnimObject = humanoid:LoadAnimation(anim)
--		currentAnimObject.Priority = Enum.AnimationPriority.Core

--		-- play the animation
--		currentAnimObject:Play(transitionTime)
--		currentAnim = animName
--		currentAnimInstance = anim

--		-- set up keyframe name triggers
--		if (currentAnimKeyframeHandler ~= nil) then
--			currentAnimKeyframeHandler:disconnect()
--		end
--		currentAnimKeyframeHandler = currentAnimObject.KeyframeReached:connect(keyFrameReachedFunc)

--		-- check to see if we need to blend a walk/run animation
--		if animName == "walk" then
--			local runAnimName = "run"
--			local runIdx = rollAnimation(runAnimName)

--			runAnimTrack = humanoid:LoadAnimation(animTable[runAnimName][runIdx].anim)
--			runAnimTrack.Priority = Enum.AnimationPriority.Core
--			runAnimTrack:Play(transitionTime)		

--			if (runAnimKeyframeHandler ~= nil) then
--				runAnimKeyframeHandler:disconnect()
--			end
--			runAnimKeyframeHandler = runAnimTrack.KeyframeReached:connect(keyFrameReachedFunc)	
--		end
--	end
--end

function playAnim(anim, transitionTime, old)
	--print(currentAnim)
	--print(anim)
	if overworldAnimsPaused or (not anim or anim == "None" or not getAnim(anim)) or ( (currentAnim == anim and currentAnimObject.isPlaying) and currentAnimObject.Animation.AnimationId == getAnim(anim).AnimationId) then --[[print(currentAnimObject.isPlaying)]] return --[[{(not getAnim(anim)), currentAnim == anim, currentAnimObject.Animation.AnimationId == getAnim(anim).AnimationId}]] end
	--if (not getAnim(anim)) or (currentAnim == anim and currentAnimObject.Animation.AnimationId == getAnim(anim).AnimationId) then --[[print(anim)]] return end
	--print("playing - "..anim)
	
	local oldSpeed = nil
	if old then
		--oldSpeed = Instance.new("Animator"):LoadAnimation().Speed
		oldSpeed = currentAnimObject.Speed
	end
	
	if currentAnimObject then
		if currentAnimObject.isPlaying then
			currentAnimObject:Stop(transitionTime or 0.2)
		end
	end
	if currentAnimObject2 then
		if currentAnimObject2.isPlaying then
			currentAnimObject2:Stop(transitionTime or 0.2)
		end
	end
	
	currentAnim = anim
	script:SetAttribute("CurrentAnim", anim)
	
	currentAnimObject = amitor:LoadAnimation(getAnim(anim))
	currentAnimObject:Play((transitionTime or 0.2)/2)

	if anim == "Walk" or anim == "Run" then
		currentAnimObject2 = amitor:LoadAnimation(getAnim(anim.."(Legs)"))
		currentAnimObject2:Play((transitionTime or 0.2)/2)

		if oldSpeed then currentAnimObject2:AdjustSpeed(oldSpeed) end
	end
	
	if oldSpeed then currentAnimObject:AdjustSpeed(oldSpeed) end
	return currentAnimObject
end

function setPose(newPose)
	pose = newPose
end

function setAnimationSpeed(speed)
	currentAnimObject:AdjustSpeed(speed)
	if currentAnimObject2 then
		currentAnimObject2:AdjustSpeed(speed)
	end
end

-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------
-- STATE CHANGE HANDLERS

function onRunning(speed)
	--print("fired")
	if speed > RUN_THRESHOLD and hum.WalkSpeed > RUN_THRESHOLD then
		local scale = 12.0
		playAnim("Run", 0.5--[[, hum]])
		--Instance.new("Animator"):LoadAnimation():pla
		--print("runlked")
		setAnimationSpeed(speed / scale)
		pose = "Running"
	elseif speed > SPEED_THRESHOLD then
		local scale = 5.0
		if pose == "Running" then
			playAnim("Walk", 0.5--[[, hum]])
		else
			playAnim("Walk", 0.65--[[, hum]])
		end
		--print("walked")
		setAnimationSpeed(speed / scale)
		pose = "Running"
	else
		playAnim("Idle", 0.35--[[, hum]])
		pose = "Idle"
	end
end

function onDied()
	pose = "Dead"
end

function onJumping()
	playAnim("Jump", 0.1--[[, hum]])
	JUMP_ANIM_TIME = JUMP_ANIM_DURATION
	pose = "Jumping"
end

function onClimbing(speed)
	local scale = 5.0
	playAnim("Climb", 0.1--[[, hum]])
	setAnimationSpeed(speed / scale)
	pose = "Climbing"
end

function onGettingUp()
	pose = "GettingUp"
end

function onFreeFall()
	if (JUMP_ANIM_TIME <= 0) then
		playAnim("Fall", FALL_TRANSITION_TIME--[[, hum]])
	end
	pose = "FreeFall"
end

function onFallingDown()
	pose = "FallingDown"
end

function onSeated()
	pose = "Seated"
end

function onPlatformStanding()
	pose = "PlatformStanding"
end

function onSwimming(speed)
	if speed > 1.00 then
		local scale = 10.0
		playAnim("Swim", 0.4--[[, hum]])
		setAnimationSpeed(speed / scale)
		pose = "Swimming"
	else
		playAnim("swimidle", 0.4--[[, hum]])
		pose = "Idle"
	end
end
-------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------


local lastTick = 0

function stepAnimate(currentTime)
	local amplitude = 1
	local frequency = 1
  	local deltaTime = currentTime - lastTick
  	lastTick = currentTime

	local climbFudge = 0
	local setAngles = false

  	if (JUMP_ANIM_TIME > 0) then
  		JUMP_ANIM_TIME = JUMP_ANIM_TIME - deltaTime
  	end

	if (pose == "FreeFall" and JUMP_ANIM_TIME <= 0) then
		playAnim("Fall", FALL_TRANSITION_TIME--[[, hum]])
	elseif (pose == "Seated") then
		playAnim("Sit", 0.5--[[, hum]])
		return
	--elseif (pose == "Running") then
	--	playAnim("Walk", 0.2--[[, hum]])
	elseif (pose == "Dead" or pose == "GettingUp" or pose == "FallingDown" or pose == "Seated" or pose == "PlatformStanding") then
		stopAllAnims()
		amplitude = 0.1
		frequency = 1
		setAngles = true
	end
end

-- Connection
hum.Died:connect(onDied)
hum.Running:connect(onRunning)
hum.Jumping:connect(onJumping)
hum.Climbing:connect(onClimbing)
hum.GettingUp:connect(onGettingUp)
hum.FreeFalling:connect(onFreeFall)
hum.FallingDown:connect(onFallingDown)
hum.Seated:connect(onSeated)
hum.PlatformStanding:connect(onPlatformStanding)
hum.Swimming:connect(onSwimming)

ev.Event:Connect(function()
	--print(hum:GetState())
	--if hum:GetState() == Enum.HumanoidStateType.FallingDown then
	--	repeat wait() print(hum:GetState()) until hum:GetState() ~= Enum.HumanoidStateType.FallingDown 
	--	if hum:GetState() == Enum.HumanoidStateType.Running then
	--		print(hum.MoveDirection.Magnitude)	
	--		onRunning(hum.MoveDirection.Magnitude)
	--	end
	--end
end)

-- Loose Threads
loadDefaults()

f1.OnInvoke = playAnim
f2.OnInvoke = setPose
f3.OnInvoke = loadDefaults
f4.OnInvoke = loadAnimationPack
f5.OnInvoke = toggleAllOverworldAnims

--coroutine.wrap(function()
--	while wait() do
--		if currentAnimObject then
--			print(currentAnimObject.Animation.AnimationId)
--		end
--	end
--end)()

if char.Parent ~= nil then
	-- initialize to idle
	playAnim("Idle", 0.1--[[, hum]])
	pose = "Idle"
end

-- loop to handle timed state transitions and tool animations
while char.Parent ~= nil do
	local _, currentGameTime = wait(0.1)
	stepAnimate(currentGameTime)
end
