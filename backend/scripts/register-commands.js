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
// back to plain text for whatever doesn't match. 'unranked' is a sentinel handled
// specially in routes/discord.js (normalized to an empty rank, same as the old
// "just leave the field blank" behavior) - it's not a real emoji key.
const RANK_CHOICES = [
	{ name: 'Bronze', value: 'bronze' },
	{ name: 'Silver', value: 'silver' },
	{ name: 'Gold', value: 'gold' },
	{ name: 'Platinum', value: 'platinum' },
	{ name: 'Diamond', value: 'diamond' },
	{ name: 'Emerald', value: 'emerald' },
	{ name: 'Nightmare', value: 'nightmare' },
	{ name: 'Unranked', value: 'unranked' },
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
		// autocomplete (not static choices) so the list always reflects the current
		// roster instead of going stale between registrations - see handleAutocomplete
		// in routes/discord.js.
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true }],
	},
	{
		name: 'update',
		description: "Update an account's rank",
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true },
			{ type: 3, name: 'rank', description: 'New rank/tier', required: true, choices: RANK_CHOICES },
		],
	},
	{
		name: 'use',
		description: 'Mark an account as currently used by you',
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true }],
	},
	{
		name: 'done',
		description: 'Release whichever account you currently have checked out',
	},
	// Kit ownership per account. Separate from the main roster embed on purpose - only
	// visible via ephemeral replies, not posted into the channel. /addkit and /removekit
	// are mutations (role-gated in routes/discord.js); /kits is read-only (open to
	// everyone, same as the embed itself).
	{
		name: 'addkit',
		description: 'Record that an account owns a kit',
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true },
			{ type: 3, name: 'kit', description: 'Kit name', required: true, autocomplete: true },
		],
	},
	{
		name: 'removekit',
		description: 'Remove a kit from an account',
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true },
			{ type: 3, name: 'kit', description: 'Kit name', required: true, autocomplete: true },
		],
	},
	{
		name: 'kits',
		description: "List an account's owned kits",
		options: [{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true }],
	},
	{
		name: 'kitowners',
		description: 'List every account that owns a given kit',
		options: [{ type: 3, name: 'kit', description: 'Kit name', required: true, autocomplete: true }],
	},
	// Wishlist - open to everyone, not role-gated (a suggestion note, not roster state).
	{
		name: 'addwish',
		description: 'Add a kit to the team wishlist',
		options: [
			{ type: 3, name: 'kit', description: 'Kit name', required: true, autocomplete: true },
			{ type: 3, name: 'account', description: 'Preferred account for this kit (optional)', required: false, autocomplete: true },
		],
	},
	{
		name: 'removewish',
		description: 'Remove a wishlist entry',
		options: [
			{ type: 3, name: 'kit', description: 'Kit name', required: true, autocomplete: true },
			{ type: 3, name: 'account', description: 'Preferred account (leave blank for the general entry)', required: false, autocomplete: true },
		],
	},
	{
		name: 'wishlist',
		description: 'List the team kit wishlist',
	},
	{
		name: 'status',
		description: "Show today's Vain API request usage against the daily budget",
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
