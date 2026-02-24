-- FootballClient.client.lua (v6)
-- Adds: play clock + ball-on + ballStatus clarity, intended receiver lock (QB), LOS/1st-down lines (client-only),
-- forward-pass-allowed indicator, cleaner prompts (only when server says), keeps v5 controls.

-- Controls:
-- P = position menu
-- H = toggle help
-- G = spawn/reset ball (dev/testing)
-- C = snap
-- 1/2/3 = bullet/touch/lob
-- LMB hold/release = throw
-- E/R/F = secure/aggressive/RAC catch
-- Q = role action
-- T = swat, Y = pick
-- RMB = tackle target under mouse

--!strict
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer
local mouse = plr:GetMouse()

local remotes = ReplicatedStorage:WaitForChild("FootballRemotes")
local MoveInput        = remotes:WaitForChild("MoveInput")
local BlockHold        = remotes:WaitForChild("BlockHold")
local Juke             = remotes:WaitForChild("Juke")
local Spin             = remotes:WaitForChild("Spin")
local Truck            = remotes:WaitForChild("Truck")
local JumpHighPoint    = remotes:WaitForChild("JumpHighPoint")
local ThrowChargeStart = remotes:WaitForChild("ThrowChargeStart")
local ThrowRelease     = remotes:WaitForChild("ThrowRelease")
local CatchAttempt     = remotes:WaitForChild("CatchAttempt")
local DefensePlayBall  = remotes:WaitForChild("DefensePlayBall")
local TackleAttempt    = remotes:WaitForChild("TackleAttempt")
local SelectPosition   = remotes:WaitForChild("SelectPosition")
local RequestSnap      = remotes:WaitForChild("RequestSnap")
local SpawnBall        = remotes:WaitForChild("SpawnBall")
local SpotBall         = remotes:WaitForChild("SpotBall")

local GameState        = remotes:WaitForChild("GameState")
local Outcome          = remotes:WaitForChild("Outcome")
local CatchPrompt      = remotes:WaitForChild("CatchPrompt")
local BallState        = remotes:WaitForChild("BallState")

---------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FootballUI"
gui.ResetOnSpawn = false
gui.Parent = plr:WaitForChild("PlayerGui")

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: Instance, t: number, a: number)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Transparency = a
	s.Parent = inst
end

local function mkFrame(name:string, size:UDim2, pos:UDim2, bg:Color3, alpha:number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = bg
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	f.Parent = gui
	return f
end

local function mkLabel(parent:Instance, text:string, size:UDim2, pos:UDim2, xAlign:Enum.TextXAlignment, scaled:boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.Text = text
	l.Size = size
	l.Position = pos
	l.BackgroundTransparency = 1
	l.TextScaled = (scaled ~= false)
	l.TextWrapped = true
	l.Font = Enum.Font.GothamBold
	l.TextColor3 = Color3.fromRGB(255,255,255)
	l.TextXAlignment = xAlign
	l.Parent = parent
	return l
end

local function mkButton(parent:Instance, text:string, size:UDim2, pos:UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
	b.BackgroundTransparency = 0.05
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextScaled = true
	b.TextColor3 = Color3.fromRGB(255,255,255)
	b.Parent = parent
	corner(b, 10)
	stroke(b, 1, 0.65)
	return b
end

local function getPos(): string
	local p = plr:GetAttribute("FB_Position")
	return (typeof(p)=="string") and p or "CB"
end

local function getBuildString(): string
	local char = plr.Character
	if not char then return "" end
	local h = char:GetAttribute("HeightIn")
	local w = char:GetAttribute("WeightLb")
	if typeof(h)~="number" or typeof(w)~="number" then return "" end
	return string.format("%s | %din %dlb", getPos(), h, w)
end

local function formatClock(sec:number): string
	sec = math.max(0, math.floor(sec + 0.5))
	local m = math.floor(sec/60)
	local s = sec % 60
	return string.format("%d:%02d", m, s)
end

---------------------------------------------------------------------
-- CLEAN UI
---------------------------------------------------------------------
local bg = Color3.fromRGB(14, 14, 18)

local top = mkFrame("TopBar", UDim2.fromScale(0.78, 0.075), UDim2.fromScale(0.11, 0.02), bg, 0.05)
corner(top, 16); stroke(top, 1, 0.55)

local homeLbl = mkLabel(top, "HOME 0", UDim2.fromScale(0.20,1), UDim2.fromScale(0.02,0), Enum.TextXAlignment.Left, true)
local midLbl  = mkLabel(top, "Q1 12:00 | PREPLAY | 1 & 10 | Ball -- | PC --", UDim2.fromScale(0.60,1), UDim2.fromScale(0.20,0), Enum.TextXAlignment.Center, true)
local awayLbl = mkLabel(top, "AWAY 0", UDim2.fromScale(0.20,1), UDim2.fromScale(0.78,0), Enum.TextXAlignment.Right, true)

local sub = mkFrame("SubBar", UDim2.fromScale(0.48, 0.05), UDim2.fromScale(0.26, 0.105), bg, 0.15)
corner(sub, 14); stroke(sub, 1, 0.70)
local subLbl = mkLabel(sub, "Build: -- | Poss: -- | Ball: -- | FP: --", UDim2.fromScale(1,1), UDim2.fromScale(0,0), Enum.TextXAlignment.Center, true)

local hint = mkFrame("HintBar", UDim2.fromScale(0.68, 0.05), UDim2.fromScale(0.16, 0.91), bg, 0.15)
corner(hint, 14); stroke(hint, 1, 0.70)
local hintLbl = mkLabel(hint, "", UDim2.fromScale(1,1), UDim2.fromScale(0,0), Enum.TextXAlignment.Center, true)

local help = mkFrame("Help", UDim2.fromScale(0.24, 0.15), UDim2.fromScale(0.02, 0.80), bg, 0.15)
corner(help, 14); stroke(help, 1, 0.70)
local helpLbl = mkLabel(help,
	"H help | P pos | G ball | C snap\nLMB throw (hold) | RMB tackle\nE/R/F catch | 1/2/3 throw type\nQ role | T swat | Y pick\nZ juke | B spin | V truck\nQB: aim at receiver to lock target",
	UDim2.fromScale(1,1), UDim2.fromScale(0,0), Enum.TextXAlignment.Left, true
)

local helpVisible = true

---------------------------------------------------------------------
-- Position UI (P)
---------------------------------------------------------------------
local posUI = mkFrame("PosUI", UDim2.fromScale(0.40, 0.44), UDim2.fromScale(0.30, 0.28), bg, 0.02)
corner(posUI, 18); stroke(posUI, 1, 0.55)
posUI.Visible = false
mkLabel(posUI, "Choose Position", UDim2.fromScale(1,0.14), UDim2.fromScale(0,0), Enum.TextXAlignment.Center, true)

local OFF_POS = {"QB","RB","WR","TE","OL"}
local DEF_POS = {"DL","LB","CB","FS","SS"}
mkLabel(posUI, "OFFENSE", UDim2.fromScale(0.48,0.10), UDim2.fromScale(0.02,0.14), Enum.TextXAlignment.Left, true)
mkLabel(posUI, "DEFENSE", UDim2.fromScale(0.48,0.10), UDim2.fromScale(0.50,0.14), Enum.TextXAlignment.Left, true)

local function addPosButtons(list:{string}, x0:number)
	for i,p in ipairs(list) do
		local btn = mkButton(posUI, p, UDim2.fromScale(0.46,0.12), UDim2.fromScale(x0, 0.26 + (i-1)*0.13))
		btn.MouseButton1Click:Connect(function()
			SelectPosition:FireServer({pos=p})
			posUI.Visible = false
		end)
	end
end
addPosButtons(OFF_POS, 0.02)
addPosButtons(DEF_POS, 0.52)
mkButton(posUI, "Close", UDim2.fromScale(0.25,0.12), UDim2.fromScale(0.375,0.86)).MouseButton1Click:Connect(function()
	posUI.Visible = false
end)

---------------------------------------------------------------------
-- Client-only field lines (LOS + 1st down)
---------------------------------------------------------------------
local cam = workspace.CurrentCamera

local function mkLinePart(name:string): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 0.55
	p.Material = Enum.Material.Neon
	p.Size = Vector3.new(120, 0.1, 0.1)
	p.Parent = cam -- client-only
	return p
end

local losLine = mkLinePart("LOS_Line")
local fdLine  = mkLinePart("FD_Line")

local function setLineVisible(p:BasePart, vis:boolean)
	p.Transparency = vis and 0.55 or 1
end

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local canCatch = false
local grappleMode = false

local blocking = false
local blockStart = 0
local lastBlockSend = 0

local wrCatchMode = "SECURE"
local chargingThrow = false
local throwStart = 0
local throwType = "TOUCH"

local possText = "--"
local ballText = "--"
local forwardPassText = "--"
local ballOnText = "--"
local playClockText = "--"
local losWorldPos: Vector3? = nil
local fdWorldPos: Vector3? = nil

local function updateHint()
	local pos = getPos()
	local build = getBuildString()

	if pos == "QB" then
		hintLbl.Text = "QB: C snap | 1/2/3 type | hold LMB to throw | aim at WR/TE/RB to lock target"
	elseif pos == "OL" then
		hintLbl.Text = string.format("OL: hold X block | Q grapple:%s | collide to engage", grappleMode and "ON" or "OFF")
	elseif pos == "WR" then
		if canCatch then
			hintLbl.Text = string.format("WR: Q attempt (%s) | E/R/F also", wrCatchMode)
		else
			hintLbl.Text = string.format("WR: Q toggle SECURE/AGG (now %s)", wrCatchMode)
		end
	elseif pos == "TE" then
		hintLbl.Text = "TE: Q secure catch (window) | E/R/F also"
	elseif pos == "RB" then
		hintLbl.Text = "RB: V truck | Z juke | B spin | Q RAC catch (window)"
	elseif pos == "CB" then
		hintLbl.Text = "CB: Q PBU | T swat | Y pick | RMB tackle"
	elseif pos == "FS" then
		hintLbl.Text = "FS: Q range PBU | T swat | Y pick | RMB tackle"
	else
		hintLbl.Text = "RMB tackle | T swat | Y pick | E/R/F catch"
	end

	subLbl.Text = string.format("Build: %s | Poss: %s | Ball: %s | FP: %s",
		(build ~= "" and build or "--"),
		possText, ballText, forwardPassText
	)
end

CatchPrompt.OnClientEvent:Connect(function(payload)
	if typeof(payload)~="table" then return end
	canCatch = payload.canCatch == true
	updateHint()
end)

BallState.OnClientEvent:Connect(function(payload)
	if typeof(payload)~="table" then return end
	possText = tostring(payload.possession or "--")
	ballText = tostring(payload.ballStatus or "--")
	forwardPassText = tostring(payload.forwardPassAllowedText or "--")
	ballOnText = tostring(payload.ballOnText or "--")
	playClockText = tostring(payload.playClockText or "--")

	if typeof(payload.losWorld) == "Vector3" then losWorldPos = payload.losWorld else losWorldPos = nil end
	if typeof(payload.fdWorld) == "Vector3" then fdWorldPos = payload.fdWorld else fdWorldPos = nil end

	updateHint()
end)

GameState.OnClientEvent:Connect(function(payload)
	if typeof(payload)~="table" then return end
	local phase = tostring(payload.phase or "PREPLAY")
	local clock = tonumber(payload.clock or 0) or 0
	local qtr = tonumber(payload.quarter or 1) or 1
	local down = tonumber(payload.down or 1) or 1
	local toGo = tonumber(payload.toGo or 10) or 10

	local homeScore = tonumber(payload.homeScore or 0) or 0
	local awayScore = tonumber(payload.awayScore or 0) or 0

	local ballOn = tostring(payload.ballOnText or ballOnText or "--")
	local pc = tostring(payload.playClockText or playClockText or "--")

	homeLbl.Text = string.format("HOME %d", homeScore)
	awayLbl.Text = string.format("AWAY %d", awayScore)
	midLbl.Text = string.format("Q%d %s | %s | %d & %d | Ball %s | PC %s", qtr, formatClock(clock), phase, down, toGo, ballOn, pc)

	updateHint()
end)

Outcome.OnClientEvent:Connect(function(payload)
	if typeof(payload)~="table" then return end
	if payload.type == "DEV_HELP" then
		local data = payload.data
		if typeof(data)=="table" and typeof(data.lines)=="table" then
			for _, line in ipairs(data.lines) do
				print("[FB HELP]", line)
			end
		end
	end
end)

---------------------------------------------------------------------
-- RenderStep: update LOS/FD lines (client-only)
---------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	if not cam then cam = workspace.CurrentCamera end
	if not cam then return end

	if losWorldPos then
		losLine.CFrame = CFrame.new(losWorldPos) * CFrame.Angles(0, 0, 0)
		setLineVisible(losLine, true)
	else
		setLineVisible(losLine, false)
	end

	if fdWorldPos then
		fdLine.CFrame = CFrame.new(fdWorldPos) * CFrame.Angles(0, 0, 0)
		setLineVisible(fdLine, true)
	else
		setLineVisible(fdLine, false)
	end
end)

---------------------------------------------------------------------
-- Movement input (throttled)
---------------------------------------------------------------------
local lastSend = 0
local SEND_HZ = 20
local lastDir = Vector3.new()

RunService.RenderStepped:Connect(function()
	local now = os.clock()
	if now - lastSend < (1 / SEND_HZ) then return end

	local cam2 = workspace.CurrentCamera
	if not cam2 then return end
	local forward = Vector3.new(cam2.CFrame.LookVector.X, 0, cam2.CFrame.LookVector.Z)
	local right   = Vector3.new(cam2.CFrame.RightVector.X, 0, cam2.CFrame.RightVector.Z)
	if forward.Magnitude > 0 then forward = forward.Unit end
	if right.Magnitude > 0 then right = right.Unit end

	local dir = Vector3.new()
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= forward end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += right end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= right end
	if dir.Magnitude > 1 then dir = dir.Unit end

	if (dir - lastDir).Magnitude < 0.15 and not (dir.Magnitude == 0 and lastDir.Magnitude > 0) then return end

	lastDir = dir
	lastSend = now
	MoveInput:FireServer({dir=dir})
end)

---------------------------------------------------------------------
-- OL block meter sending
---------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
	if blocking then
		local now = os.clock()
		if now - lastBlockSend > 0.10 then
			lastBlockSend = now
			local meter = math.clamp((now - blockStart) / 0.75, 0, 1)
			BlockHold:FireServer({holding=true, meter=meter, mode=grappleMode and "GRAPPLE" or "NORMAL"})
		end
	end
end)

local function getAimPos(): Vector3?
	local ok, cf = pcall(function() return mouse.Hit end)
	if not ok or typeof(cf) ~= "CFrame" then return nil end
	return cf.Position
end

local function getAimedPlayerUserId(): number?
	local t = mouse.Target
	if not t then return nil end
	local model = t:FindFirstAncestorWhichIsA("Model")
	if not model then return nil end
	local tp = Players:GetPlayerFromCharacter(model)
	if tp then return tp.UserId end
	return nil
end

---------------------------------------------------------------------
-- Chat commands
---------------------------------------------------------------------
plr.Chatted:Connect(function(msg)
	local m = string.lower(msg)
	if m == "/ball" or m == "!ball" then
		SpawnBall:FireServer()
	elseif m == "/spot" or m == "!spot" then
		SpotBall:FireServer()
	end
end)

---------------------------------------------------------------------
-- Inputs
---------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end

	if input.KeyCode == Enum.KeyCode.H then
		helpVisible = not helpVisible
		help.Visible = helpVisible
	end

	if input.KeyCode == Enum.KeyCode.P then posUI.Visible = not posUI.Visible end

	-- Spawn/reset ball (dev/testing)
	if input.KeyCode == Enum.KeyCode.G then SpawnBall:FireServer() end
	-- Snap
	if input.KeyCode == Enum.KeyCode.C then RequestSnap:FireServer() end

	-- throw types
	if input.KeyCode == Enum.KeyCode.One then throwType="BULLET" end
	if input.KeyCode == Enum.KeyCode.Two then throwType="TOUCH" end
	if input.KeyCode == Enum.KeyCode.Three then throwType="LOB" end

	-- moves
	if input.KeyCode == Enum.KeyCode.Z then Juke:FireServer({}) end
	if input.KeyCode == Enum.KeyCode.B then Spin:FireServer({}) end
	if input.KeyCode == Enum.KeyCode.V then Truck:FireServer({}) end
	if input.KeyCode == Enum.KeyCode.Space then JumpHighPoint:FireServer({}) end

	-- catches
	if input.KeyCode == Enum.KeyCode.E then CatchAttempt:FireServer({mode="SECURE"}) end
	if input.KeyCode == Enum.KeyCode.R then CatchAttempt:FireServer({mode="AGG"}) end
	if input.KeyCode == Enum.KeyCode.F then CatchAttempt:FireServer({mode="RAC"}) end

	-- defense
	if input.KeyCode == Enum.KeyCode.T then DefensePlayBall:FireServer({action="SWAT"}) end
	if input.KeyCode == Enum.KeyCode.Y then DefensePlayBall:FireServer({action="PICK"}) end

	-- Q role action
	if input.KeyCode == Enum.KeyCode.Q then
		local pos = getPos()
		if pos == "OL" then
			grappleMode = not grappleMode
			BlockHold:FireServer({holding=blocking, meter=0, mode=grappleMode and "GRAPPLE" or "NORMAL"})
			updateHint()
			return
		end
		if pos == "WR" then
			if canCatch then
				CatchAttempt:FireServer({mode=wrCatchMode})
			else
				wrCatchMode = (wrCatchMode == "SECURE") and "AGG" or "SECURE"
				updateHint()
			end
			return
		end
		if pos == "TE" then
			if canCatch then CatchAttempt:FireServer({mode="SECURE"}) end
			return
		end
		if pos == "RB" then
			if canCatch then CatchAttempt:FireServer({mode="RAC"}) end
			return
		end
		if pos == "CB" then
			DefensePlayBall:FireServer({action="PBU", range="NORMAL"})
			return
		end
		if pos == "FS" then
			DefensePlayBall:FireServer({action="PBU", range="DEEP"})
			return
		end
	end

	-- OL block X
	if input.KeyCode == Enum.KeyCode.X and getPos() == "OL" then
		blocking = true
		blockStart = os.clock()
		lastBlockSend = 0
		BlockHold:FireServer({holding=true, meter=0, mode=grappleMode and "GRAPPLE" or "NORMAL"})
	end

	-- throw charge (LMB)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not posUI.Visible then
		chargingThrow = true
		throwStart = os.clock()
		ThrowChargeStart:FireServer({throwType=throwType})
	end
end)

UserInputService.InputEnded:Connect(function(input, gpe)
	if gpe then return end

	-- OL block release
	if input.KeyCode == Enum.KeyCode.X and blocking then
		blocking = false
		BlockHold:FireServer({holding=false, meter=0, mode=grappleMode and "GRAPPLE" or "NORMAL"})
	end

	-- throw release
	if input.UserInputType == Enum.UserInputType.MouseButton1 and chargingThrow then
		chargingThrow = false
		local aimPos = getAimPos()
		if not aimPos then return end

		local power = math.clamp((os.clock() - throwStart) / 1.10, 0, 1)

		-- QB intended target lock (aim at player)
		local intended: number? = nil
		if getPos() == "QB" then
			intended = getAimedPlayerUserId()
		end

		ThrowRelease:FireServer({
			aimPos=aimPos,
			throwType=throwType,
			power=power,
			intendedTargetUserId=intended,
		})
	end
end)

-- tackle RMB
mouse.Button2Down:Connect(function()
	local t = mouse.Target
	if not t then return end
	local model = t:FindFirstAncestorWhichIsA("Model")
	if not model then return end
	local tp = Players:GetPlayerFromCharacter(model)
	if tp then
		TackleAttempt:FireServer({targetUserId=tp.UserId, hitstick=false})
	end
end)

-- initial
updateHint()
