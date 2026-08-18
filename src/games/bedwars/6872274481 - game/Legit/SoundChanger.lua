local SoundChanger
local List
local soundlist = {}
local old

SoundChanger = vain.Legit:CreateModule({
	Name = 'SoundChanger',
	Function = function(callback)
		if callback then
			-- Hooks AudioManager rather than SoundManager. SoundManager no longer exists
			-- in the game, so reading .playSound off it threw the moment this was
			-- switched on - and even shimmed it would only have caught sounds this
			-- script plays, never the game's own, which is the entire point here.
			if not bedwars.AudioManager then return end
			old = bedwars.AudioManager.playAudio
			bedwars.AudioManager.playAudio = function(self, id, ...)
				if soundlist[id] then
					id = soundlist[id]
				end

				return old(self, id, ...)
			end
		elseif old then
			bedwars.AudioManager.playAudio = old
			old = nil
		end
	end,
	Tooltip = 'Change ingame sounds to custom ones.'
})
List = SoundChanger:CreateTextList({
	Name = 'Sounds',
	Tooltip = 'Sounds to use',
	Placeholder = '(DAMAGE_1/ben.mp3)',
	Function = function()
		table.clear(soundlist)
		for _, entry in List.ListEnabled do
			local split = entry:split('/')
			local id = bedwars.SoundList[split[1]]
			if id and #split > 1 then
				soundlist[id] = split[2]:find('rbxasset') and split[2] or isfile(split[2]) and assetfunction(split[2]) or ''
			end
		end
	end
})