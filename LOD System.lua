local RunService = game:GetService("RunService")

if _G.lod_system_running then
	return
end
_G.lod_system_running = true

_G.LOD_SETTINGS = _G.LOD_SETTINGS or {
	EnableDynamicFPS = false,
	TargetFPS = 60
}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:WaitForChild("HumanoidRootPart", 10)
local humanoid = character:FindFirstChildOfClass("Humanoid")

local hiddenFolder = ReplicatedStorage:FindFirstChild("HiddenObjects_LOD")
if not hiddenFolder then
	hiddenFolder = Instance.new("Folder")
	hiddenFolder.Name = "HiddenObjects_LOD"
	hiddenFolder.Parent = ReplicatedStorage
end

for _, child in hiddenFolder:GetChildren() do
	child:Destroy()
end

local parts = {}
local partsCount = 0
local hiddenParts = {}
local visibleParts = {}
local chunks = {}
local hiddenChunks = {}
local visibleChunks = {}
local playerChars = {}
local connections = {}
local largeHiddenNodes = {}
local restoreCandidatePool = {}
local humanoidCache = setmetatable({}, {__mode = "k"})
local spawnCache = setmetatable({}, {__mode = "k"})

local toHide = table.create(2000)
local frontHideQueue = table.create(1000)
local toRestoreNow = table.create(2000)
local pendingAddQueue = table.create(1000)
local pendingAddCount = 0

local restoreReadIndex = 1
local resCount = 0

local hideLen = 0
local hideIndex = 1

local camera = Workspace.CurrentCamera
local terrain = Workspace.Terrain
local lastPlayerPos = camera and camera.CFrame.Position or Vector3.zero
local lastCamLook = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)

local lastScan = 0
local isRunning = true

local dynamicScale = 1.0
local smoothedDt = 0.0166

local baseHideThreshold = 300
local baseBehindHideThreshold = 120
local chunkSize = 150

local hideThreshold = baseHideThreshold
local restoreThreshold = baseHideThreshold - 40
local behindHideThreshold = baseBehindHideThreshold
local behindRestoreThreshold = baseBehindHideThreshold - 20

local minHorizontalDistSq = 10000
local distCheckThresholdSq = 1600
local scanInterval = 0.1

local fovCosSq = 0.5
local FAR_CHUNK_DIST_SQ = 81
local LARGE_RADIUS_THRESHOLD = 80

local standingNode = nil
local standRayParams = RaycastParams.new()
standRayParams.FilterType = Enum.RaycastFilterType.Exclude
standRayParams.FilterDescendantsInstances = {character}
standRayParams.IgnoreWater = true

local chunkOffsets = {
	{0, 0},
	{-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1},
	{-2, 0}, {2, 0}, {0, -2}, {0, 2},
	{-2, -1}, {-2, 1}, {2, -1}, {2, 1}, {-1, -2}, {1, -2}, {-1, 2}, {1, 2},
	{-2, -2}, {-2, 2}, {2, -2}, {2, 2}
}

local effectClassMap = {
	ParticleEmitter = {needsClear = true},
	Trail = {needsClear = true},
	Beam = {needsClear = false},
	PointLight = {needsClear = false},
	SpotLight = {needsClear = false},
	SurfaceLight = {needsClear = false},
	Fire = {needsClear = false},
	Smoke = {needsClear = false},
	Sparkles = {needsClear = false},
	Highlight = {needsClear = false},
	SurfaceGui = {needsClear = false, kickAdornee = true},
	BillboardGui = {needsClear = false, kickAdornee = true},
	ProximityPrompt = {needsClear = false},
	Sound = {needsClear = false, isSound = true}
}

local function hasSpawnLocation(node)
	if node:IsA("SpawnLocation") then return true end
	if not node:IsA("Model") and not node:IsA("Folder") then return false end

	local cached = spawnCache[node]
	if cached ~= nil then
		return cached
	end

	local found = node:FindFirstChildOfClass("SpawnLocation") ~= nil
	spawnCache[node] = found
	return found
end

local function hasHumanoid(model)
	local cached = humanoidCache[model]
	if cached ~= nil then
		return cached
	end
	local found = model:FindFirstChildOfClass("Humanoid") ~= nil
	humanoidCache[model] = found
	return found
end

local function isLODEntity(node)
	return node:IsA("BasePart") or node:IsA("Model")
end

local function shouldSkip(node)
	if not isLODEntity(node) then return true end
	if node == terrain or node == Workspace then return true end

	if node:IsA("SpawnLocation") or hasSpawnLocation(node) then return true end

	if playerChars[node] then return true end
	if player.Character and (node == player.Character or node:IsDescendantOf(player.Character)) then return true end

	local parent = node.Parent
	if not parent then return true end
	if parent == hiddenFolder or parent == camera then return true end

	if node:IsA("Model") then
		if Players:GetPlayerFromCharacter(node) then return true end
		if hasHumanoid(node) then return true end

		local sz = node:GetExtentsSize()
		if sz.X == 0 and sz.Y == 0 and sz.Z == 0 then return true end
		if sz.X > 800 or sz.Z > 800 or sz.Y > 800 then return true end
	elseif node:IsA("BasePart") then
		local parentModel = node:FindFirstAncestorWhichIsA("Model")
		if parentModel and parentModel ~= Workspace and not playerChars[parentModel] then
			return true
		end

		if node:IsA("Seat") then return true end
		if node.Transparency >= 1 and not node.CanCollide then return true end

		local sz = node.Size
		if sz.X > 800 or sz.Y > 800 or sz.Z > 800 then return true end
	end

	if node:GetAttribute("_PooledObject") then return true end

	local checkParent = parent
	local depth = 0
	while checkParent and checkParent ~= Workspace and depth < 20 do
		if playerChars[checkParent] then return true end
		if hasSpawnLocation(checkParent) then return true end

		if checkParent:IsA("Model") then
			if Players:GetPlayerFromCharacter(checkParent) then return true end
			if hasHumanoid(checkParent) then return true end
		end

		checkParent = checkParent.Parent
		depth = depth + 1
	end

	return false
end

local function getWorldExtents(cf, size)
	local ax, ay, az = cf.XVector, cf.YVector, cf.ZVector
	local wx = math.abs(ax.X) * size.X + math.abs(ay.X) * size.Y + math.abs(az.X) * size.Z
	local wy = math.abs(ax.Y) * size.X + math.abs(ay.Y) * size.Y + math.abs(az.Y) * size.Z
	local wz = math.abs(ax.Z) * size.X + math.abs(ay.Z) * size.Y + math.abs(az.Z) * size.Z
	return wx, wy, wz
end

local function isFloor(wx, wy, wz)
	return wy < 8 and wx * wz >= 500
end

local function getRadiusSq(sx, sy, sz)
	return 0.25 * (sx * sx + sy * sy + sz * sz)
end

local function scanEffects(node)
	local effects = nil
	local count = 0

	for _, child in node:GetDescendants() do
		local effectData = effectClassMap[child.ClassName]
		if effectData then
			if not effects then effects = table.create(16) end
			count = count + 1
			effects[count] = child
			effects[count + 1] = effectData
			count = count + 1
		end
	end
	return effects
end

local function toggleEffects(effects, enable, data)
	if not effects then return end
	local len = #effects
	local i = 1
	local idx = 1

	if not enable then
		if data then
			data.savedEffects = data.savedEffects or table.create(len / 2)
		end
		while i <= len do
			local obj = effects[i]
			local effectData = effects[i + 1]
			i = i + 2

			if obj and obj.Parent then
				if effectData.isSound then
					if data and data.savedEffects then
						data.savedEffects[idx] = obj.IsPlaying
						idx = idx + 1
					end
					if obj.IsPlaying then
						obj:Pause()
					end
				else
					if data and data.savedEffects then
						data.savedEffects[idx] = obj.Enabled
						idx = idx + 1
					end
					if effectData.needsClear and obj.Enabled then
						obj:Clear()
					end
					obj.Enabled = false
				end
			end
		end
	else
		local saved = data and data.savedEffects
		while i <= len do
			local obj = effects[i]
			local effectData = effects[i + 1]
			i = i + 2

			if obj and obj.Parent then
				if effectData.isSound then
					if saved and saved[idx] ~= nil then
						if saved[idx] then
							obj:Play()
						end
						idx = idx + 1
					end
				else
					if saved and saved[idx] ~= nil then
						obj.Enabled = saved[idx]
						idx = idx + 1
					else
						obj.Enabled = true
					end

					if effectData.kickAdornee then
						local currentAdornee = obj.Adornee
						if currentAdornee then
							obj.Adornee = nil
							obj.Adornee = currentAdornee
						elseif obj.Parent and (obj.Parent:IsA("BasePart") or obj.Parent:IsA("Attachment")) then
							obj.Adornee = obj.Parent
						end
					end
				end
			end
		end
	end
end

local function addToParts(node)
	if parts[node] then return end

	local isModelNode = node:IsA("Model")

	local pos, size
	if isModelNode then
		pos = node:GetPivot().Position
		size = node:GetExtentsSize()
	else
		pos = node.Position
		size = node.Size
	end

	if not size then return end

	local sx, sy, sz = size.X, size.Y, size.Z
	local radiusSq = getRadiusSq(sx, sy, sz)
	local radiusSqrt = math.sqrt(radiusSq)
	local px, py, pz = pos.X, pos.Y, pos.Z

	local wx, wy, wz
	if isModelNode then
		wx, wy, wz = sx, sy, sz
	else
		wx, wy, wz = getWorldExtents(node.CFrame, size)
	end

	local cx = math.floor(px / chunkSize)
	local cz = math.floor(pz / chunkSize)
	local cKey = cx * 10000000 + cz

	partsCount = partsCount + 1
	parts[node] = {
		parent = node.Parent,
		hidden = false,
		isModel = isModelNode,
		radiusSqrt = radiusSqrt,
		sizeMult = math.clamp(radiusSqrt / 12, 0.5, 1.4),
		isFloor = isFloor(wx, wy, wz),
		effects = scanEffects(node),
		savedEffects = nil,
		px = px,
		py = py,
		pz = pz,
		cKey = cKey
	}

	if not chunks[cKey] then
		chunks[cKey] = {}
	end
	chunks[cKey][node] = true

	if not visibleChunks[cKey] then
		visibleChunks[cKey] = {cx = cx, cz = cz, nodes = {}}
	end
	visibleChunks[cKey].nodes[node] = true
	visibleParts[node] = true
end

local function removeFromParts(node)
	local data = parts[node]
	if data then
		data.effects = nil
		data.savedEffects = nil

		local chunk = chunks[data.cKey]
		if chunk then
			chunk[node] = nil
			if next(chunk) == nil then
				chunks[data.cKey] = nil
			end
		end

		local vChunk = visibleChunks[data.cKey]
		if vChunk then
			vChunk.nodes[node] = nil
			if next(vChunk.nodes) == nil then
				visibleChunks[data.cKey] = nil
			end
		end

		local hChunk = hiddenChunks[data.cKey]
		if hChunk then
			hChunk[node] = nil
			if next(hChunk) == nil then
				hiddenChunks[data.cKey] = nil
			end
		end

		parts[node] = nil
		visibleParts[node] = nil
		hiddenParts[node] = nil
		largeHiddenNodes[node] = nil

		partsCount = partsCount - 1
		if partsCount < 0 then partsCount = 0 end

		if standingNode == node then
			standingNode = nil
		end
	end
end

local function restoreNode(node, data)
	node.Parent = data.parent
	data.hidden = false
	hiddenParts[node] = nil
	visibleParts[node] = true
	largeHiddenNodes[node] = nil

	local hChunk = hiddenChunks[data.cKey]
	if hChunk then
		hChunk[node] = nil
		if next(hChunk) == nil then
			hiddenChunks[data.cKey] = nil
		end
	end

	if not visibleChunks[data.cKey] then
		local cx = math.floor(data.px / chunkSize)
		local cz = math.floor(data.pz / chunkSize)
		visibleChunks[data.cKey] = {cx = cx, cz = cz, nodes = {}}
	end
	visibleChunks[data.cKey].nodes[node] = true

	toggleEffects(data.effects, true, data)
end

local function forceUntrackPart(node)
	local data = parts[node]
	if not data then return end
	if data.hidden and node.Parent == hiddenFolder and data.parent and data.parent.Parent then
		restoreNode(node, data)
	end
	removeFromParts(node)
end

local function registerPart(node)
	if not isRunning then return end
	if shouldSkip(node) or parts[node] then return end
	addToParts(node)
end

local function cleanupPart(node)
	if not isRunning then return end
	if not (node:IsA("BasePart") or node:IsA("Model")) then return end
	if not parts[node] and not hiddenParts[node] then return end

	task.defer(function()
		if not isRunning then return end
		if node.Parent == hiddenFolder then return end
		if node:IsDescendantOf(Workspace) then return end
		removeFromParts(node)
	end)
end

local function findTrackedAncestor(node)
	local p = node.Parent
	local depth = 0
	while p and p ~= Workspace and depth < 20 do
		if parts[p] then return p end
		p = p.Parent
		depth = depth + 1
	end
	return nil
end

local function onDescendantAdded(node)
	if not isRunning then return end

	if node:IsA("BasePart") or node:IsA("Model") then
		pendingAddCount = pendingAddCount + 1
		pendingAddQueue[pendingAddCount] = node
		return
	end

	local effectData = effectClassMap[node.ClassName]
	if not effectData then return end

	local owner = findTrackedAncestor(node)
	local data = owner and parts[owner]
	if not data then return end

	if data.effects then
		for i = 1, #data.effects, 2 do
			if data.effects[i] == node then
				return
			end
		end
	else
		data.effects = table.create(4)
	end

	local len = #data.effects
	data.effects[len + 1] = node
	data.effects[len + 2] = effectData

	if data.hidden then
		if effectData.isSound then
			if node.IsPlaying then
				node:Pause()
			end
		else
			if effectData.needsClear and node.Enabled then
				node:Clear()
			end
			node.Enabled = false
		end
	end
end

local function processPendingAdds()
	if pendingAddCount == 0 or not isRunning then return end
	local startTime = os.clock()

	while pendingAddCount > 0 do
		local node = pendingAddQueue[pendingAddCount]
		pendingAddQueue[pendingAddCount] = nil
		pendingAddCount = pendingAddCount - 1

		if node and node.Parent then
			registerPart(node)
		end

		if pendingAddCount % 8 == 0 and (os.clock() - startTime) > 0.001 then
			break
		end
	end
end

local function addCharacter(char)
	if not char or not isRunning then return end
	playerChars[char] = true
	forceUntrackPart(char)
	for _, part in char:GetDescendants() do
		if isLODEntity(part) then
			forceUntrackPart(part)
		end
	end
end

local function removeCharacter(char)
	if char then playerChars[char] = nil end
end

if character then addCharacter(character) end

local function setupPlayer(plr)
	if not isRunning or plr == player then return end
	if plr.Character then addCharacter(plr.Character) end
	connections[plr] = {
		plr.CharacterAdded:Connect(addCharacter),
		plr.CharacterRemoving:Connect(removeCharacter)
	}
end

local function disconnectPlayer(plr)
	local conns = connections[plr]
	if conns then
		conns[1]:Disconnect()
		conns[2]:Disconnect()
		connections[plr] = nil
	end
end

for _, plr in Players:GetPlayers() do setupPlayer(plr) end

connections.playerAdded = Players.PlayerAdded:Connect(setupPlayer)
connections.playerRemoving = Players.PlayerRemoving:Connect(function(plr)
	removeCharacter(plr.Character)
	disconnectPlayer(plr)
end)

connections.charAdded = player.CharacterAdded:Connect(function(char)
	character = char
	hrp = char:WaitForChild("HumanoidRootPart", 10)
	humanoid = char:FindFirstChildOfClass("Humanoid")
	standRayParams.FilterDescendantsInstances = {char}
	standingNode = nil
	addCharacter(char)
	if camera then
		lastPlayerPos = camera.CFrame.Position
		lastCamLook = camera.CFrame.LookVector
	end
end)

connections.charRemoving = player.CharacterRemoving:Connect(function()
	hrp = nil
	humanoid = nil
	standingNode = nil
end)

connections.descAdded = Workspace.DescendantAdded:Connect(onDescendantAdded)
connections.descRemoving = Workspace.DescendantRemoving:Connect(cleanupPart)
connections.hiddenRemoving = hiddenFolder.DescendantRemoving:Connect(cleanupPart)

task.spawn(function()
	local startTime = os.clock()

	local function scanFolder(container)
		if not isRunning then return end
		local children = container:GetChildren()
		for i = 1, #children do
			if not isRunning then break end
			local child = children[i]

			if isLODEntity(child) then
				registerPart(child)
			end

			if child:IsA("Folder") then
				scanFolder(child)
			elseif child:IsA("Model") and not parts[child] then
				scanFolder(child)
			end

			if i % 50 == 0 and (os.clock() - startTime) > 0.003 then
				task.wait()
				startTime = os.clock()
			end
		end
	end

	scanFolder(Workspace)
end)

local function scanNearby(camPos, camLook, vx, vy, vz)
	if not isRunning then return end

	table.clear(toHide)
	hideLen = 0
	hideIndex = 1
	local frontLen = 0

	local lx, ly, lz = camLook.X, camLook.Y, camLook.Z
	local px = camPos.X + vx
	local py = camPos.Y + vy
	local pz = camPos.Z + vz

	local pcx = math.floor(px / chunkSize)
	local pcz = math.floor(pz / chunkSize)

	for cKey, vChunk in visibleChunks do
		local dcx = vChunk.cx - pcx
		local dcz = vChunk.cz - pcz
		local chunkDistSq = dcx * dcx + dcz * dcz

		if chunkDistSq >= FAR_CHUNK_DIST_SQ then
			for node in vChunk.nodes do
				local data = parts[node]
				if data and not data.hidden and not data.isFloor and node ~= standingNode then
					hideLen = hideLen + 1
					toHide[hideLen] = node
				end
			end
		else
			for node in vChunk.nodes do
				local data = parts[node]
				if data and not data.hidden and node ~= standingNode then
					local dx = data.px - px
					local dz = data.pz - pz

					if not data.isFloor then
						local horizontalSq = dx * dx + dz * dz
						if horizontalSq > minHorizontalDistSq then
							local dy = data.py - py
							local distSq = horizontalSq + dy * dy

							local dot = dx * lx + dy * ly + dz * lz
							local dotAdj = dot + data.radiusSqrt
							local isInFOV = (dotAdj > 0) and ((dotAdj * dotAdj) >= fovCosSq * distSq)
							local baseThresh = isInFOV and hideThreshold or behindHideThreshold

							local threshold = (baseThresh * data.sizeMult) + data.radiusSqrt

							if distSq > (threshold * threshold) then
								if not isInFOV then
									hideLen = hideLen + 1
									toHide[hideLen] = node
								else
									frontLen = frontLen + 1
									frontHideQueue[frontLen] = node
								end
							end
						end
					end
				end
			end
		end
	end

	for i = 1, frontLen do
		hideLen = hideLen + 1
		toHide[hideLen] = frontHideQueue[i]
		frontHideQueue[i] = nil
	end
end

local function processInstantRestores(dt, camPos, camLook, vx, vy, vz)
	if not isRunning then return end

	local startTime = os.clock()
	local maxRestoreTime = (dt and dt > 0.02) and 0.0010 or 0.0020

	local lx, ly, lz = camLook.X, camLook.Y, camLook.Z
	local px = camPos.X + vx
	local py = camPos.Y + vy
	local pz = camPos.Z + vz

	if restoreReadIndex > resCount then
		resCount = 0
		restoreReadIndex = 1

		local pcx = math.floor(px / chunkSize)
		local pcz = math.floor(pz / chunkSize)
		local candidates = table.create(32)
		local candidateCount = 0
		local seen = {}

		for k = 1, #chunkOffsets do
			local off = chunkOffsets[k]
			local cx = pcx + off[1]
			local cz = pcz + off[2]
			local cKey = cx * 10000000 + cz
			local hChunk = hiddenChunks[cKey]
			if hChunk then
				for node in hChunk do
					local data = parts[node]
					if data and data.hidden then
						local dx = data.px - px
						local dy = data.py - py
						local dz = data.pz - pz
						local distSq = dx * dx + dy * dy + dz * dz

						local dot = dx * lx + dy * ly + dz * lz
						local dotAdj = dot + data.radiusSqrt
						local isInFOV = (dotAdj > 0) and ((dotAdj * dotAdj) >= fovCosSq * distSq)
						local activeRestoreThreshold = isInFOV and restoreThreshold or behindRestoreThreshold

						local threshold = (activeRestoreThreshold * data.sizeMult) + data.radiusSqrt
						if distSq <= (threshold * threshold) then
							candidateCount = candidateCount + 1
							local slot = restoreCandidatePool[candidateCount]
							if not slot then
								slot = {}
								restoreCandidatePool[candidateCount] = slot
							end
							slot.node = node
							slot.distSq = distSq
							candidates[candidateCount] = slot
							seen[node] = true
						end
					end
				end
			end
		end

		for node in largeHiddenNodes do
			if not seen[node] then
				local data = parts[node]
				if data and data.hidden then
					local dx = data.px - px
					local dy = data.py - py
					local dz = data.pz - pz
					local distSq = dx * dx + dy * dy + dz * dz

					local dot = dx * lx + dy * ly + dz * lz
					local dotAdj = dot + data.radiusSqrt
					local isInFOV = (dotAdj > 0) and ((dotAdj * dotAdj) >= fovCosSq * distSq)
					local activeRestoreThreshold = isInFOV and restoreThreshold or behindRestoreThreshold

					local threshold = (activeRestoreThreshold * data.sizeMult) + data.radiusSqrt
					if distSq <= (threshold * threshold) then
						candidateCount = candidateCount + 1
						local slot = restoreCandidatePool[candidateCount]
						if not slot then
							slot = {}
							restoreCandidatePool[candidateCount] = slot
						end
						slot.node = node
						slot.distSq = distSq
						candidates[candidateCount] = slot
					end
				end
			end
		end

		table.sort(candidates, function(a, b) return a.distSq < b.distSq end)

		for k = 1, candidateCount do
			resCount = resCount + 1
			toRestoreNow[resCount] = candidates[k].node
		end
	end

	while restoreReadIndex <= resCount do
		local node = toRestoreNow[restoreReadIndex]
		toRestoreNow[restoreReadIndex] = nil
		restoreReadIndex = restoreReadIndex + 1

		local data = parts[node]
		if data and data.hidden then
			if not node.Parent or node.Parent ~= hiddenFolder then
				removeFromParts(node)
				continue
			end

			local originalParent = data.parent
			if not originalParent or not originalParent.Parent then
				node:Destroy()
				removeFromParts(node)
				continue
			end

			local dx = data.px - px
			local dy = data.py - py
			local dz = data.pz - pz
			local distSq = dx * dx + dy * dy + dz * dz

			local dot = dx * lx + dy * ly + dz * lz
			local dotAdj = dot + data.radiusSqrt
			local isInFOV = (dotAdj > 0) and ((dotAdj * dotAdj) >= fovCosSq * distSq)
			local activeRestoreThreshold = isInFOV and restoreThreshold or behindRestoreThreshold
			local threshold = (activeRestoreThreshold * data.sizeMult) + data.radiusSqrt

			if distSq > (threshold * threshold) and node ~= standingNode then
				continue
			end

			local isModel = data.isModel

			restoreNode(node, data)

			if isModel or (restoreReadIndex % 4 == 0) then
				if (os.clock() - startTime) > maxRestoreTime then
					break
				end
			end
		end
	end

	if restoreReadIndex > resCount then
		resCount = 0
		restoreReadIndex = 1
	end
end

local function processBatch(dt)
	if not isRunning then return end

	local startTime = os.clock()
	local maxHideTime = (dt and dt > 0.02) and 0.0030 or 0.0020
	local iterations = 0

	while hideIndex <= hideLen do
		local node = toHide[hideIndex]
		toHide[hideIndex] = nil
		hideIndex = hideIndex + 1
		iterations = iterations + 1

		if node and node.Parent and node.Parent ~= hiddenFolder and node ~= standingNode then
			local data = parts[node]
			if data and not data.hidden then
				data.parent = node.Parent
				local isModel = data.isModel

				toggleEffects(data.effects, false, data)

				node.Parent = hiddenFolder
				data.hidden = true
				hiddenParts[node] = true
				visibleParts[node] = nil

				local vChunk = visibleChunks[data.cKey]
				if vChunk then
					vChunk.nodes[node] = nil
					if next(vChunk.nodes) == nil then
						visibleChunks[data.cKey] = nil
					end
				end

				if not hiddenChunks[data.cKey] then
					hiddenChunks[data.cKey] = {}
				end
				hiddenChunks[data.cKey][node] = true

				if data.radiusSqrt > LARGE_RADIUS_THRESHOLD then
					largeHiddenNodes[node] = true
				end

				if isModel or (iterations % 4 == 0) then
					if (os.clock() - startTime) > maxHideTime then
						break
					end
				end
			end
		end
	end

	if hideIndex > hideLen then
		hideLen = 0
		hideIndex = 1
	end
end

local function cleanup()
	isRunning = false
	_G.lod_system_running = nil

	for k, conn in connections do
		if typeof(conn) == "RBXScriptConnection" then conn:Disconnect()
		elseif type(conn) == "table" then conn[1]:Disconnect(); conn[2]:Disconnect() end
	end

	for node, data in parts do
		if data.hidden and node.Parent == hiddenFolder and data.parent and data.parent.Parent then
			node.Parent = data.parent
			toggleEffects(data.effects, true, data)
		end
	end

	table.clear(connections); table.clear(parts); table.clear(hiddenParts)
	table.clear(playerChars); table.clear(toHide); table.clear(visibleParts)
	table.clear(chunks); table.clear(hiddenChunks); table.clear(visibleChunks)
	table.clear(toRestoreNow); table.clear(pendingAddQueue); table.clear(largeHiddenNodes)
	table.clear(restoreCandidatePool)
end

if script.Parent then
	script.AncestryChanged:Connect(function()
		if not script.Parent then cleanup() end
	end)
end

connections.postsim = RunService.PostSimulation:Connect(function(dt)
	if not isRunning then return end

	camera = Workspace.CurrentCamera or camera
	if not camera then return end

	processPendingAdds()

	local settings = _G.LOD_SETTINGS or {}
	if settings.EnableDynamicFPS == true then
		smoothedDt = smoothedDt + (dt - smoothedDt) * 0.05
		local currentFPS = 1 / math.max(smoothedDt, 0.001)
		local targetFPS = settings.TargetFPS or 60

		if currentFPS < (targetFPS - 5) then
			local deficit = (targetFPS - currentFPS) / targetFPS
			dynamicScale = math.max(0.35, dynamicScale - math.min(0.01, deficit * 0.02))
		elseif currentFPS >= (targetFPS - 2) and dynamicScale < 1.0 then
			dynamicScale = math.min(1.0, dynamicScale + 0.003)
		end
	else
		if dynamicScale < 1.0 then
			dynamicScale = math.min(1.0, dynamicScale + 0.01)
		end
	end

	hideThreshold = baseHideThreshold * dynamicScale
	restoreThreshold = math.max(60, hideThreshold - 40)
	behindHideThreshold = baseBehindHideThreshold * dynamicScale
	behindRestoreThreshold = math.max(40, behindHideThreshold - 20)

	local halfFov = math.rad(math.clamp(camera.FieldOfView, 1, 130) * 0.5 + 15)
	local cosHalfFov = math.cos(halfFov)
	fovCosSq = cosHalfFov * cosHalfFov

	local currentCamCF = camera.CFrame
	local currentCamPos = currentCamCF.Position
	local currentCamLook = currentCamCF.LookVector

	local vel = (hrp and hrp.Parent and hrp.AssemblyLinearVelocity) or Vector3.zero
	local vx, vy, vz = vel.X * 0.2, vel.Y * 0.2, vel.Z * 0.2
	local vMagSq = vx * vx + vy * vy + vz * vz
	local maxVMag = 40
	if vMagSq > maxVMag * maxVMag then
		local vScale = maxVMag / math.sqrt(vMagSq)
		vx, vy, vz = vx * vScale, vy * vScale, vz * vScale
	end

	if hrp and hrp.Parent then
		local rayDist = 10 + (humanoid and humanoid.HipHeight or 0)
		local rayResult = Workspace:Raycast(hrp.Position, Vector3.new(0, -rayDist, 0), standRayParams)
		local hitNode = nil
		if rayResult and rayResult.Instance then
			local hitPart = rayResult.Instance
			if parts[hitPart] then
				hitNode = hitPart
			else
				hitNode = findTrackedAncestor(hitPart)
			end
		end
		standingNode = hitNode
	else
		standingNode = nil
	end

	if standingNode then
		local sData = parts[standingNode]
		if sData and sData.hidden and standingNode.Parent == hiddenFolder and sData.parent and sData.parent.Parent then
			restoreNode(standingNode, sData)
		end
	end

	processInstantRestores(dt, currentCamPos, currentCamLook, vx, vy, vz)

	local dx = currentCamPos.X - lastPlayerPos.X
	local dy = currentCamPos.Y - lastPlayerPos.Y
	local dz = currentCamPos.Z - lastPlayerPos.Z
	local distSq = dx * dx + dy * dy + dz * dz

	local ldx = currentCamLook.X - lastCamLook.X
	local ldy = currentCamLook.Y - lastCamLook.Y
	local ldz = currentCamLook.Z - lastCamLook.Z
	local rotSq = ldx * ldx + ldy * ldy + ldz * ldz

	if distSq > distCheckThresholdSq or rotSq > 0.05 then
		resCount = 0
		restoreReadIndex = 1

		local now = os.clock()

		if now - lastScan > scanInterval and hideIndex > hideLen then
			lastPlayerPos = currentCamPos
			lastCamLook = currentCamLook
			lastScan = now
			scanNearby(currentCamPos, currentCamLook, vx, vy, vz)
		end
	end

	processBatch(dt)
end)
