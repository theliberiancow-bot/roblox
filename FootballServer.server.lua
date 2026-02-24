-- FootballServer.server.lua (v6)
-- Adds the full "11v11 strict loop" spec into your v5 base:
-- ✅ Field calibration via workspace.Field markers (goal lines + sidelines)
-- ✅ Play lifecycle: PREPLAY → LIVE → DEAD → SPOT
-- ✅ Spotting + ball on + LOS + first down line
-- ✅ Play clock
-- ✅ Forward pass rules (must throw behind LOS; optional disallow past LOS)
-- ✅ Intended receiver bonus + contest radius modifier
-- ✅ Implement PICK + return
-- ✅ Out of bounds (college 1 foot in)
-- ✅ Basic strict formations (toggle)
-- ✅ Catch prompts only when IN_AIR / FUMBLE_LIVE (performance)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------
local folder = ReplicatedStorage:FindFirstChild("FootballRemotes")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "FootballRemotes"
	folder.Parent = ReplicatedStorage
end

local function ensureRemote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local remoteNames = {
	"MoveInput","BlockHold","Juke","Spin","Truck","JumpHighPoint",
	"ThrowChargeStart","ThrowRelease","CatchAttempt","DefensePlayBall",
	"TackleAttempt","SelectPosition","RequestSnap","SpawnBall","SpotBall",
	"BallState","GameState","Outcome","CatchPrompt",
}
local R = {}
for _, n in ipairs(remoteNames) do
	R[n] = ensureRemote(n)
end

---------------------------------------------------------------------
-- Config toggles (friend test)
---------------------------------------------------------------------
local CFG = {
	STRICT_FORMATIONS = true,
	ENABLE_FUMBLE_RECOVERY = true,

	PLAY_CLOCK_SECONDS = 25,

	ALLOW_FORWARD_PASS_PAST_LOS = false, -- if QB crosses LOS, forward pass rejected

	STUDS_PER_FOOT = 1,
	CONTEST_RADIUS = 5,

	INTENDED_RECEIVER_BONUS = 0.10,         -- +chance
	NON_INTENDED_OFFENSE_PENALTY = 0.12,     -- -chance
	DEFENDER_PICK_BONUS = 0.08,              -- +chance on pick action

	PROMPT_TICK_IN_AIR = 0.30,
	DEAD_AUTO_SECONDS_IN_AIR = 4.75,
}

local function clamp01(x:number): number
	if x < 0 then return 0 end
	if x > 1 then return 1 end
	return x
end

---------------------------------------------------------------------
-- Field calibration (workspace.Field markers REQUIRED)
-- Required parts:
-- workspace.Field.GoalLineHome
-- workspace.Field.GoalLineAway
-- workspace.Field.SidelineLeft
-- workspace.Field.SidelineRight
---------------------------------------------------------------------
local FieldFolder = workspace:FindFirstChild("Field")

local function requireFieldPart(name:string): BasePart
	assert(FieldFolder, "workspace.Field folder missing")
	local p = FieldFolder:FindFirstChild(name)
	assert(p and p:IsA("BasePart"), ("workspace.Field.%s missing or not a BasePart"):format(name))
	return p :: BasePart
end

local GoalHome = requireFieldPart("GoalLineHome")
local GoalAway = requireFieldPart("GoalLineAway")
local SideLeft = requireFieldPart("SidelineLeft")
local SideRight= requireFieldPart("SidelineRight")

-- Build a stable field frame:
-- - origin at midfield between goal lines
-- - Z axis points Home -> Away
-- - X axis points left->right across field
local function computeFieldCFrame(): (CFrame, number, number)
	local homePos = GoalHome.Position
	local awayPos = GoalAway.Position
	local mid = (homePos + awayPos) * 0.5

	local forward = (awayPos - homePos)
	forward = Vector3.new(forward.X, 0, forward.Z)
	if forward.Magnitude < 1 then forward = Vector3.new(0,0,1) end
	forward = forward.Unit

	-- derive right axis from sidelines if possible
	local leftPos = SideLeft.Position
	local rightPos = SideRight.Position
	local right = (rightPos - leftPos)
	right = Vector3.new(right.X, 0, right.Z)
	if right.Magnitude < 1 then
		right = forward:Cross(Vector3.new(0,1,0)).Unit
	else
		right = right.Unit
	end

	-- orthonormalize
	right = (right - forward * right:Dot(forward))
	if right.Magnitude < 0.01 then right = forward:Cross(Vector3.new(0,1,0)).Unit end
	right = right.Unit
	local up = Vector3.new(0,1,0)

	local cf = CFrame.fromMatrix(mid, right, up, forward)

	local fieldLengthStuds = (awayPos - homePos).Magnitude
	local fieldWidthStuds = (rightPos - leftPos).Magnitude
	return cf, fieldLengthStuds, fieldWidthStuds
end

local function worldToField(cf:CFrame, worldPos:Vector3): Vector3
	return cf:PointToObjectSpace(worldPos)
end

local function fieldToWorld(cf:CFrame, fieldPos:Vector3): Vector3
	return cf:PointToWorldSpace(fieldPos)
end

-- yardline 0..100 where 0 = Home goal line, 100 = Away goal line
local function yardlineFromWorld(cf:CFrame, fieldLengthStuds:number, worldPos:Vector3): number
	local fp = worldToField(cf, worldPos)
	-- field Z in object space: negative toward home, positive toward away if forward set that way via cf above
	-- Our cf forward is +Z (home->away). Home goal is at -fieldLength/2, Away goal at +fieldLength/2.
	local z = fp.Z
	local zFromHome = z + (fieldLengthStuds/2)
	local yds = (zFromHome / math.max(CFG.STUDS_PER_FOOT, 0.01))
	local totalYds = (fieldLengthStuds / math.max(CFG.STUDS_PER_FOOT, 0.01))
	if totalYds <= 1 then totalYds = 100 end
	local yl = (yds / totalYds) * 100
	return math.clamp(yl, 0, 100)
end

local function worldFromYardline(cf:CFrame, fieldLengthStuds:number, yardline:number, xHash:number?): Vector3
	local totalYds = (fieldLengthStuds / math.max(CFG.STUDS_PER_FOOT, 0.01))
	if totalYds <= 1 then totalYds = 100 end
	local zFromHomeStuds = (yardline / 100) * (totalYds * CFG.STUDS_PER_FOOT)
	local zField = zFromHomeStuds - (fieldLengthStuds/2)
	local x = xHash or 0
	return fieldToWorld(cf, Vector3.new(x, 0, zField))
end

local function isInBounds(cf:CFrame, fieldWidthStuds:number, worldPos:Vector3, feetInside:number): boolean
	local fp = worldToField(cf, worldPos)
	local halfW = fieldWidthStuds/2
	local insideStuds = feetInside * CFG.STUDS_PER_FOOT
	return (fp.X >= (-halfW + insideStuds)) and (fp.X <= (halfW - insideStuds))
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function getHRP(char: Model): BasePart?
	local hrp = char:FindFirstChild("HumanoidRootPart")
	return (hrp and hrp:IsA("BasePart")) and hrp or nil
end

local function getHum(char: Model): Humanoid?
	return char:FindFirstChildOfClass("Humanoid")
end

local function getPlayerByUserId(uid: number): Player?
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == uid then return p end
	end
	return nil
end

---------------------------------------------------------------------
-- Builds + derived ratings (kept from v5)
---------------------------------------------------------------------
type Range = {min:number, max:number}
type BuildDef = {height:Range, weight:Range}

local BUILDS: {[string]: BuildDef} = {
	QB = {height={min=70, max=80}, weight={min=185, max=260}},
	RB = {height={min=66, max=74}, weight={min=175, max=235}},
	WR = {height={min=68, max=79}, weight={min=165, max=230}},
	TE = {height={min=74, max=82}, weight={min=220, max=270}},
	OL = {height={min=74, max=80}, weight={min=270, max=370}},
	DL = {height={min=73, max=80}, weight={min=250, max=360}},
	LB = {height={min=70, max=78}, weight={min=210, max=260}},
	CB = {height={min=66, max=75}, weight={min=160, max=200}},
	FS = {height={min=67, max=76}, weight={min=170, max=210}},
	SS = {height={min=68, max=77}, weight={min=180, max=220}},
}

local function randInt(r: Range): number
	return math.random(r.min, r.max)
end

local function setBuildForCharacter(char: Model, pos: string)
	local def = BUILDS[pos]
	if not def then return end

	local h = randInt(def.height)
	local w = randInt(def.weight)

	char:SetAttribute("Position", pos)
	char:SetAttribute("HeightIn", h)
	char:SetAttribute("WeightLb", w)

	local strength = (w ^ 0.60) * (h ^ 0.25)
	local strengthRating = math.clamp(strength / 4.0, 45, 140)

	local baseArm = (pos == "QB") and 92 or ((pos == "WR" or pos == "TE") and 62 or 50)
	local sizeFactor = math.clamp(((h - 70) / 12) * 0.10 + ((w - 180) / 190) * 0.10, -0.10, 0.20)
	local throwPower = math.clamp(baseArm * (1 + sizeFactor), 40, 112)

	local catchRadius = math.clamp(2.0 + (h - 66) * 0.06, 2.0, 3.2)
	local catchStrength = math.clamp((w / 220) * 90, 45, 120)

	local pbuRange = (pos == "FS") and 16 or ((pos == "CB") and 12 or 10)

	char:SetAttribute("Strength", strengthRating)
	char:SetAttribute("ThrowPower", throwPower)
	char:SetAttribute("CatchRadius", catchRadius)
	char:SetAttribute("CatchStrength", catchStrength)
	char:SetAttribute("PBURange", pbuRange)

	local hum = getHum(char)
	if hum then
		local speedAdj = math.clamp((200 - w) / 200 * 2.2, -2.2, 2.2)
		hum.WalkSpeed = 16 + speedAdj
	end
end

---------------------------------------------------------------------
-- Side assignment (no Teams UI)
---------------------------------------------------------------------
local flip = false
local function assignSide(plr: Player)
	flip = not flip
	local side = flip and "HOME" or "AWAY"
	plr:SetAttribute("Side", side)
end

---------------------------------------------------------------------
-- Football object
---------------------------------------------------------------------
local BALL_NAME = "Football"
local football: BasePart? = nil

local function ensureFootball(): BasePart
	if football and football.Parent then return football end

	local p = Instance.new("Part")
	p.Name = BALL_NAME
	p.Shape = Enum.PartType.Block
	p.Size = Vector3.new(1.2, 1.1, 2.2)
	p.Color = Color3.fromRGB(120, 70, 40)
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = true
	p.Anchored = false
	p.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5)
	p.Position = Vector3.new(0, 10, 0)
	p.Parent = workspace

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(1.0, 0.9, 1.6)
	mesh.Parent = p

	local stripe = Instance.new("Decal")
	stripe.Face = Enum.NormalId.Top
	stripe.Color3 = Color3.fromRGB(235, 235, 235)
	stripe.Transparency = 0.65
	stripe.Parent = p

	football = p
	return p
end

local function clearBallWeld(ball: BasePart)
	for _, d in ipairs(ball:GetChildren()) do
		if d:IsA("WeldConstraint") and d.Name == "BallWeld" then
			d:Destroy()
		end
	end
end

local function attachBallToCarrier(ball: BasePart, char: Model)
	clearBallWeld(ball)
	local hrp = getHRP(char)
	if not hrp then return end

	ball.AssemblyLinearVelocity = Vector3.new()
	ball.AssemblyAngularVelocity = Vector3.new()
	ball.CFrame = hrp.CFrame * CFrame.new(0.8, 0.8, -0.8) * CFrame.Angles(0, math.rad(90), math.rad(15))

	local weld = Instance.new("WeldConstraint")
	weld.Name = "BallWeld"
	weld.Part0 = ball
	weld.Part1 = hrp
	weld.Parent = ball
end

---------------------------------------------------------------------
-- League game state (v6)
---------------------------------------------------------------------
local homeScore = 0
local awayScore = 0
local quarter = 1
local clock = 12*60

local phase = "PREPLAY"  -- PREPLAY | LIVE | DEAD | SPOT
local playClock = CFG.PLAY_CLOCK_SECONDS

local down = 1
local toGo = 10

local possession: "HOME"|"AWAY" = "HOME" -- offense team
local ballStatus = "SPOTTED" -- SPOTTED | SNAPPED | IN_AIR | CAUGHT | PICKED | FUMBLE_LIVE | DEAD

local ballCarrierUserId: number? = nil
local ballInAir = false

local losYardline = 50.0
local ballOnYardline = 50.0
local firstDownYardline = 60.0

local forwardPassUsed = false
local forwardPassAllowed = true
local lastThrowWasForward = false
local intendedTargetUserId: number? = nil

local fieldCF, fieldLengthStuds, fieldWidthStuds = computeFieldCFrame()

local function yardText(y:number): string
	y = math.floor(y + 0.5)
	return tostring(y)
end

local function ballOnText(): string
	-- simple "Ball 37" display (0..100 scale)
	return yardText(ballOnYardline)
end

local function playClockText(): string
	return tostring(math.max(0, math.floor(playClock + 0.5)))
end

local function forwardPassAllowedText(): string
	return forwardPassAllowed and "OK" or "NO"
end

local function losWorld(): Vector3
	local p = worldFromYardline(fieldCF, fieldLengthStuds, losYardline, 0)
	return Vector3.new(p.X, 3.2, p.Z)
end

local function fdWorld(): Vector3
	local p = worldFromYardline(fieldCF, fieldLengthStuds, firstDownYardline, 0)
	return Vector3.new(p.X, 3.2, p.Z)
end

local function broadcastGameState()
	R.GameState:FireAllClients({
		phase = phase,
		clock = clock,
		quarter = quarter,
		down = down,
		toGo = toGo,
		homeScore = homeScore,
		awayScore = awayScore,
		ballOnText = ballOnText(),
		playClockText = playClockText(),
	})
end

local function setBallState()
	R.BallState:FireAllClients({
		possession = possession,
		ballStatus = ballStatus,
		forwardPassAllowedText = forwardPassAllowedText(),
		ballOnText = ballOnText(),
		playClockText = playClockText(),
		losWorld = losWorld(),
		fdWorld = fdWorld(),
	})
end

local function resetPlayFlags()
	forwardPassUsed = false
	lastThrowWasForward = false
	intendedTargetUserId = nil
	forwardPassAllowed = true
end

local function setPhase(newPhase:string)
	phase = newPhase
	if phase == "PREPLAY" then
		playClock = CFG.PLAY_CLOCK_SECONDS
	end
	broadcastGameState()
	setBallState()
end

---------------------------------------------------------------------
-- Spotting
---------------------------------------------------------------------
local function placeBallAtYardline(y:number)
	local ball = ensureFootball()
	clearBallWeld(ball)
	ballCarrierUserId = nil
	ballInAir = false

	ballOnYardline = math.clamp(y, 0, 100)
	losYardline = ballOnYardline
	firstDownYardline = math.clamp(losYardline + toGo, 0, 100)

	local pos = worldFromYardline(fieldCF, fieldLengthStuds, ballOnYardline, 0)
	ball.CFrame = CFrame.new(pos.X, 3.0, pos.Z)
	ball.AssemblyLinearVelocity = Vector3.new()
	ball.AssemblyAngularVelocity = Vector3.new()

	ballStatus = "SPOTTED"
	resetPlayFlags()
	setBallState()
end

local function turnover()
	possession = (possession == "HOME") and "AWAY" or "HOME"
	down = 1
	toGo = 10
end

local function gainedYards(fromY:number, toY:number): number
	-- offense always moves Home -> Away in this simplified build (since yardline is 0..100)
	return (toY - fromY)
end

local function endPlayAtWorldSpot(worldPos:Vector3, reason:string?)
	local prevLOS = losYardline
	local newY = yardlineFromWorld(fieldCF, fieldLengthStuds, worldPos)
	newY = math.clamp(newY, 0, 100)

	-- stop ball
	local ball = ensureFootball()
	clearBallWeld(ball)
	ballCarrierUserId = nil
	ballInAir = false
	ballStatus = "DEAD"

	-- down/dist update
	local gain = gainedYards(prevLOS, newY)
	local gotFirst = (gain >= toGo - 0.001)

	if gotFirst then
		down = 1
		toGo = math.min(10, math.max(1, 100 - newY))
	else
		down += 1
		toGo = math.max(1, toGo - math.floor(gain + 0.5))
		if down >= 5 then
			turnover()
		end
	end

	ballOnYardline = newY

	setPhase("SPOT")
	task.delay(0.25, function()
		placeBallAtYardline(ballOnYardline)
		setPhase("PREPLAY")
	end)

	if reason then
		R.Outcome:FireAllClients({type="DEV_HELP", data={lines={("Play dead: %s"):format(reason)}}})
	end
end

---------------------------------------------------------------------
-- Basic strict formation checks
---------------------------------------------------------------------
local function formationOk(qb:Player): (boolean, string?)
	if not CFG.STRICT_FORMATIONS then return true, nil end
	if phase ~= "PREPLAY" then return false, "Not PREPLAY" end

	-- offense/defense based on possession
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local hrp = char and getHRP(char)
		if hrp then
			local isOff = (p:GetAttribute("Side") == possession)
			local yl = yardlineFromWorld(fieldCF, fieldLengthStuds, hrp.Position)

			if isOff then
				-- offense beyond LOS by > 0.5 yards = offsides
				if yl > (losYardline + 0.5) then
					return false, "OFFSIDES (OFFENSE)"
				end
			else
				-- defense inside neutral zone: within 1 yard of LOS (past LOS - 1)
				if yl > (losYardline - 1.0) then
					return false, "DEFENSE IN NEUTRAL ZONE"
				end
			end
		end
	end
	return true, nil
end

---------------------------------------------------------------------
-- OL block + grapple (unchanged v5 logic)
---------------------------------------------------------------------
type BlockState = {holding:boolean, meter:number, mode:"NORMAL"|"GRAPPLE"}
local blockState: {[number]: BlockState} = {}
local grappleCooldown: {[Model]: number} = {}

local function applyKnockdown(targetChar: Model, duration: number)
	local hum = getHum(targetChar)
	if not hum then return end
	hum:ChangeState(Enum.HumanoidStateType.Physics)
	hum.AutoRotate = false
	task.delay(duration, function()
		if hum and hum.Parent then
			hum.AutoRotate = true
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
end

local function applyImpulse(attackerChar: Model, targetChar: Model, hitstick: boolean)
	local a = getHRP(attackerChar)
	local t = getHRP(targetChar)
	if not a or not t then return end
	pcall(function() t:SetNetworkOwner(nil) end)

	local aw = attackerChar:GetAttribute("WeightLb"); if typeof(aw)~="number" then aw = 200 end
	local tw = targetChar:GetAttribute("WeightLb"); if typeof(tw)~="number" then tw = 200 end
	local aStr = attackerChar:GetAttribute("Strength"); if typeof(aStr)~="number" then aStr = 80 end

	local dir = Vector3.new(t.Position.X - a.Position.X, 0, t.Position.Z - a.Position.Z)
	if dir.Magnitude < 0.01 then dir = a.CFrame.LookVector end
	dir = dir.Unit

	local weightFactor = math.clamp((aw / math.max(tw, 1)), 0.6, 1.65)
	local strengthFactor = math.clamp(aStr / 90, 0.6, 1.65)
	local base = hitstick and 1150 or 850

	local impulseMag = base * weightFactor * strengthFactor
	t:ApplyImpulse(dir * impulseMag + Vector3.new(0, hitstick and 520 or 320, 0))
	applyKnockdown(targetChar, hitstick and 0.80 or 0.55)
end

local function tryGrappleLock(blockerChar: Model, defenderChar: Model, meter: number)
	local now = os.clock()
	local last = grappleCooldown[defenderChar] or 0
	if now - last < 1.25 then return end

	local bHrp = getHRP(blockerChar)
	local dHrp = getHRP(defenderChar)
	if not bHrp or not dHrp then return end
	if meter < 0.45 then return end

	local bw = blockerChar:GetAttribute("WeightLb"); if typeof(bw)~="number" then bw = 280 end
	local dw = defenderChar:GetAttribute("WeightLb"); if typeof(dw)~="number" then dw = 200 end
	local bStr = blockerChar:GetAttribute("Strength"); if typeof(bStr)~="number" then bStr = 110 end
	local dStr = defenderChar:GetAttribute("Strength"); if typeof(dStr)~="number" then dStr = 80 end

	local weightEdge = math.clamp((bw - dw) / 140, -1.0, 1.3)
	local strEdge = math.clamp((bStr - dStr) / 70, -1.0, 1.3)
	local score = 0.35 + 0.35*weightEdge + 0.30*strEdge + 0.20*(meter - 0.5)
	local chance = math.clamp(score, 0.10, 0.80)
	if math.random() > chance then return end

	grappleCooldown[defenderChar] = now

	local holder = Instance.new("Folder")
	holder.Name = "GrappleHold"
	holder.Parent = defenderChar

	local a0 = Instance.new("Attachment")
	a0.Parent = dHrp

	local targetAtt = Instance.new("Attachment")
	targetAtt.Parent = bHrp
	targetAtt.Position = Vector3.new(0, 0, -2.2)

	local alignPos = Instance.new("AlignPosition")
	alignPos.Attachment0 = a0
	alignPos.Attachment1 = targetAtt
	alignPos.MaxForce = 38000
	alignPos.Responsiveness = 45
	alignPos.Parent = holder

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Attachment0 = a0
	alignOri.Attachment1 = targetAtt
	alignOri.MaxTorque = 38000
	alignOri.Responsiveness = 45
	alignOri.Parent = holder

	local push = (0.25 + 0.55 * meter)
	dHrp:ApplyImpulse((bHrp.CFrame.LookVector) * (-240 * push) + Vector3.new(0,45,0))
	bHrp:ApplyImpulse((bHrp.CFrame.LookVector) * (180 * push))

	local lockTime = 1.05 + 0.45 * meter
	task.delay(lockTime, function()
		if holder and holder.Parent then holder:Destroy() end
	end)

	task.spawn(function()
		local start = os.clock()
		while holder.Parent do
			task.wait(0.15)
			local dBreak = math.clamp((dStr / math.max(bStr, 1)) * 0.18 + (dw / math.max(bw, 1)) * 0.10, 0.05, 0.35)
			dBreak = math.clamp(dBreak - 0.12 * meter, 0.02, 0.30)
			if math.random() < dBreak then
				holder:Destroy()
				break
			end
			if os.clock() - start > lockTime then break end
		end
	end)
end

---------------------------------------------------------------------
-- Catch prompts (only while IN_AIR / FUMBLE_LIVE)
---------------------------------------------------------------------
local function sendCatchPrompts()
	if not (ballStatus == "IN_AIR" or ballStatus == "FUMBLE_LIVE") then
		for _, plr in ipairs(Players:GetPlayers()) do
			R.CatchPrompt:FireClient(plr, {canCatch=false, canSwat=false, canPick=false})
		end
		return
	end

	local ball = ensureFootball()
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and getHRP(char)
		if not hrp or not char then
			R.CatchPrompt:FireClient(plr, {canCatch=false, canSwat=false, canPick=false})
			continue
		end

		local dist = (hrp.Position - ball.Position).Magnitude
		local catchRadius = char:GetAttribute("CatchRadius")
		if typeof(catchRadius) ~= "number" then catchRadius = 2.5 end

		local near = (ballCarrierUserId == nil) and (dist <= (6 + catchRadius))
		local canCatchHere = near and (ballStatus == "IN_AIR" or ballStatus == "FUMBLE_LIVE")
		R.CatchPrompt:FireClient(plr, {canCatch=canCatchHere, canSwat=near and (ballStatus=="IN_AIR"), canPick=near and (ballStatus=="IN_AIR")})
	end
end

task.spawn(function()
	while true do
		task.wait(CFG.PROMPT_TICK_IN_AIR)
		sendCatchPrompts()
	end
end)

---------------------------------------------------------------------
-- Block touch (pancake + grapple)
---------------------------------------------------------------------
local touchConn: {[Model]: RBXScriptConnection} = {}

local function connectBlockTouch(char: Model)
	if touchConn[char] then touchConn[char]:Disconnect() end
	local hrp = getHRP(char)
	if not hrp then return end

	touchConn[char] = hrp.Touched:Connect(function(otherPart)
		local otherChar = otherPart:FindFirstAncestorWhichIsA("Model")
		if not otherChar or otherChar == char then return end

		local aPlr = Players:GetPlayerFromCharacter(char)
		local bPlr = Players:GetPlayerFromCharacter(otherChar)
		if not aPlr or not bPlr then return end

		local aState = blockState[aPlr.UserId]
		if not aState or not aState.holding then return end
		if aPlr:GetAttribute("FB_Position") ~= "OL" then return end

		local meter = clamp01(aState.meter)

		if aState.mode == "GRAPPLE" then
			tryGrappleLock(char, otherChar, meter)
		end

		local aW = char:GetAttribute("WeightLb"); if typeof(aW)~="number" then aW = 280 end
		local bW = otherChar:GetAttribute("WeightLb"); if typeof(bW)~="number" then bW = 200 end
		local aStr = char:GetAttribute("Strength"); if typeof(aStr)~="number" then aStr = 110 end
		local bStr = otherChar:GetAttribute("Strength"); if typeof(bStr)~="number" then bStr = 80 end

		local weightEdge = math.clamp((aW - bW) / 120, -1.0, 1.25)
		local strEdge = math.clamp((aStr - bStr) / 60, -1.0, 1.25)
		local meterEdge = (meter - 0.35) * 1.1

		local score = weightEdge * 0.55 + strEdge * 0.35 + meterEdge * 0.35
		local chance = math.clamp(0.10 + score * 0.40, 0.05, 0.75)

		if otherChar:GetAttribute("RecentlyPancaked") == true then return end
		if math.random() < chance then
			otherChar:SetAttribute("RecentlyPancaked", true)
			task.delay(1.0, function()
				if otherChar and otherChar.Parent then
					otherChar:SetAttribute("RecentlyPancaked", false)
				end
			end)
			applyImpulse(char, otherChar, false)
		end
	end)
end

---------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------
Players.PlayerAdded:Connect(function(plr)
	assignSide(plr)
	plr:SetAttribute("FB_Position", "CB")

	plr.CharacterAdded:Connect(function(char)
		task.wait(0.1)
		local pos = plr:GetAttribute("FB_Position")
		if typeof(pos) ~= "string" then pos = "CB" end
		setBuildForCharacter(char, pos)
		connectBlockTouch(char)
		ensureFootball()
		setBallState()
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	blockState[plr.UserId] = nil
	if ballCarrierUserId == plr.UserId then
		ballCarrierUserId = nil
	end
end)

---------------------------------------------------------------------
-- Main clock loop + play clock (v6)
---------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(1)

		-- recompute field frame occasionally (if markers moved during dev)
		fieldCF, fieldLengthStuds, fieldWidthStuds = computeFieldCFrame()

		clock -= 1
		if clock <= 0 then
			clock = 12*60
			quarter = math.min(4, quarter + 1)
		end

		if phase == "PREPLAY" then
			playClock -= 1
			if playClock <= 0 then
				-- delay of game = dead/spot at same LOS
				endPlayAtWorldSpot(worldFromYardline(fieldCF, fieldLengthStuds, losYardline, 0), "Delay of game")
			end
		end

		broadcastGameState()
		setBallState()
	end
end)

---------------------------------------------------------------------
-- Out-of-bounds checks + end of play checks
---------------------------------------------------------------------
RunService.Heartbeat:Connect(function()
	if phase ~= "LIVE" then return end

	-- if carrier out of bounds -> dead
	if ballCarrierUserId then
		local p = getPlayerByUserId(ballCarrierUserId)
		local char = p and p.Character
		local hrp = char and getHRP(char)
		if hrp then
			if not isInBounds(fieldCF, fieldWidthStuds, hrp.Position, 1) then
				endPlayAtWorldSpot(hrp.Position, "Out of bounds")
			end
		end
	end
end)

---------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------
R.SelectPosition.OnServerEvent:Connect(function(plr, payload)
	local pos = payload and payload.pos
	if typeof(pos) ~= "string" then return end
	if not BUILDS[pos] then return end

	plr:SetAttribute("FB_Position", pos)
	if plr.Character then
		setBuildForCharacter(plr.Character, pos)
		connectBlockTouch(plr.Character)
	end
end)

R.BlockHold.OnServerEvent:Connect(function(plr, payload)
	local holding = (payload and payload.holding) == true
	local meter = payload and payload.meter
	if typeof(meter) ~= "number" then meter = 0 end
	meter = clamp01(meter)

	local mode = payload and payload.mode
	if mode ~= "GRAPPLE" and mode ~= "NORMAL" then mode = "NORMAL" end

	blockState[plr.UserId] = {holding=holding, meter=meter, mode=mode}
end)

-- Dev/test spawn ball in front
R.SpawnBall.OnServerEvent:Connect(function(plr)
	local ball = ensureFootball()
	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	clearBallWeld(ball)
	ballCarrierUserId = nil
	ballInAir = false
	ballStatus = "DEAD"

	ball.CFrame = hrp.CFrame * CFrame.new(0, 2.5, -4)
	ball.AssemblyLinearVelocity = Vector3.new()
	ball.AssemblyAngularVelocity = Vector3.new()

	setBallState()
end)

-- Spot ball to midfield (drive reset)
R.SpotBall.OnServerEvent:Connect(function()
	down = 1
	toGo = 10
	possession = "HOME"
	placeBallAtYardline(50)
	setPhase("PREPLAY")
end)

-- Snap: requires PREPLAY, formation checks, assigns QB as carrier
R.RequestSnap.OnServerEvent:Connect(function(plr)
	if phase ~= "PREPLAY" then return end

	-- choose QB on offense side
	local side = possession
	local qb: Player? = nil
	for _, p in ipairs(Players:GetPlayers()) do
		if p:GetAttribute("Side") == side and p:GetAttribute("FB_Position") == "QB" then
			qb = p
			break
		end
	end
	qb = qb or plr

	local ok, reason = formationOk(qb)
	if not ok then
		if reason then
			R.Outcome:FireAllClients({type="DEV_HELP", data={lines={reason}}})
		end
		return
	end

	local ball = ensureFootball()
	local char = qb.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	clearBallWeld(ball)
	ball.CFrame = hrp.CFrame * CFrame.new(0, 0.2, -2.0)
	ball.AssemblyLinearVelocity = Vector3.new()
	ball.AssemblyAngularVelocity = Vector3.new()

	ballCarrierUserId = qb.UserId
	ballInAir = false
	ballStatus = "SNAPPED"
	attachBallToCarrier(ball, char)

	resetPlayFlags()
	setPhase("LIVE")
	setBallState()
end)

R.ThrowChargeStart.OnServerEvent:Connect(function() end)

-- Throw (only carrier throws; forward-pass rules + intended target)
R.ThrowRelease.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	local ball = ensureFootball()
	if ballCarrierUserId ~= plr.UserId then return end

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then return end

	local aimPos = payload and payload.aimPos
	if typeof(aimPos) ~= "Vector3" then return end

	local power = payload and payload.power
	if typeof(power) ~= "number" then power = 0 end
	power = clamp01(power)

	local throwType = payload and payload.throwType
	if typeof(throwType) ~= "string" then throwType = "TOUCH" end

	-- forward pass eligibility: must release behind LOS
	local qbYL = yardlineFromWorld(fieldCF, fieldLengthStuds, hrp.Position)
	forwardPassAllowed = (qbYL <= losYardline + 0.01)

	if not forwardPassAllowed and not CFG.ALLOW_FORWARD_PASS_PAST_LOS then
		-- reject
		R.Outcome:FireClient(plr, {type="DEV_HELP", data={lines={"Forward pass not allowed past LOS"}}})
		setBallState()
		return
	end

	if forwardPassUsed and forwardPassAllowed then
		R.Outcome:FireClient(plr, {type="DEV_HELP", data={lines={"Forward pass already used"}}})
		return
	end

	-- set intended target (server will verify later)
	local intended = payload and payload.intendedTargetUserId
	if typeof(intended) == "number" then
		intendedTargetUserId = intended
	else
		intendedTargetUserId = nil
	end

	local tp = char:GetAttribute("ThrowPower")
	if typeof(tp) ~= "number" then tp = 70 end

	local mult = (throwType == "BULLET") and 1.18 or ((throwType == "LOB") and 0.86 or 1.00)
	local speed = (tp * (0.35 + 0.65 * power) * mult)

	local dir = (aimPos - hrp.Position)
	if dir.Magnitude < 2 then dir = hrp.CFrame.LookVector end
	dir = dir.Unit

	local upBoost = (throwType == "LOB") and 0.60 or ((throwType == "TOUCH") and 0.36 or 0.20)
	local vel = (dir + Vector3.new(0, upBoost, 0)).Unit * (speed * 1.25)

	clearBallWeld(ball)
	ball.CFrame = hrp.CFrame * CFrame.new(0.8, 0.9, -1.7) * CFrame.Angles(0, math.rad(90), 0)
	ball.AssemblyLinearVelocity = vel
	ball.AssemblyAngularVelocity = Vector3.new(0, 14, 0)

	ballCarrierUserId = nil
	ballInAir = true
	ballStatus = "IN_AIR"
	setBallState()

	-- mark forward pass usage if released behind LOS (forward attempt)
	if forwardPassAllowed then
		forwardPassUsed = true
		lastThrowWasForward = true
	else
		lastThrowWasForward = false
	end

	-- auto-dead if no catch/pick
	task.delay(CFG.DEAD_AUTO_SECONDS_IN_AIR, function()
		if ballInAir and ballCarrierUserId == nil and ballStatus == "IN_AIR" then
			ballInAir = false
			ballStatus = "DEAD"
			-- spot at ball position (incomplete)
			endPlayAtWorldSpot(ball.Position, "Incomplete / no catch")
		end
	end)
end)

-- Catch / Recovery attempt (intended receiver + contest modifier)
R.CatchAttempt.OnServerEvent:Connect(function(plr, payload)
	local ball = ensureFootball()
	if not (ballStatus == "IN_AIR" or ballStatus == "FUMBLE_LIVE") then return end
	if ballCarrierUserId ~= nil then return end

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then return end

	local dist = (hrp.Position - ball.Position).Magnitude
	local catchRadius = char:GetAttribute("CatchRadius")
	if typeof(catchRadius) ~= "number" then catchRadius = 2.5 end
	if dist > (6 + catchRadius) then return end

	local mode = payload and payload.mode
	if typeof(mode) ~= "string" then mode = "SECURE" end

	-- base chance
	local cs = char:GetAttribute("CatchStrength"); if typeof(cs)~="number" then cs = 80 end
	local base = (mode == "SECURE") and 0.80 or ((mode == "RAC") and 0.70 or 0.60)
	if ballStatus == "FUMBLE_LIVE" then
		base = 0.88 -- recovery easier than contested catch
	end

	local sizeBonus = math.clamp((cs - 75) / 100, -0.10, 0.18)
	local speedPenalty = math.clamp(ball.AssemblyLinearVelocity.Magnitude / 240, 0, 0.26)
	local chance = math.clamp(base + sizeBonus - speedPenalty, 0.10, 0.95)

	-- intended receiver logic (only applies for IN_AIR)
	if ballStatus == "IN_AIR" and intendedTargetUserId then
		if plr.UserId == intendedTargetUserId then
			chance = math.clamp(chance + CFG.INTENDED_RECEIVER_BONUS, 0.10, 0.98)
		else
			-- non-intended offensive penalty (only if on same team as passer's team = possession)
			if plr:GetAttribute("Side") == possession then
				chance = math.clamp(chance - CFG.NON_INTENDED_OFFENSE_PENALTY, 0.05, 0.98)
			end
		end
	end

	-- contest modifier: nearest defender within radius reduces chance
	local nearestDef = 999
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr and p:GetAttribute("Side") ~= plr:GetAttribute("Side") then
			local c2 = p.Character
			local h2 = c2 and getHRP(c2)
			if h2 then
				local d2 = (h2.Position - hrp.Position).Magnitude
				if d2 < nearestDef then nearestDef = d2 end
			end
		end
	end
	if nearestDef <= CFG.CONTEST_RADIUS then
		local penalty = math.clamp((CFG.CONTEST_RADIUS - nearestDef) / CFG.CONTEST_RADIUS, 0, 1) * 0.16
		chance = math.clamp(chance - penalty, 0.05, 0.98)
	end

	-- out-of-bounds rule at completion (1 foot in)
	if not isInBounds(fieldCF, fieldWidthStuds, hrp.Position, 1) then
		-- ruled out
		ballInAir = false
		ballStatus = "DEAD"
		endPlayAtWorldSpot(hrp.Position, "Out-of-bounds catch attempt")
		return
	end

	if math.random() > chance then return end

	ballCarrierUserId = plr.UserId
	ballInAir = false
	ballStatus = "CAUGHT"
	attachBallToCarrier(ball, char)

	-- possession stays offense unless defender actually got it (pbu/pick handles that)
	possession = plr:GetAttribute("Side") == "HOME" and "HOME" or "AWAY"
	setBallState()
end)

-- Defense play ball: PBU, SWAT, PICK + return
R.DefensePlayBall.OnServerEvent:Connect(function(plr, payload)
	local action = payload and payload.action
	if action ~= "PBU" and action ~= "SWAT" and action ~= "PICK" then return end

	local ball = ensureFootball()
	local char = plr.Character
	local hrp = char and getHRP(char)
	if not ball or not hrp or not char then return end
	if ballStatus ~= "IN_AIR" or ballCarrierUserId ~= nil then return end

	local pos = plr:GetAttribute("FB_Position")
	local range = char:GetAttribute("PBURange")
	if typeof(range) ~= "number" then range = (pos=="FS") and 16 or 10 end

	local dist = (hrp.Position - ball.Position).Magnitude

	if action == "PBU" and (pos == "CB" or pos == "FS") and dist <= range then
		ball.AssemblyLinearVelocity = Vector3.new(0, -18, 0)
		ballInAir = false
		ballStatus = "DEAD"
		endPlayAtWorldSpot(ball.Position, "PBU")
		return
	end

	if action == "SWAT" and dist <= (range - 2) then
		local v = ball.AssemblyLinearVelocity
		if v.Magnitude > 1 then
			ball.AssemblyLinearVelocity = (v.Unit + Vector3.new(0, 0.35, 0)).Unit * 45
		else
			ball.AssemblyLinearVelocity = Vector3.new(0, 22, 0)
		end
		ballInAir = false
		ballStatus = "DEAD"
		endPlayAtWorldSpot(ball.Position, "Swat")
		return
	end

	if action == "PICK" and dist <= (range - 1) then
		-- pick chance (positioning + small bonus)
		local pickChance = 0.55 + CFG.DEFENDER_PICK_BONUS
		-- if defender very close, boost
		pickChance += math.clamp((range - dist) / math.max(range,1), 0, 1) * 0.15
		pickChance = math.clamp(pickChance, 0.20, 0.92)

		if math.random() > pickChance then return end

		-- Interception: defender becomes carrier, possession flips immediately
		ballCarrierUserId = plr.UserId
		ballInAir = false
		ballStatus = "PICKED"

		possession = (plr:GetAttribute("Side") == "HOME") and "HOME" or "AWAY"
		attachBallToCarrier(ball, char)
		setBallState()
		return
	end
end)

-- Tackling: impulse + down OR fumble live (toggle)
R.TackleAttempt.OnServerEvent:Connect(function(plr, payload)
	local targetUserId = payload and payload.targetUserId
	local hitstick = (payload and payload.hitstick) == true
	if typeof(targetUserId) ~= "number" then return end

	local targetPlr = getPlayerByUserId(targetUserId)
	if not targetPlr or targetPlr == plr then return end

	local aChar = plr.Character
	local tChar = targetPlr.Character
	if not aChar or not tChar then return end

	local aHrp = getHRP(aChar)
	local tHrp = getHRP(tChar)
	if not aHrp or not tHrp then return end

	if (aHrp.Position - tHrp.Position).Magnitude > 10 then return end

	applyImpulse(aChar, tChar, hitstick)

	if phase ~= "LIVE" then return end

	-- if tackled player is ball carrier: either down or fumble live
	if ballCarrierUserId == targetPlr.UserId then
		local ball = ensureFootball()

		if CFG.ENABLE_FUMBLE_RECOVERY and math.random() < (hitstick and 0.55 or 0.28) then
			-- fumble live
			clearBallWeld(ball)
			ball.CFrame = tHrp.CFrame * CFrame.new(0, 0.9, -1.0)
			ball.AssemblyLinearVelocity = aHrp.CFrame.LookVector * 12 + Vector3.new(0, 10, 0)
			ball.AssemblyAngularVelocity = Vector3.new(0, 18, 0)

			ballCarrierUserId = nil
			ballInAir = false
			ballStatus = "FUMBLE_LIVE"
			setBallState()

			-- if not recovered quickly, dead + spot at ball
			task.delay(3.0, function()
				if ballStatus == "FUMBLE_LIVE" and ballCarrierUserId == nil then
					ballStatus = "DEAD"
					endPlayAtWorldSpot(ball.Position, "Fumble dead")
				end
			end)
		else
			-- down by contact
			endPlayAtWorldSpot(tHrp.Position, "Tackle")
		end
	end
end)

---------------------------------------------------------------------
-- No-ops kept for compatibility (movement/moves handled elsewhere)
---------------------------------------------------------------------
for _, name in ipairs({"MoveInput","Juke","Spin","Truck","JumpHighPoint"}) do
	R[name].OnServerEvent:Connect(function() end)
end

---------------------------------------------------------------------
-- Initial setup
---------------------------------------------------------------------
task.delay(0.25, function()
	ensureFootball()
	placeBallAtYardline(50)
	setPhase("PREPLAY")
	broadcastGameState()
	setBallState()
end)
