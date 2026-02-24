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

	-- Evasion move config
	JUKE_COOLDOWN = 1.5,
	SPIN_COOLDOWN = 1.8,
	TRUCK_COOLDOWN = 1.2,
}

local function clamp01(x:number): number
	if x < 0 then return 0 end
	if x > 1 then return 1 end
	return x
end

-- Returns the horizontal unit vector from `from` toward `to`, falling back to
-- `fallback` when the two points are too close to distinguish.
local function horizontalUnit(from: Vector3, to: Vector3, fallback: Vector3): Vector3
	local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	return d.Magnitude >= 0.01 and d.Unit or fallback.Unit
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

-- Defense modifier applied by PBU/SWAT actions to reduce catch chance
local defenseModifier = 0.0

-- Evasion move cooldowns per userId
local jukeCooldown: {[number]: number} = {}
local spinCooldown: {[number]: number} = {}
local truckCooldown: {[number]: number} = {}

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
	defenseModifier = 0.0
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

-- Incomplete pass: no gain, spot at LOS, advance down
local function incompletePass()
	local ball = ensureFootball()
	clearBallWeld(ball)
	ballCarrierUserId = nil
	ballInAir = false
	ballStatus = "DEAD"

	-- no yards gained; advance down
	down += 1
	toGo = math.max(1, toGo)
	if down >= 5 then
		turnover()
	end

	ballOnYardline = losYardline

	R.Outcome:FireAllClients({type="INCOMPLETE", data={lines={"Incomplete pass"}}})

	setPhase("SPOT")
	task.delay(0.25, function()
		placeBallAtYardline(losYardline)
		setPhase("PREPLAY")
	end)
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

	local dir = horizontalUnit(a.Position, t.Position, a.CFrame.LookVector)

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
-- Build the CatchPrompt payload for a single player given the current ball.
local function catchPromptForPlayer(plr: Player, ball: BasePart): {[string]: any}
	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then
		return {canCatch=false, canSwat=false, canPick=false}
	end

	local dist = (hrp.Position - ball.Position).Magnitude
	local catchRadius = char:GetAttribute("CatchRadius")
	if typeof(catchRadius) ~= "number" then catchRadius = 2.5 end

	local near = (ballCarrierUserId == nil) and (dist <= (6 + catchRadius))
	local canCatchHere = near and (ballStatus == "IN_AIR" or ballStatus == "FUMBLE_LIVE")
	return {
		canCatch = canCatchHere,
		canSwat  = near and (ballStatus == "IN_AIR"),
		canPick  = near and (ballStatus == "IN_AIR"),
	}
end

local function sendCatchPrompts()
	if not (ballStatus == "IN_AIR" or ballStatus == "FUMBLE_LIVE") then
		for _, plr in ipairs(Players:GetPlayers()) do
			R.CatchPrompt:FireClient(plr, {canCatch=false, canSwat=false, canPick=false})
		end
		return
	end

	local ball = ensureFootball()
	for _, plr in ipairs(Players:GetPlayers()) do
		R.CatchPrompt:FireClient(plr, catchPromptForPlayer(plr, ball))
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
	jukeCooldown[plr.UserId] = nil
	spinCooldown[plr.UserId] = nil
	truckCooldown[plr.UserId] = nil
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
-- Auto-dead: ball in air too long
---------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(0.5)
		if ballStatus == "IN_AIR" and ballInAir then
			local ball = ensureFootball()
			-- if ball has been out longer than DEAD_AUTO_SECONDS_IN_AIR, incomplete
			-- tracked via ballAirTime attribute on the ball
			local airTime = ball:GetAttribute("AirTime")
			if typeof(airTime) == "number" then
				if (os.clock() - airTime) >= CFG.DEAD_AUTO_SECONDS_IN_AIR then
					incompletePass()
				end
			end
		end
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

	-- if ball in air goes out of bounds -> incomplete
	if ballInAir and ballStatus == "IN_AIR" then
		local ball = ensureFootball()
		if not isInBounds(fieldCF, fieldWidthStuds, ball.Position, 0) then
			incompletePass()
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
		R.Outcome:FireClient(plr, {type="DEV_HELP", data={lines={"Forward pass not allowed past LOS"}}})
		setBallState()
		return
	end

	if forwardPassUsed and forwardPassAllowed then
		R.Outcome:FireClient(plr, {type="DEV_HELP", data={lines={"Forward pass already used"}}})
		return
	end

	-- set intended target (server will verify on catch)
	local intended = payload and payload.intendedTargetUserId
	if typeof(intended) == "number" then
		intendedTargetUserId = intended
	else
		intendedTargetUserId = nil
	end

	-- determine if this is a forward pass
	local aimYL = yardlineFromWorld(fieldCF, fieldLengthStuds, aimPos)
	lastThrowWasForward = (aimYL > qbYL)

	if lastThrowWasForward then
		forwardPassUsed = true
	end

	-- release ball from carrier
	clearBallWeld(ball)
	ballCarrierUserId = nil

	-- compute throw velocity
	local throwPower = char:GetAttribute("ThrowPower")
	if typeof(throwPower) ~= "number" then throwPower = 70 end

	-- speed scales from 40 to 110 studs/s based on power and ThrowPower rating
	local minSpeed = 30
	local maxSpeed = 110
	local ratedSpeed = math.clamp(throwPower * 1.05, minSpeed, maxSpeed)
	local throwSpeed = ratedSpeed * (0.55 + 0.45 * power)

	-- adjust aim slightly upward for arc (touch throws arc more)
	local arcFactor = (throwType == "TOUCH") and 0.22 or 0.10
	local releasePos = hrp.Position + Vector3.new(0, 1.2, 0)
	local rawDir = (aimPos - releasePos)
	local horizontalDist = Vector3.new(rawDir.X, 0, rawDir.Z).Magnitude
	local arcLift = horizontalDist * arcFactor

	local aimWithArc = aimPos + Vector3.new(0, arcLift, 0)
	local dir = (aimWithArc - releasePos)
	if dir.Magnitude < 0.01 then dir = hrp.CFrame.LookVector end
	dir = dir.Unit

	ball.CFrame = CFrame.new(releasePos)
	ball.AssemblyLinearVelocity = dir * throwSpeed
	-- gentle spin around the ball's long axis
	ball.AssemblyAngularVelocity = Vector3.new(0, math.rad(360) * 2, 0)

	ballInAir = true
	ballStatus = "IN_AIR"
	defenseModifier = 0.0

	-- record air time for auto-incomplete timer
	ball:SetAttribute("AirTime", os.clock())

	setBallState()
	R.Outcome:FireAllClients({type="THROW", data={
		throwerId = plr.UserId,
		isForward = lastThrowWasForward,
		intendedTargetUserId = intendedTargetUserId,
	}})
end)

-- Defense play ball: PBU, SWAT, PICK + return
R.DefensePlayBall.OnServerEvent:Connect(function(plr, payload)
	local action = payload and payload.action
	if action ~= "PBU" and action ~= "SWAT" and action ~= "PICK" then return end

	if phase ~= "LIVE" then return end
	if ballStatus ~= "IN_AIR" then return end

	local ball = ensureFootball()
	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then return end

	-- defender must be within PBURange studs of the ball
	local pbuRange = char:GetAttribute("PBURange")
	if typeof(pbuRange) ~= "number" then pbuRange = 10 end
	local dist = (hrp.Position - ball.Position).Magnitude
	if dist > pbuRange then return end

	-- defender must be on the defense side
	local defSide = (possession == "HOME") and "AWAY" or "HOME"
	if plr:GetAttribute("Side") ~= defSide then return end

	if action == "SWAT" then
		-- Knock the ball down immediately - incomplete pass
		clearBallWeld(ball)
		ballCarrierUserId = nil
		ballInAir = false

		-- Give the ball a downward impulse to show the swat
		ball.AssemblyLinearVelocity = Vector3.new(
			ball.AssemblyLinearVelocity.X * 0.3,
			-18,
			ball.AssemblyLinearVelocity.Z * 0.3
		)

		R.Outcome:FireAllClients({type="SWAT", data={defenderId=plr.UserId}})
		incompletePass()

	elseif action == "PBU" then
		-- Reduce the catch chance for the intended receiver
		defenseModifier = math.clamp(defenseModifier + 0.25, 0, 0.60)
		R.Outcome:FireAllClients({type="PBU", data={defenderId=plr.UserId}})

	elseif action == "PICK" then
		-- Interception attempt
		local defStr = char:GetAttribute("Strength"); if typeof(defStr)~="number" then defStr = 80 end
		local basePickChance = 0.18 + CFG.DEFENDER_PICK_BONUS

		-- Boost pick chance if near intended target
		if intendedTargetUserId then
			local targetPlr = getPlayerByUserId(intendedTargetUserId)
			local targetChar = targetPlr and targetPlr.Character
			local targetHrp = targetChar and getHRP(targetChar)
			if targetHrp then
				local defDist = (hrp.Position - targetHrp.Position).Magnitude
				if defDist <= 4 then
					basePickChance = basePickChance + 0.12
				end
			end
		end

		local pickChance = math.clamp(basePickChance + (defStr - 80) / 300, 0.05, 0.55)
		if math.random() < pickChance then
			-- Interception!
			clearBallWeld(ball)
			ballInAir = false
			ballStatus = "PICKED"

			ball.AssemblyLinearVelocity = Vector3.new()
			ball.AssemblyAngularVelocity = Vector3.new()
			attachBallToCarrier(ball, char)
			ballCarrierUserId = plr.UserId

			-- flip possession
			turnover()

			R.Outcome:FireAllClients({type="INTERCEPTION", data={
				defenderId = plr.UserId,
				lines = {"INTERCEPTION!"},
			}})
			setBallState()
		else
			-- Attempted pick that failed still partially breaks up the pass
			defenseModifier = math.clamp(defenseModifier + 0.10, 0, 0.60)
			R.Outcome:FireAllClients({type="PBU", data={defenderId=plr.UserId}})
		end
	end
end)

-- Catch attempt: offense or defense can attempt to catch a ball in the air
R.CatchAttempt.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	if ballStatus ~= "IN_AIR" and ballStatus ~= "FUMBLE_LIVE" then return end

	local ball = ensureFootball()
	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then return end

	local dist = (hrp.Position - ball.Position).Magnitude
	local catchRadius = char:GetAttribute("CatchRadius")
	if typeof(catchRadius) ~= "number" then catchRadius = 2.5 end

	if dist > (6 + catchRadius) then return end

	local catchStrength = char:GetAttribute("CatchStrength")
	if typeof(catchStrength) ~= "number" then catchStrength = 70 end

	local plrSide = plr:GetAttribute("Side")
	local isOffense = (plrSide == possession)

	-- Base catch chance from CatchStrength
	local baseCatchChance = math.clamp(catchStrength / 120, 0.30, 0.85)

	-- High-point catch bonus
	if char:GetAttribute("HighPointBonus") then
		baseCatchChance = baseCatchChance + 0.15
		char:SetAttribute("HighPointBonus", nil)
	end

	-- Intended receiver bonus / non-intended penalty
	if isOffense then
		if intendedTargetUserId == plr.UserId then
			baseCatchChance = baseCatchChance + CFG.INTENDED_RECEIVER_BONUS
		elseif intendedTargetUserId ~= nil then
			baseCatchChance = baseCatchChance - CFG.NON_INTENDED_OFFENSE_PENALTY
		end
		-- Apply defense modifier from PBU actions
		baseCatchChance = baseCatchChance - defenseModifier
	else
		-- Defense trying to catch (interception via catch attempt)
		local defStr = char:GetAttribute("Strength"); if typeof(defStr)~="number" then defStr = 80 end
		baseCatchChance = math.clamp(0.12 + (defStr - 80) / 300 + CFG.DEFENDER_PICK_BONUS, 0.05, 0.45)
	end

	local finalChance = clamp01(baseCatchChance)

	if math.random() < finalChance then
		-- Successful catch
		clearBallWeld(ball)
		ballInAir = false
		ball.AssemblyLinearVelocity = Vector3.new()
		ball.AssemblyAngularVelocity = Vector3.new()

		if isOffense then
			attachBallToCarrier(ball, char)
			ballCarrierUserId = plr.UserId
			ballStatus = "CAUGHT"

			R.Outcome:FireAllClients({type="CATCH", data={
				catcherId = plr.UserId,
				lines = {"CATCH!"},
			}})
		else
			-- Defense catches = interception
			attachBallToCarrier(ball, char)
			ballCarrierUserId = plr.UserId
			ballStatus = "PICKED"

			turnover()

			R.Outcome:FireAllClients({type="INTERCEPTION", data={
				defenderId = plr.UserId,
				lines = {"INTERCEPTION!"},
			}})
		end
		setBallState()
	else
		-- Drop / failed catch
		if isOffense then
			R.Outcome:FireClient(plr, {type="DROP", data={lines={"Dropped!"}}} )
		end
	end
end)

-- Tackle attempt: defense tries to bring down the ball carrier
R.TackleAttempt.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	if ballCarrierUserId == nil then return end

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp or not char then return end

	-- must be on defense
	local defSide = (possession == "HOME") and "AWAY" or "HOME"
	if plr:GetAttribute("Side") ~= defSide then return end

	-- find carrier
	local carrierPlr = getPlayerByUserId(ballCarrierUserId)
	local carrierChar = carrierPlr and carrierPlr.Character
	local carrierHrp = carrierChar and getHRP(carrierChar)
	if not carrierHrp or not carrierChar then return end

	-- must be within tackle range
	local tackleDist = payload and payload.distance
	if typeof(tackleDist) ~= "number" then tackleDist = 5 end
	tackleDist = math.clamp(tackleDist, 2, 8)

	local dist = (hrp.Position - carrierHrp.Position).Magnitude
	if dist > tackleDist then return end

	local hitstick = (payload and payload.hitstick) == true

	-- tackle success chance based on weight/strength
	local defW = char:GetAttribute("WeightLb"); if typeof(defW)~="number" then defW = 220 end
	local carW = carrierChar:GetAttribute("WeightLb"); if typeof(carW)~="number" then carW = 200 end
	local defStr = char:GetAttribute("Strength"); if typeof(defStr)~="number" then defStr = 85 end
	local carStr = carrierChar:GetAttribute("Strength"); if typeof(carStr)~="number" then carStr = 80 end

	local weightEdge = math.clamp((defW - carW) / 100, -1.2, 1.2)
	local strEdge = math.clamp((defStr - carStr) / 80, -1.2, 1.2)
	local baseChance = 0.55 + weightEdge * 0.20 + strEdge * 0.15
	if hitstick then baseChance = baseChance + 0.10 end
	local tackleChance = math.clamp(baseChance, 0.20, 0.90)

	if math.random() < tackleChance then
		-- Tackle made
		applyImpulse(char, carrierChar, hitstick)
		endPlayAtWorldSpot(carrierHrp.Position, hitstick and "Hitstick tackle" or "Tackle")

		R.Outcome:FireAllClients({type="TACKLE", data={
			tacklerUserId = plr.UserId,
			carrierUserId = ballCarrierUserId,
			hitstick = hitstick,
			lines = {hitstick and "HITSTICK!" or "Tackle"},
		}})
	else
		-- Missed tackle - small stumble on carrier
		local stumbleDir = horizontalUnit(hrp.Position, carrierHrp.Position, carrierHrp.CFrame.LookVector)
		carrierHrp:ApplyImpulse(stumbleDir * 180)

		R.Outcome:FireAllClients({type="MISSED_TACKLE", data={
			tacklerUserId = plr.UserId,
			lines = {"Missed tackle"},
		}})
	end
end)

-- Juke: ball carrier evades a defender
R.Juke.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	if ballCarrierUserId ~= plr.UserId then return end

	local now = os.clock()
	local last = jukeCooldown[plr.UserId] or 0
	if now - last < CFG.JUKE_COOLDOWN then return end
	jukeCooldown[plr.UserId] = now

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	-- direction: -1 = left, 1 = right (default left if not provided)
	local dir = payload and payload.direction
	if typeof(dir) ~= "number" then dir = -1 end
	dir = dir >= 0 and 1 or -1

	local carW = char:GetAttribute("WeightLb"); if typeof(carW)~="number" then carW = 200 end
	-- lighter players juke better
	local jukeBoost = math.clamp(1.0 + (200 - carW) / 200, 0.6, 1.5)

	local lateralDir = hrp.CFrame.RightVector * (dir * 22 * jukeBoost)
	hrp:ApplyImpulse(lateralDir + Vector3.new(0, 80, 0))

	R.Outcome:FireAllClients({type="JUKE", data={userId=plr.UserId, direction=dir}})
end)

-- Spin: ball carrier spins through contact
R.Spin.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	if ballCarrierUserId ~= plr.UserId then return end

	local now = os.clock()
	local last = spinCooldown[plr.UserId] or 0
	if now - last < CFG.SPIN_COOLDOWN then return end
	spinCooldown[plr.UserId] = now

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	local carW = char:GetAttribute("WeightLb"); if typeof(carW)~="number" then carW = 200 end
	local spinBoost = math.clamp(1.0 + (200 - carW) / 250, 0.7, 1.4)

	-- forward + spin angular velocity
	hrp:ApplyImpulse(hrp.CFrame.LookVector * (160 * spinBoost))
	hrp.AssemblyAngularVelocity = Vector3.new(0, math.rad(360) * 2.5 * spinBoost, 0)

	R.Outcome:FireAllClients({type="SPIN", data={userId=plr.UserId}})
end)

-- Truck: heavier carriers truck through defenders
R.Truck.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end
	if ballCarrierUserId ~= plr.UserId then return end

	local now = os.clock()
	local last = truckCooldown[plr.UserId] or 0
	if now - last < CFG.TRUCK_COOLDOWN then return end
	truckCooldown[plr.UserId] = now

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	local carW = char:GetAttribute("WeightLb"); if typeof(carW)~="number" then carW = 200 end
	local carStr = char:GetAttribute("Strength"); if typeof(carStr)~="number" then carStr = 80 end
	-- heavier/stronger players truck better
	local truckBoost = math.clamp((carW / 200) * (carStr / 90), 0.7, 1.8)

	hrp:ApplyImpulse(hrp.CFrame.LookVector * (280 * truckBoost) + Vector3.new(0, 60, 0))

	-- knock back any nearby defenders
	for _, p in ipairs(Players:GetPlayers()) do
		if p == plr then continue end
		local defSide = (possession == "HOME") and "AWAY" or "HOME"
		if p:GetAttribute("Side") ~= defSide then continue end
		local defChar = p.Character
		local defHrp = defChar and getHRP(defChar)
		if not defHrp then continue end
		local defDist = (hrp.Position - defHrp.Position).Magnitude
		if defDist <= CFG.CONTEST_RADIUS then
			local knockDir = horizontalUnit(hrp.Position, defHrp.Position, hrp.CFrame.LookVector)
			local knockMag = math.clamp((1.0 - defDist / CFG.CONTEST_RADIUS) * 620 * truckBoost, 80, 820)
			defHrp:ApplyImpulse(knockDir * knockMag + Vector3.new(0, 120, 0))
			applyKnockdown(defChar, 0.4)
		end
	end

	R.Outcome:FireAllClients({type="TRUCK", data={userId=plr.UserId}})
end)

-- MoveInput: relay movement direction to server for future server-auth movement
R.MoveInput.OnServerEvent:Connect(function(plr, payload)
	-- Currently client-authoritative movement; server stores last input for reference
	local moveDir = payload and payload.moveDir
	if typeof(moveDir) ~= "Vector3" then return end
	-- Normalize to unit vector
	if moveDir.Magnitude > 0.01 then
		moveDir = moveDir.Unit
	else
		moveDir = Vector3.new(0,0,0)
	end
	local char = plr.Character
	if char then
		char:SetAttribute("LastMoveDir", moveDir)
	end
end)

-- JumpHighPoint: notify server that a player is at the apex of a jump (for high-point catches)
R.JumpHighPoint.OnServerEvent:Connect(function(plr, payload)
	if phase ~= "LIVE" then return end

	local char = plr.Character
	local hrp = char and getHRP(char)
	if not hrp then return end

	-- Only relevant when ball is in the air
	if ballStatus ~= "IN_AIR" then return end

	local ball = ensureFootball()
	local dist = (hrp.Position - ball.Position).Magnitude
	local catchRadius = char:GetAttribute("CatchRadius")
	if typeof(catchRadius) ~= "number" then catchRadius = 2.5 end

	-- High-point window is generous: 1.5x normal catch radius at jump apex
	if dist > (catchRadius * 1.5 + 3) then return end

	-- Grant a small catch probability bonus for high-pointing
	-- This is applied on the next CatchAttempt from this player within 0.5 s
	char:SetAttribute("HighPointBonus", true)
	task.delay(0.5, function()
		if char and char.Parent then
			char:SetAttribute("HighPointBonus", nil)
		end
	end)

	local prompt = catchPromptForPlayer(plr, ball)
	prompt.canCatch = true
	prompt.highPoint = true
	R.CatchPrompt:FireClient(plr, prompt)
end)
