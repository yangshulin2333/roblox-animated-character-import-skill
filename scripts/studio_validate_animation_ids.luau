-- Published/runtime validation. Run in a fresh Play session after editing the configuration.

local MODEL_PATH = "Workspace.ChangeMe"
local ANIMATIONS = {
	-- { name = "Idle", id = "rbxassetid://<ANIMATION_ID>", looped = true },
}
local LOAD_TIMEOUT_SECONDS = 8
local SAMPLE_SECONDS = 0.25

local HttpService = game:GetService("HttpService")

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

assert(#ANIMATIONS > 0, "Fill ANIMATIONS with published AnimationIds before running")
local model = resolvePath(MODEL_PATH)
assert(model and model:IsDescendantOf(workspace), "MODEL_PATH must resolve under Workspace")
local animator = findAnimator(model)

local results = {}
for _, definition in ANIMATIONS do
	local snapshot = snapshotBones(model)
	local result = {
		name = definition.name,
		id = definition.id,
		loaded = false,
		isPlaying = false,
		timeAdvanced = false,
		changedBones = 0,
		status = "FAIL",
	}
	local ok, message = pcall(function()
		local animation = Instance.new("Animation")
		animation.Name = "RuntimeValidation_" .. tostring(definition.name)
		animation.AnimationId = definition.id
		local track = animator:LoadAnimation(animation)
		local deadline = os.clock() + LOAD_TIMEOUT_SECONDS
		while track.Length <= 0 and os.clock() < deadline do
			task.wait()
		end
		result.loaded = track.Length > 0
		track.Looped = definition.looped == true
		track:Play(0)
		task.wait()
		result.isPlaying = track.IsPlaying
		local startPosition = track.TimePosition
		task.wait(math.min(SAMPLE_SECONDS, math.max(track.Length / 3, 0.05)))
		result.timeAdvanced = track.TimePosition > startPosition
		result.changedBones = changedBoneCount(snapshot)
		track:Stop(0)
		animation:Destroy()
		result.status = if result.loaded and result.isPlaying and result.timeAdvanced and result.changedBones > 0
			then "RUNTIME_PLAYBACK_PASS"
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
	if result.status == "RUNTIME_PLAYBACK_PASS" then
		passed += 1
	end
end

local report = {
	status = if passed == #results then "RUNTIME_PLAYBACK_PASS" else "PLAYBACK_BLOCKED",
	modelPath = MODEL_PATH,
	passed = passed,
	total = #results,
	results = results,
	note = "Also inspect Studio Output for permission or moderation errors and visually review deformation.",
}

local json = HttpService:JSONEncode(report)
print("ROBLOX_RUNTIME_ANIMATION_VALIDATION " .. json)
return json
