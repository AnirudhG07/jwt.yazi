local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
-- convert to 6 char long binary string. (max int 64!)
local function toBinaryString(int)
	if int > 64 then
		error("Bad number " .. int .. " to convert to binary")
	end
	local remaining = tonumber(int)
	local bits = ""
	for i = 5, 0, -1 do
		local pow = 2 ^ i
		if remaining >= pow then
			bits = bits .. "1"
			remaining = remaining - pow
		else
			bits = bits .. "0"
		end
	end
	return bits
end
local function fromBinaryString(bits)
	return tonumber(bits, 2)
end
local function decodeBase64(encoded)
	local bitstr = ""
	local decoded = ""
	-- decode chars into bitstring
	for i = 1, string.len(encoded) do
		local offset, _ = string.find(alpha, string.sub(encoded, i, i))
		if offset == nil then
			error("Bad base64 character " .. string.sub(encoded, i, i))
		end
		bitstr = bitstr .. toBinaryString(offset - 1)
	end
	-- decode bitstring back to chars
	for i = 1, string.len(bitstr), 8 do
		decoded = decoded .. string.char(fromBinaryString(string.sub(bitstr, i, i + 7)))
	end
	return decoded
end
-- json handling
local json = {}

-- Returns pos, did_find; there are two cases:
-- 1. Delimiter found: pos = pos after leading space + delim; did_find = true.
-- 2. Delimiter not found: pos = pos after leading space;     did_find = false.
-- This throws an error if err_if_missing is true and the delim is not found.
local function skip_delim(str, pos, delim, err_if_missing)
	pos = pos + #str:match("^%s*", pos)
	if str:sub(pos, pos) ~= delim then
		if err_if_missing then
			error("Expected " .. delim .. " near position " .. pos)
		end
		return pos, false
	end
	return pos + 1, true
end

-- Expects the given pos to be the first character after the opening quote.
-- Returns val, pos; the returned pos is after the closing quote character.
local function parse_str_val(str, pos, val)
	val = val or ""
	local early_end_error = "End of input found while parsing string."
	if pos > #str then
		error(early_end_error)
	end
	local c = str:sub(pos, pos)
	if c == '"' then
		return val, pos + 1
	end
	if c ~= "\\" then
		return parse_str_val(str, pos + 1, val .. c)
	end
	-- We must have a \ character.
	local esc_map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
	local nextc = str:sub(pos + 1, pos + 1)
	if not nextc then
		error(early_end_error)
	end
	return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

-- Returns val, pos; the returned pos is after the number's final character.
local function parse_num_val(str, pos)
	local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
	local val = tonumber(num_str)
	if not val then
		error("Error parsing number at position " .. pos .. ".")
	end
	return val, pos + #num_str
end

json.null = {} -- one-off table to represent the null value.
function json.parse(str, pos, end_delim)
	pos = pos or 1
	if pos > #str then
		error("Reached unexpected end of input.")
	end
	local pos = pos + #str:match("^%s*", pos) -- Skip whitespace.
	local first = str:sub(pos, pos)
	if first == "{" then -- Parse an object.
		local obj, key, delim_found = {}, true, true
		pos = pos + 1
		while true do
			key, pos = json.parse(str, pos, "}")
			if key == nil then
				return obj, pos
			end
			if not delim_found then
				error("Comma missing between object items.")
			end
			pos = skip_delim(str, pos, ":", true) -- true -> error if missing.
			obj[key], pos = json.parse(str, pos)
			pos, delim_found = skip_delim(str, pos, ",")
		end
	elseif first == "[" then -- Parse an array.
		local arr, val, delim_found = {}, true, true
		pos = pos + 1
		while true do
			val, pos = json.parse(str, pos, "]")
			if val == nil then
				return arr, pos
			end
			if not delim_found then
				error("Comma missing between array items.")
			end
			arr[#arr + 1] = val
			pos, delim_found = skip_delim(str, pos, ",")
		end
	elseif first == '"' then -- Parse a string.
		return parse_str_val(str, pos + 1)
	elseif first == "-" or first:match("%d") then -- Parse a number.
		return parse_num_val(str, pos)
	elseif first == end_delim then -- End of an object or array.
		return nil, pos + 1
	else -- Parse true, false, or null.
		local literals = {
			["true"] = true,
			["false"] = false,
			["null"] = json.null,
		}
		for lit_str, lit_val in pairs(literals) do
			local lit_end = pos + #lit_str - 1
			if str:sub(pos, lit_end) == lit_str then
				return lit_val, lit_end + 1
			end
		end
		local pos_info_str = "position " .. pos .. ": " .. str:sub(pos, pos + 10)
		error("Invalid json syntax starting at " .. pos_info_str)
	end
end

local function decode_jwt(jwt)
	local i = 0
	local result = {}
	for match in (jwt .. "."):gmatch("(.-)%.") do
		result[i] = decodeBase64(match)
		i = i + 1
	end
	-- header
	local head = json.parse(result[0])
	-- claims
	local claims = json.parse(result[1])
	return { head = head, claims = claims }
end

local function tableToString(t, indent)
	indent = indent or 0
	local prefix = string.rep("  ", indent)
	local result = ""
	for k, v in pairs(t) do
		if type(v) == "table" then
			result = result .. prefix .. k .. ":\n" .. tableToString(v, indent + 1)
		else
			result = result .. prefix .. k .. ": " .. tostring(v) .. "\n"
		end
	end
	return result
end

local M = {}

function M:peek(job)
	local jwt_path = job.file.url
	local jwt =
		"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
	-- local jwt = io.open(jwt_path, "r"):read("*a")

	local decoded = decode_jwt(jwt)
	local decodedString = tableToString(decoded)

	local text = ui.Text(decodedString)
	ya.preview_widgets(job, { text:area(job.area):wrap(ui.Text.WRAP) })
end

function M:seek(job)
	local h = cx.active.current.hovered
	if h and h.url == job.file.url then
		ya.manager_emit("peek", {
			math.max(0, cx.active.preview.skip + job.units),
			only_if = job.file.url,
		})
	end
end

return M
