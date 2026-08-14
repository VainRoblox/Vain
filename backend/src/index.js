import { handlePoll } from './routes/poll.js';
import { handleCommand } from './routes/command.js';
import { handleRank } from './routes/rank.js';
import { handleDiscordInteraction } from './routes/discord.js';

export default {
	async fetch(request, env) {
		const url = new URL(request.url);

		if (url.pathname === '/poll') return handlePoll(request, env);
		if (url.pathname === '/command') return handleCommand(request, env);
		if (url.pathname === '/rank') return handleRank(request, env);
		if (url.pathname === '/discord/interactions') return handleDiscordInteraction(request, env);

		return new Response('not found', { status: 404 });
	},
};
