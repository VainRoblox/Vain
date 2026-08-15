import { handlePoll } from './routes/poll.js';
import { handleCommand } from './routes/command.js';
import { handleRank } from './routes/rank.js';
import { handleDiscordInteraction } from './routes/discord.js';
import { checkStaleCheckouts } from './lib/reminders.js';

export default {
	async fetch(request, env) {
		const url = new URL(request.url);

		if (url.pathname === '/poll') return handlePoll(request, env);
		if (url.pathname === '/command') return handleCommand(request, env);
		if (url.pathname === '/rank') return handleRank(request, env);
		if (url.pathname === '/discord/interactions') return handleDiscordInteraction(request, env);

		return new Response('not found', { status: 404 });
	},

	// Cron Trigger (see wrangler.toml) - only checks for stale account checkouts, does
	// not touch the /poll long-polling budget (see lib/reminders.js for why that's fine).
	async scheduled(event, env, ctx) {
		ctx.waitUntil(checkStaleCheckouts(env));
	},
};
