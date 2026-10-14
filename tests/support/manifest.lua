-- The addon manifests contain only Script/Include file entries, not UI templates.
local function files(path)
	local result = {}
	local function visit(file)
		if file:match("%.xml$") then
			local handle = assert(io.open(file))
			local xml = handle:read("*a")
			handle:close()
			local directory = file:match("^(.*[/\\])") or ""
			for tag, dependency in xml:gmatch('<(%w+)%s+file="([^"]+)"') do
				assert(tag == "Script" or tag == "Include")
				visit(directory .. dependency)
			end
		else
			result[#result + 1] = file
		end
	end
	for line in io.lines(path) do
		if line:match("%.lua$") or line:match("%.xml$") then
			visit(line)
		end
	end
	return result
end

return files
