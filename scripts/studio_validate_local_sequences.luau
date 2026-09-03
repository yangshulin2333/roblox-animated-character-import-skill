-- Studio-local preview only. Run in a test copy/current session after setting MODEL_PATH.
-- A pass here does not prove published AnimationId ownership or runtime permission.

local MODEL_PATH = "Workspace.ChangeMe"
local SEQUENCES_PATH = "" -- Optional explicit Folder path. Empty uses model.AnimSaves or its ObjectValue.
local LOAD_TIMEOUT_SECONDS = 5
local SAMPLE_SECONDS = 0.25

local HttpService = game:GetService("HttpService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local function resolvePath(path: string): Instance?
	local normalized = string.gsub(path, "^game%.", "")
	local current: Instance = game
	for segment in string.gmatch(normalized, "[^%.]+") do
		if current == game and segment == "Workspace" then
			current = workspace
		else
			local child = current:FindFirstChild(segment)
			if not child then
				return nil
			end
			current = child
		end
	end
	return current
end

local function findAnimator(model: Instance): Animator
	local host = model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildOfClass("AnimationController")
	if not host then
		host = Instance.new("AnimationController")
		host.Parent = model
	end
	local animator = host:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = host
	end
	return animator
end

local function findSequenceContainer(model: Instance): Instance
	if SEQUENCES_PATH ~= "" then
		local explicit = resolvePath(SEQUENCES_PATH)
		assert(explicit, "SEQUENCES_PATH was not found: " .. SEQUENCES_PATH)
		return explicit
	end
	local saves = model:FindFirstChild("AnimSaves")
	assert(saves, "No AnimSaves child. Set SEQUENCES_PATH explicitly.")
	if saves:IsA("ObjectValue") then
		assert(saves.Value, "AnimSaves ObjectValue has no Value")
		return saves.Value
	end
	return saves
end

local function snapshotBones(model: Instance): {[Bone]: CFrame}
	local snapshot = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Bone") then
			snapshot[descendant] = descendant.Transform
		end
	end
	return snapshot
end

local function restoreBones(snapshot: {[Bone]: CFrame})
	for bone, transform in snapshot do
		if bone.Parent then
			bone.Transform = transform
		end
	end
end

local function changedBoneCount(snapshot: {[Bone]: CFrame}): number
	local changed = 0
	for bone, before in snapshot do
		if bone.Parent then
			local delta = before:ToObjectSpace(bone.Transform)
			local _, angle = delta:ToAxisAngle()
			if delta.Position.Magnitude > 1e-5 or math.abs(angle) > 1e-5 then
				changed += 1
			end
		end
	end
	return changed
end

local model = resolvePath(MODEL_PATH)
assert(model and model:IsDescendantOf(workspace), "MODEL_PATH must resolve under Workspace")
local animator = findAnimator(model)
local container = findSequenceContainer(model)
local sequences = {}
for _, descendant in container:GetDescendants() do
	if descendant:IsA("KeyframeSequence") then
		table.insert(sequences, descendant)
	end
end
table.sort(sequences, function(a, b)
	return a.Name < b.Name
end)
assert(#sequences > 0, "No KeyframeSequence descendants were found")

local results = {}
for _, sequence in sequences do
	local snapshot = snapshotBones(model)
	local result = {
		name = sequence.Name,
		loaded = false,
		isPlaying = false,
		timeAdvanced = false,
		changedBones = 0,
		status = "FAIL",
	}
	local ok, message = pcall(function()
		local temporaryId = KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
		local animation = Instance.new("Animation")
		animation.Name = "LocalValidation_" .. sequence.Name
		animation.AnimationId = temporaryId
		local track = animator:LoadAnimation(animation)
		local deadline = os.clock() + LOAD_TIMEOUT_SECONDS
		while track.Length <= 0 and os.clock() < deadline do
			task.wait()
		end
		result.loaded = track.Length > 0
		track:Play(0)
		animator:StepAnimations(0)
		result.isPlaying = track.IsPlaying
		local startPosition = track.TimePosition
		local stepDuration = math.min(SAMPLE_SECONDS, math.max(track.Length / 3, 0.05))
		animator:StepAnimations(stepDuration)
		result.timeAdvanced = track.TimePosition > startPosition
		result.changedBones = changedBoneCount(snapshot)
		track:Stop(0)
		animator:StepAnimations(0)
		animation:Destroy()
		result.status = if result.loaded and result.isPlaying and result.timeAdvanced and result.changedBones > 0
			then "LOCAL_PLAYBACK_PASS"
			else "PLAYBACK_BLOCKED"
	end)
	if not ok then
		result.error = tostring(message)
	end
	restoreBones(snapshot)
	table.insert(results, result)
end

local passed = 0
for _, result in results do
	if result.status == "LOCAL_PLAYBACK_PASS" then
		passed += 1
	end
end

local report = {
	status = if passed == #results then "LOCAL_PLAYBACK_PASS" else "PLAYBACK_BLOCKED",
	modelPath = MODEL_PATH,
	boneCount = (function()
		local count = 0
		for _, item in model:GetDescendants() do
			if item:IsA("Bone") then
				count += 1
			end
		end
		return count
	end)(),
	passed = passed,
	total = #results,
	results = results,
	note = "Temporary KeyframeSequence preview only; publish and test AnimationIds for runtime acceptance.",
}

local json = HttpService:JSONEncode(report)
print("ROBLOX_LOCAL_ANIMATION_VALIDATION " .. json)
return json
