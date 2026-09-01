// One-time setup: registers the slash commands with Discord. Run it again whenever the
// list below changes - Discord keeps offering whatever was registered last, including
// commands the Worker no longer answers.
//
// Guild-scoped commands (vs global) show up instantly, which is what you want while
// testing.
//
// Config comes from, in order of preference: real env vars, then .dev.vars (wrangler's
// own local-secrets file, already gitignored), then wrangler.toml for the guild id since
// that one is a plain var rather than a secret. So `npm run register-commands` works on
// its own once .dev.vars exists, instead of needing three variables typed in front of it
// every time - which is how a bot token ends up in your shell history.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));

function readIfPresent(path) {
	try {
		return readFileSync(path, 'utf8');
	} catch {
		return '';
	}
}

// KEY=value per line, # comments and blanks ignored. Values are used verbatim apart from
// one optional layer of surrounding quotes.
function parseVars(text) {
	const out = {};
	for (const line of text.split('\n')) {
		const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
		if (match) out[match[1]] = match[2].trim().replace(/^["']|["']$/g, '');
	}
	return out;
}

const devVars = parseVars(readIfPresent(join(here, '..', '.dev.vars')));
const tomlVars = parseVars(readIfPresent(join(here, '..', 'wrangler.toml')));

const appId = process.env.DISCORD_APP_ID || devVars.DISCORD_APP_ID;
const botToken = process.env.DISCORD_BOT_TOKEN || devVars.DISCORD_BOT_TOKEN;
const guildId = process.env.DISCORD_GUILD_ID || devVars.DISCORD_GUILD_ID || tomlVars.DISCORD_GUILD_ID;

if (!appId || !botToken || !guildId) {
	const missing = [
		!appId && 'DISCORD_APP_ID',
		!botToken && 'DISCORD_BOT_TOKEN',
		!guildId && 'DISCORD_GUILD_ID',
	].filter(Boolean);

	console.error(`Missing: ${missing.join(', ')}`);
	console.error('Put them in backend/.dev.vars (gitignored), one KEY=value per line, then re-run.');
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
	// Account roster. Visible to everyone (Discord has no native per-role gating for
	// custom roles), but actually restricted to ROSTER_ROLE_ID in routes/discord.js -
	// anyone else gets an ephemeral "you don't have permission" reply.
	{
		name: 'add',
		description: 'Add an account to the roster',
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true },
			{ type: 3, name: 'rank', description: 'Current rank/tier', required: true, choices: RANK_CHOICES },
			{ type: 5, name: '2fa_required', description: '2FA Required — needs a code from the owner to log in', required: false },
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
		name: 'set2fa',
		description: "Update an account's 2FA Required setting",
		options: [
			{ type: 3, name: 'name', description: 'Roblox account name', required: true, autocomplete: true },
			{ type: 5, name: 'value', description: '2FA Required — needs a code from the owner to log in', required: true },
		],
	},
	{
		name: 'reset',
		description: 'Reset every account to Unranked (new season)',
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
	// Target list - separate embed/channel from the account roster, same role gate.
	{
		name: 'addtarget',
		description: 'Add a player to the targets list',
		options: [
			{ type: 3, name: 'target', description: 'Roblox username', required: true },
			{ type: 3, name: 'reason', description: 'Why this player is a target (optional)', required: false },
		],
	},
	{
		name: 'removetarget',
		description: 'Remove a player from the targets list',
		options: [{ type: 3, name: 'target', description: 'Roblox username', required: true, autocomplete: true }],
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
