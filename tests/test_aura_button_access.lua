-- Run from the repository root with a Lua interpreter.
local secret = {}
local sizeCalls = 0
local cooldownTextCalls = 0
local AuraDB = {
	Size = 24,
	ShowType = true,
	Count = {FontSize = 12, Layout = {"CENTER", "CENTER", 0, 0}, Colour = {1, 1, 1, 1}},
}
local UUF = {
	oUF = {RegisterInitCallback = function() end, colors = {dispel = {}}},
	db = {profile = {General = {Fonts = {FontFlag = "OUTLINE", Shadow = {Enabled = false}}}}},
	Media = {Font = "test-font"},
	GetUnitDB = function() return {Auras = {Buffs = AuraDB}} end,
	IsSecretValue = function(_, value) return value == secret end,
	ApplyCooldownText = function() cooldownTextCalls = cooldownTextCalls + 1 end,
}
Enum = {CustomAuraButtonDispelTypeTextureStyle = {Border = 1}}
unpack = unpack or table.unpack
assert(loadfile("vaarattu-unit-frames/Elements/Auras.lua"))("VaarattuUnitFrames", UUF)

local function GetUpvalue(func, name)
	for index = 1, math.huge do
		local key, value = debug.getupvalue(func, index)
		if not key then error("Missing upvalue: " .. name) end
		if key == name then return value end
	end
end

local configure = GetUpvalue(UUF.UpdateUnitAuras, "ConfigureSecureAuraContainer")
local style = GetUpvalue(configure, "StyleAuraButton")
local region = {}
for _, method in ipairs({"SetTexCoord", "SetDrawEdge", "SetDrawSwipe", "SetReverse", "SetAlpha",
	"ClearAllPoints", "SetFont", "SetPoint", "SetShadowColor", "SetShadowOffset", "SetTextColor"}) do
	region[method] = function() end
end
local methods = {
	SetSize = function(_, width, height)
		assert(width == AuraDB.Size and height == AuraDB.Size)
		sizeCalls = sizeCalls + 1
	end,
	ClearDispelTypeTextures = function() end,
	AddDispelTypeTexture = function() end,
	Icon = region, Border = region, Cooldown = region, Count = region, Duration = region,
}
local access = true
local button = setmetatable({CanBeAccessedInContext = function() return access end}, {
	__index = function(_, key)
		assert(access == true, "Attempt to access forbidden object: " .. key)
		return assert(methods[key], "Unexpected button member: " .. key)
	end,
})

-- Initialization and ordinary settings updates retain the configured appearance.
style(button, {}, "player", "Buffs")
assert(sizeCalls == 1 and cooldownTextCalls == 1)

-- The same button becomes inaccessible after the container applies restrictions.
access = false
style(button, {}, "player", "Buffs")
assert(sizeCalls == 1 and cooldownTextCalls == 1)

-- Security metadata can itself be secret; do not branch on that value.
access = secret
style(button, {}, "player", "Buffs")
assert(sizeCalls == 1 and cooldownTextCalls == 1)

-- Once access returns, a subsequent update applies current settings normally.
access = true
AuraDB.Size = 32
style(button, {}, "player", "Buffs")
assert(sizeCalls == 2 and cooldownTextCalls == 2)
print("Aura button access regression checks passed")
