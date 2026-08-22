import { handlePoll } from './routes/poll.js';
import { handleCommand } from './routes/command.js';
import { handleRank } from './routes/rank.js';
import { handleDiscordInteraction } from './routes/discord.js';
import { checkStaleCheckouts, checkUsageBudget } from './lib/reminders.js';

export default {
	async fetch(request, env, ctx) {
		const url = new URL(request.url);

		if (url.pathname === '/poll') return handlePoll(request, env);
		if (url.pathname === '/command') return handleCommand(request, env);
		if (url.pathname === '/rank') return handleRank(request, env);
		// ctx is passed through so interactions can be deferred - see routes/discord.js.
		if (url.pathname === '/discord/interactions') return handleDiscordInteraction(request, env, ctx);

		// Reports whether the Worker is configured, without exposing any secret values -
		// only whether each one is present. A bot that never answers looks identical
		// whether the public key is missing, the endpoint is misconfigured, or the code
		// is timing out, and there was no way to tell those apart from outside.
		if (url.pathname === '/status') {
			let db = 'unknown';
			try {
				await env.DB.prepare('SELECT 1').first();
				db = 'ok';
			} catch (err) {
				db = `error: ${err}`;
			}
			return Response.json({
				ok: true,
				db,
				guildId: env.DISCORD_GUILD_ID ?? null,
				secrets: {
					DISCORD_PUBLIC_KEY: Boolean(env.DISCORD_PUBLIC_KEY),
					DISCORD_BOT_TOKEN: Boolean(env.DISCORD_BOT_TOKEN),
					DISCORD_APP_ID: Boolean(env.DISCORD_APP_ID),
				},
				// Present only on a build that includes interaction deferral.
				defersInteractions: true,
			});
		}

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
