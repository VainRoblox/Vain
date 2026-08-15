// Nags whoever has an account checked out for 2+ hours to /done it. Runs on a
// Cloudflare Cron Trigger (see wrangler.toml) - separate concern from the /poll
// long-polling budget: this is a handful of Worker invocations every 15 minutes,
// not per-online-user traffic, so it doesn't compete with the request budget that
// ruled out cron for the whitelist-linking flow.

import { getStaleCheckouts, markReminderSent } from './roster.js';
import { postMessage } from './discord.js';

const STALE_THRESHOLD_SECONDS = 2 * 60 * 60;

// Must match ROSTER_CHANNEL_ID in routes/discord.js.
const ROSTER_CHANNEL_ID = '1537805418728919086';

async function checkStaleCheckouts(env) {
	const stale = await getStaleCheckouts(env.DB, STALE_THRESHOLD_SECONDS);
	for (const account of stale) {
		await postMessage(
			ROSTER_CHANNEL_ID,
			{ content: `<@${account.in_use_by}> you've had **${account.name}** checked out for 2+ hours — run \`/done\` when you're finished with it.` },
			env.DISCORD_BOT_TOKEN
		);
		await markReminderSent(env.DB, account.name);
	}
}

export { checkStaleCheckouts };
