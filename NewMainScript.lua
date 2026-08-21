--[[
	Entry point people inject.

	This used to be a full second copy of the loader, duplicated from src/loader.lua.
	The two drifted: fixes made to src/loader.lua were compiled into
	VainCompiled/loader.lua, which this file never loaded, so injecting kept running
	the old logic and no update could ever arrive. Keeping one source of truth is the
	whole point of this file being three lines - it fetches the compiled loader and
	runs it, so any future loader change reaches everyone without touching this.

	The nocache query string plus the HttpGet cache flag matter: executors cache
	responses keyed by URL, and a cached copy of the loader would pin the client to
	an old build exactly the way the duplicate did.
]]

local url = 'https://raw.githubusercontent.com/VainRoblox/VainCompiled/main/loader.lua?nocache=' .. tick()

local ok, source = pcall(function()
	return game:HttpGet(url, true)
end)

if not ok or type(source) ~= 'string' or source == '' or source == '404: Not Found' then
	error('[Vain] could not download the loader: ' .. tostring(source))
end

return loadstring(source, 'loader')()
