-- client script to measure distance from map center (0, 0, 0) and display in a clean screen gui
local PLRS = game:GetService("Players")
local RS = game:GetService("RunService")

local plr = PLRS.LocalPlayer
local pgui = plr:WaitForChild("PlayerGui")

-- create screen gui and container frame
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DistanceTrackerGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = pgui

local frame = Instance.new("Frame")
frame.Name = "Container"
frame.Size = UDim2.new(0, 240, 0, 48)
frame.Position = UDim2.new(0.5, -120, 0.05, 0)
frame.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
frame.BackgroundTransparency = 0.2
frame.BorderSizePixel = 0
frame.Parent = screenGui

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 10)
uiCorner.Parent = frame

local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(0, 170, 255)
uiStroke.Thickness = 1.5
uiStroke.Transparency = 0.3
uiStroke.Parent = frame

local label = Instance.new("TextLabel")
label.Name = "DistanceLabel"
label.Size = UDim2.new(1, 0, 1, 0)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextSize = 15
label.Text = "Distance from Center: 0.0 studs"
label.Parent = frame

local centerPos = Vector3.new(0, 0, 0)

-- update distance text label every render frame
RS.RenderStepped:Connect(function()
	local char = plr.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local flatPos = Vector3.new(root.Position.X, 0, root.Position.Z)
	local dist = (flatPos - centerPos).Magnitude
	label.Text = string.format("Distance from Center: %.1f studs", dist)
end)
