// The shared account roster: name, current in-game rank, and who (if anyone) has it
// checked out. See schema.sql's account_roster table for the shape.

// Guild's custom tier emoji (fetched once via GET /guilds/{id}/emojis and hardcoded
// here - these are static per-emoji IDs, not something that changes at runtime).
const RANK_EMOJIS = {
	bronze: '<:bronze:1537805324101353623>',
	silver: '<:silver:1537805259571859536>',
	gold: '<:gold:1537805148527656960>',
	platinum: '<:platinum:1537805203703730270>',
	diamond: '<:diamond:1537805177497722920>',
	emerald: '<:emerald:1537799234055700520>',
	nightmare: '<:nightmare:1537799266159042701>',
};

// has2fa: true/false to set it, or omitted (undefined) to leave it untouched on an
// existing row - /update calls this without touching 2FA status, since that's set via
// /add's optional `2fa_required` option or changed later with /set2fa. A brand new row
// can't be left "untouched" (the column is NOT NULL), so callers inserting a fresh
// account must pass a real boolean - only handleRosterUpdate (which always targets an
// existing row) omits it.
async function upsertAccount(db, name, rank, has2fa) {
	const now = Math.floor(Date.now() / 1000);
	const has2faValue = has2fa === undefined ? null : has2fa ? 1 : 0;
	await db
		.prepare(
			`INSERT INTO account_roster (name, rank, has_2fa, updated_at) VALUES (?, ?, ?, ?)
			 ON CONFLICT(name) DO UPDATE SET rank = excluded.rank, updated_at = excluded.updated_at,
			 	has_2fa = COALESCE(excluded.has_2fa, account_roster.has_2fa)`
		)
		.bind(name, rank, has2faValue, now)
		.run();
}

async function removeAccount(db, name) {
	const res = await db.prepare('DELETE FROM account_roster WHERE name = ?').bind(name).run();
	return res.meta.changes > 0;
}

// Backs /set2fa - changes only has_2fa on an existing account, unlike upsertAccount
// which also always touches rank.
async function setHas2fa(db, name, has2fa) {
	const now = Math.floor(Date.now() / 1000);
	const res = await db
		.prepare('UPDATE account_roster SET has_2fa = ?, updated_at = ? WHERE name = ?')
		.bind(has2fa ? 1 : 0, now, name)
		.run();
	return res.meta.changes > 0;
}

// Backs /reset ("a new season begins") - only touches rank, leaving checkout status,
// kits, 2FA, and wishlist entries untouched.
async function resetAllRanks(db) {
	const now = Math.floor(Date.now() / 1000);
	const res = await db.prepare("UPDATE account_roster SET rank = '', updated_at = ?").bind(now).run();
	return res.meta.changes;
}

async function getAccount(db, name) {
	return db.prepare('SELECT * FROM account_roster WHERE name = ?').bind(name).first();
}

// Each Discord user can only have one account checked out at a time - this is what
// lets /done skip the name parameter entirely (auto-detects which one to release) and
// what /use checks before letting someone grab a second account.
async function getAccountInUseByUser(db, discordUserId) {
	return db.prepare('SELECT * FROM account_roster WHERE in_use_by = ?').bind(discordUserId).first();
}

async function setInUse(db, name, discordUserId) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('UPDATE account_roster SET in_use_by = ?, checked_out_at = ?, reminder_sent = 0, updated_at = ? WHERE name = ?')
		.bind(discordUserId, now, now, name)
		.run();
}

async function clearInUse(db, name) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('UPDATE account_roster SET in_use_by = NULL, checked_out_at = NULL, reminder_sent = 0, updated_at = ? WHERE name = ?')
		.bind(now, name)
		.run();
}

// Backs the 2-hour stale-checkout reminder cron (see lib/reminders.js). reminder_sent
// stops it from re-notifying every 15 minutes once a reminder's already gone out for
// the current checkout - it resets to 0 on the next /use.
async function getStaleCheckouts(db, thresholdSeconds) {
	const cutoff = Math.floor(Date.now() / 1000) - thresholdSeconds;
	const { results } = await db
		.prepare('SELECT * FROM account_roster WHERE in_use_by IS NOT NULL AND checked_out_at IS NOT NULL AND checked_out_at <= ? AND reminder_sent = 0')
		.bind(cutoff)
		.all();
	return results;
}

async function markReminderSent(db, name) {
	await db.prepare('UPDATE account_roster SET reminder_sent = 1 WHERE name = ?').bind(name).run();
}

async function listAccounts(db) {
	const { results } = await db.prepare('SELECT * FROM account_roster ORDER BY name COLLATE NOCASE').all();
	return results;
}

// Backs the autocomplete on /update and /remove's `name` option - a static Discord
// `choices` list can't work here since it's fixed at command-registration time and
// would go stale the moment an account gets added/removed, so this queries live
// instead. Discord caps autocomplete results at 25.
async function searchAccountNames(db, query) {
	const { results } = await db
		.prepare("SELECT name FROM account_roster WHERE name LIKE ? ESCAPE '\\' ORDER BY name COLLATE NOCASE LIMIT 25")
		.bind(`%${query.replace(/[%_]/g, '\\$&')}%`)
		.all();
	return results.map((r) => r.name);
}

// Highest to lowest. Unranked (no rank at all) always sorts below every tier here;
// unrecognized rank text (a typo, or something without an emoji) sorts just above
// unranked but below every real tier.
const RANK_ORDER = ['nightmare', 'emerald', 'diamond', 'platinum', 'gold', 'silver', 'bronze'];

function rankPriority(rank) {
	if (!rank) return -Infinity;
	const idx = RANK_ORDER.indexOf(rank.toLowerCase());
	return idx === -1 ? -1 : RANK_ORDER.length - idx;
}

function sortByRank(accounts) {
	return [...accounts].sort((a, b) => {
		const diff = rankPriority(b.rank) - rankPriority(a.rank);
		return diff !== 0 ? diff : a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
	});
}

const GUIDELINES = [
	'**Guidelines**',
	"• Run `/use` before playing on an account so everyone can see it's taken.",
	"• Run `/done` the moment you're finished — don't leave it marked as in use.",
	"• Only play on accounts you've checked out with `/use`.",
	"• Keep an account's rank up to date with `/update` as it levels.",
	'• 🔒 next to a name means that account has 2FA — you\'ll need a code from whoever owns it.',
].join('\n');

function buildRosterEmbed(accounts) {
	const lines = accounts.length
		? sortByRank(accounts).map((a) => {
				let rankLabel = '';
				if (a.rank) {
					const emoji = RANK_EMOJIS[a.rank.toLowerCase()];
					// Unrecognized rank text (typo, or a tier without an emoji) - fall back to
					// showing it as plain text rather than dropping it silently.
					rankLabel = (emoji || `\`${a.rank}\``) + ' ';
				}
				const twofa = a.has_2fa ? ' 🔒' : '';
				// No rank at all (unranked) - no emoji, no label, just the name.
				const inUse = a.in_use_by ? ` — *currently used by <@${a.in_use_by}>*` : '';
				return `${rankLabel}**${a.name}**${twofa}${inUse}`;
			})
		: ['*No accounts yet — add one with `/add`.*'];

	return {
		title: 'Account Roster',
		description: `${GUIDELINES}\n\n${lines.join('\n')}`,
		color: 0x054785,
		fields: [
			{
				name: 'Commands',
				value: [
					'`/add name:<account> rank:<tier> 2fa_required:<optional>` — add an account (mark 2fa_required if it needs a code from someone)',
					'`/update name:<account> rank:<tier>` — change its rank',
					'`/remove name:<account>` — remove it',
					'`/use name:<account>` — marks account as being currently used by you',
					'`/done` — marks your checked-out account as free again',
					'`/addkit name:<account> kit:<kit>` — record that an account owns a kit',
					'`/removekit name:<account> kit:<kit>` — remove a kit from an account',
					"`/kits name:<account>` — list an account's owned kits",
					'`/kitowners kit:<kit>` — list every account that owns a kit',
					'',
					'*Wishlist (optional):*',
					'`/addwish kit:<kit> account:<optional>` — add a kit to the wishlist',
					'`/removewish kit:<kit> account:<optional>` — remove a wishlist entry',
					'`/wishlist` — view the wishlist',
				].join('\n'),
			},
		],
		footer: { text: `${accounts.length} account${accounts.length === 1 ? '' : 's'}` },
		timestamp: new Date().toISOString(),
	};
}

// Kit ownership is deliberately separate from the main embed (the user asked for it to
// only be visible via an ephemeral /kits reply, not shown to everyone in the channel).

async function addKit(db, accountName, kitName) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO account_kits (account_name, kit_name, added_at) VALUES (?, ?, ?) ON CONFLICT(account_name, kit_name) DO NOTHING')
		.bind(accountName, kitName, now)
		.run();
}

async function removeKit(db, accountName, kitName) {
	const res = await db.prepare('DELETE FROM account_kits WHERE account_name = ? AND kit_name = ?').bind(accountName, kitName).run();
	return res.meta.changes > 0;
}

async function listKitsForAccount(db, accountName) {
	const { results } = await db
		.prepare('SELECT kit_name FROM account_kits WHERE account_name = ? ORDER BY kit_name COLLATE NOCASE')
		.bind(accountName)
		.all();
	return results.map((r) => r.kit_name);
}

async function listAccountsWithKit(db, kitName) {
	const { results } = await db
		.prepare('SELECT account_name FROM account_kits WHERE kit_name = ? ORDER BY account_name COLLATE NOCASE')
		.bind(kitName)
		.all();
	return results.map((r) => r.account_name);
}

// Kits nobody owns yet, optionally tied to a preferred account. preferredAccount may be
// null (a general "we should get this" request with no account in mind).
async function addWish(db, kitName, preferredAccount, requestedBy) {
	const now = Math.floor(Date.now() / 1000);
	await db
		.prepare('INSERT INTO kit_wishlist (kit_name, preferred_account, requested_by, requested_at) VALUES (?, ?, ?, ?)')
		.bind(kitName, preferredAccount, requestedBy, now)
		.run();
}

// `IS` (not `=`) so a null preferredAccount correctly matches rows with a null
// preferred_account, instead of matching nothing the way `= NULL` would.
async function removeWish(db, kitName, preferredAccount) {
	const res = await db
		.prepare('DELETE FROM kit_wishlist WHERE kit_name = ? AND preferred_account IS ?')
		.bind(kitName, preferredAccount)
		.run();
	return res.meta.changes > 0;
}

async function listWishlist(db) {
	const { results } = await db.prepare('SELECT * FROM kit_wishlist ORDER BY kit_name COLLATE NOCASE, requested_at').all();
	return results;
}

export {
	upsertAccount,
	removeAccount,
	setHas2fa,
	resetAllRanks,
	getAccount,
	getAccountInUseByUser,
	setInUse,
	clearInUse,
	listAccounts,
	searchAccountNames,
	buildRosterEmbed,
	addKit,
	removeKit,
	listKitsForAccount,
	listAccountsWithKit,
	getStaleCheckouts,
	markReminderSent,
	addWish,
	removeWish,
	listWishlist,
};
