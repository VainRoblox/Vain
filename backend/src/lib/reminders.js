// Nags whoever has an account checked out for 2+ hours to /done it, and warns the
// channel if the Worker is approaching Cloudflare's free-tier daily request limit.
// Both run on a Cloudflare Cron Trigger (see wrangler.toml) - separate concern from the
// /poll long-polling budget: this is a handful of Worker invocations every 15 minutes,
// not per-online-user traffic, so it doesn't compete with the request budget that
// ruled out cron for the whitelist-linking flow.

import { getStaleCheckouts, markReminderSent } from './roster.js';
import { postMessage } from './discord.js';
import { getUsageAlertDate, setUsageAlertDate } from './db.js';

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

// Must match DAILY_REQUEST_BUDGET in routes/discord.js (used there for /status).
const DAILY_REQUEST_BUDGET = 100000;
const USAGE_ALERT_THRESHOLD = 0.9;

// Reads today's request count from Cloudflare's Workers Analytics (GraphQL) - same
// approach as /status, so this needs the same CLOUDFLARE_ANALYTICS_TOKEN secret. Only
// posts once per day (tracked in usage_alert_state) even though this check itself runs
// every 15 minutes, so it doesn't spam the channel while usage stays high.
async function checkUsageBudget(env) {
	const today = new Date().toISOString().slice(0, 10);
	if ((await getUsageAlertDate(env.DB)) === today) return;

	// No orderBy needed (unlike /status's query in routes/discord.js) - the filter
	// already narrows this to a single day, so there's nothing to order.
	const query = `query {
		viewer {
			accounts(filter: { accountTag: "${env.CLOUDFLARE_ACCOUNT_ID}" }) {
				workersInvocationsAdaptive(limit: 1, filter: { scriptName: "vain-api", date_geq: "${today}", date_leq: "${today}" }) {
					sum { requests }
				}
			}
		}
	}`;
	const res = await fetch('https://api.cloudflare.com/client/v4/graphql', {
		method: 'POST',
		headers: { Authorization: `Bearer ${env.CLOUDFLARE_ANALYTICS_TOKEN}`, 'Content-Type': 'application/json' },
		body: JSON.stringify({ query }),
	});
	// Analytics token not set yet, or a transient failure - skip silently, the next
	// cron tick (15 min later) just retries.
	if (!res.ok) return;
	const data = await res.json();
	const count = data?.data?.viewer?.accounts?.[0]?.workersInvocationsAdaptive?.[0]?.sum?.requests ?? 0;
	if (count < DAILY_REQUEST_BUDGET * USAGE_ALERT_THRESHOLD) return;

	const pct = Math.round((count / DAILY_REQUEST_BUDGET) * 100);
	await postMessage(
		ROSTER_CHANNEL_ID,
		{
			content: `⚠️ Vain API is at ${count.toLocaleString()} / ${DAILY_REQUEST_BUDGET.toLocaleString()} requests today (${pct}%) — approaching Cloudflare's free-tier daily limit.`,
		},
		env.DISCORD_BOT_TOKEN
	);
	await setUsageAlertDate(env.DB, today);
}

export { checkStaleCheckouts, checkUsageBudget };
