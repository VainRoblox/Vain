// One-time setup: registers the slash commands with Discord.
// Run with: DISCORD_APP_ID=... DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... node scripts/register-commands.js
// Guild-scoped commands (vs global) show up instantly, which is what you want while testing.

const appId = process.env.DISCORD_APP_ID;
const botToken = process.env.DISCORD_BOT_TOKEN;
const guildId = process.env.DISCORD_GUILD_ID;

if (!appId || !botToken || !guildId) {
	console.error('Set DISCORD_APP_ID, DISCORD_BOT_TOKEN, and DISCORD_GUILD_ID env vars first.');
	process.exit(1);
}

const commands = [
	{
		name: 'whitelist',
		description: 'Link or unlink your Roblox account',
		options: [
			{
				type: 1, // SUB_COMMAND
				name: 'edit',
				description: 'Link a Roblox account (run twice: once to get a code, once to confirm)',
				options: [{ type: 3, name: 'roblox', description: 'Your Roblox username', required: true }],
			},
			{
				type: 1,
				name: 'unlink',
				description: 'Remove your linked Roblox account',
			},
		],
	},
	{
		name: 'command',
		description: 'Run a command on a lower-ranked Roblox user',
		options: [
			{ type: 3, name: 'action', description: 'Command name (e.g. kick)', required: true },
			{ type: 3, name: 'target', description: 'Target Roblox username', required: true },
		],
	},
];

const res = await fetch(`https://discord.com/api/v10/applications/${appId}/guilds/${guildId}/commands`, {
	method: 'PUT',
	headers: {
		Authorization: `Bot ${botToken}`,
		'Content-Type': 'application/json',
	},
	body: JSON.stringify(commands),
});

if (!res.ok) {
	console.error('Failed:', res.status, await res.text());
	process.exit(1);
}
console.log('Registered', commands.length, 'commands.');
