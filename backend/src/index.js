import { handlePoll } from './routes/poll.js';
import { handleCommand } from './routes/command.js';
import { handleRank } from './routes/rank.js';
import { handleDiscordInteraction } from './routes/discord.js';
import { checkStaleCheckouts, checkUsageBudget } from './lib/reminders.js';

export default {
	async fetch(request, env) {
		const url = new URL(request.url);

		if (url.pathname === '/poll') return handlePoll(request, env);
		if (url.pathname === '/command') return handleCommand(request, env);
		if (url.pathname === '/rank') return handleRank(request, env);
		if (url.pathname === '/discord/interactions') return handleDiscordInteraction(request, env);

		return new Response('not found', { status: 404 });
	},

	// Cron Trigger (see wrangler.toml) - checks for stale account checkouts and whether
	// the Worker is nearing its daily request budget. Neither touches the /poll
	// long-polling budget itself (see lib/reminders.js for why that's fine).
	async scheduled(event, env, ctx) {
		ctx.waitUntil(checkStaleCheckouts(env));
		ctx.waitUntil(checkUsageBudget(env));
	},
};
