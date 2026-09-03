-- Read-only dependency audit for an imported Roblox character/model.
-- Set MODEL_PATH, run in Edit and again in a fresh Play session, and compare reports.

local MODEL_PATH = "Workspace.ChangeMe"

local ContentProvider = game:GetService("ContentProvider")
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

local function fetchStatus(contentId: string): string
	if contentId == "" then
		return "EMPTY"
	end
	local ok, value = pcall(function()
		return tostring(ContentProvider:GetAssetFetchStatus(contentId))
	end)
	return if ok then value else "ERROR: " .. tostring(value)
end

local function classify(contentId: string): string
	if contentId == "" then
		return "EMPTY"
	elseif string.match(contentId, "^rbxthumb://") then
		return "THUMBNAIL_FORBIDDEN"
	elseif string.match(contentId, "^rbxassetid://") then
		return "DIRECT_ASSET"
	elseif string.match(contentId, "^rbxgameasset://") then
		return "PROJECT_ASSET"
	elseif string.match(contentId, "^rbxtemp://") then
		return "TEMPORARY"
	elseif string.match(contentId, "^rbxasset://") then
		return "BUILTIN"
	end
	return "OTHER"
end

local root = resolvePath(MODEL_PATH)
assert(root and root:IsDescendantOf(workspace), "MODEL_PATH must resolve under Workspace")

local dependencies = {}
local blockers = {}
local warnings = {}

local function addDependency(instance: Instance, propertyName: string, contentId: string)
	local kind = classify(contentId)
	local status = fetchStatus(contentId)
	local item = {
		instance = instance:GetFullName(),
		className = instance.ClassName,
		property = propertyName,
		contentId = contentId,
		kind = kind,
		fetchStatus = status,
	}
	table.insert(dependencies, item)

	if kind == "THUMBNAIL_FORBIDDEN" then
		table.insert(blockers, item.instance .. "." .. propertyName .. " uses rbxthumb://")
	elseif contentId ~= "" and kind ~= "BUILTIN" and status == "Enum.AssetFetchStatus.Failure" then
		table.insert(blockers, item.instance .. "." .. propertyName .. " failed to fetch")
	end
end

for _, descendant in root:GetDescendants() do
	if descendant:IsA("MeshPart") then
		addDependency(descendant, "MeshId", descendant.MeshId)
		addDependency(descendant, "TextureID", descendant.TextureID)
	elseif descendant:IsA("SpecialMesh") then
		addDependency(descendant, "MeshId", descendant.MeshId)
		addDependency(descendant, "TextureId", descendant.TextureId)
	elseif descendant:IsA("SurfaceAppearance") then
		addDependency(descendant, "ColorMap", descendant.ColorMap)
		addDependency(descendant, "NormalMap", descendant.NormalMap)
		addDependency(descendant, "RoughnessMap", descendant.RoughnessMap)
		addDependency(descendant, "MetalnessMap", descendant.MetalnessMap)
	elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
		addDependency(descendant, "Texture", descendant.Texture)
		if descendant.Parent and descendant.Parent:IsA("MeshPart") then
			table.insert(warnings, descendant:GetFullName() .. " is a face/projection texture under a MeshPart; verify it is intentional")
		end
	elseif descendant:IsA("Animation") then
		addDependency(descendant, "AnimationId", descendant.AnimationId)
	elseif descendant:IsA("Shirt") then
		addDependency(descendant, "ShirtTemplate", descendant.ShirtTemplate)
	elseif descendant:IsA("Pants") then
		addDependency(descendant, "PantsTemplate", descendant.PantsTemplate)
	elseif descendant:IsA("ShirtGraphic") then
		addDependency(descendant, "Graphic", descendant.Graphic)
	end
end

local report = {
	status = if #blockers == 0 then "DEPENDENCY_AUDIT_PASS" else "DEPENDENCY_AUDIT_BLOCKED",
	modelPath = MODEL_PATH,
	placeId = game.PlaceId,
	gameId = game.GameId,
	creatorId = game.CreatorId,
	dependencyCount = #dependencies,
	dependencies = dependencies,
	blockers = blockers,
	warnings = warnings,
	note = "Read-only audit. A pass still requires fresh-Play visual verification and Output review.",
}

local json = HttpService:JSONEncode(report)
print("ROBLOX_ASSET_DEPENDENCY_AUDIT " .. json)
return json
