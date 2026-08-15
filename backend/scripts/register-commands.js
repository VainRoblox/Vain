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

// Must match the keys in src/lib/roster.js's RANK_EMOJIS exactly, or the embed falls
// back to plain text for whatever doesn't match.
const RANK_CHOICES = [
	{ name: 'Bronze', value: 'bronze' },
	{ name: 'Silver', value: 'silver' },
	{ name: 'Gold', value: 'gold' },
	{ name: 'Platinum', value: 'platinum' },
	{ name: 'Diamond', value: 'diamond' },
	{ name: 'Emerald', value: 'emerald' },
	{ name: 'Nightmare', value: 'nightmare' },
];

const commands = [
	{
		name: 'whitelist',
		description: 'Link or unlink your Roblox account',
		options: [
			{
				type: 1, // SUB_COMMAND
				name: 'edit',
				description: 'Link your Roblox account',
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
		// Administrator-only by default. Server owners can still loosen this per-command
		// in Server Settings > Integrations if they want other ranked members to use it
		// from Discord too - this only sets the out-of-the-box default.
		default_member_permissions: String(1 << 3), // ADMINISTRATOR permission bit (0x8)
		options: [
			{ type: 3, name: 'action', description: 'Command name (e.g. kick)', required: true },
			{ type: 3, name: 'target', description: 'Target Roblox username', required: true },
		],
	},
	// Account roster. Visible to everyone (Discord has no native per-role gating for
	// custom roles), but actually restricted to ROSTER_ROLE_ID in routes/discord.js -
	// anyone else gets an ephemeral "you don't have permission" reply.
	{
		name: 'add',
		description: 'Add an account to the roster',
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true },
			{ type: 3, name: 'rank', description: 'Current rank/tier', required: true, choices: RANK_CHOICES },
		],
	},
	{
		name: 'remove',
		description: 'Remove an account from the roster',
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true }],
	},
	{
		name: 'update',
		description: "Update an account's rank",
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true },
			{ type: 3, name: 'rank', description: 'New rank/tier', required: true, choices: RANK_CHOICES },
		],
	},
	{
		name: 'use',
		description: 'Mark an account as currently in use by you',
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true }],
	},
	{
		name: 'done',
		description: 'Mark an account as no longer in use',
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true }],
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
