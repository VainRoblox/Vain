import { getBindingByRobloxId } from '../lib/db.js';
import { issueCommand } from '../lib/commands.js';

// Called by a Roblox client issuing a command against another player it sees in-game.
// (The Discord bot issues commands through issueCommand() directly, not this HTTP route -
// see routes/discord.js, which is authenticated by Discord's own signed interaction instead.)
//
// Auth here is the actual security boundary of the whole feature: `key` must match the
// issuer's own binding_secret (given to them once, privately, when they linked via
// /whitelist edit). Only a real linked account can ever pass this - there is no shared
// secret embedded in the public script that would let anyone impersonate a ranked user.
async function handleCommand(request, env) {
	const url = new URL(request.url);
	const issuerUid = url.searchParams.get('issuer_uid');
	const targetUid = url.searchParams.get('target_uid');
	const command = url.searchParams.get('command');
	const argsRaw = url.searchParams.get('args') || '[]';
	const key = url.searchParams.get('key');

	if (!issuerUid || !targetUid || !command || !key) {
		return Response.json({ error: 'missing params' }, { status: 400 });
	}

	const issuerRobloxUserId = parseInt(issuerUid, 10);
	const binding = await getBindingByRobloxId(env.DB, issuerRobloxUserId);
	if (!binding || binding.binding_secret !== key) {
		// Deliberately the same error whether the account isn't linked at all or the key
		// is just wrong - doesn't help an attacker tell which.
		return Response.json({ error: 'not authorized' }, { status: 401 });
	}

	let args;
	try {
		args = JSON.parse(argsRaw);
	} catch {
		return Response.json({ error: 'invalid args' }, { status: 400 });
	}

	const result = await issueCommand(env, {
		issuerRobloxUserId,
		targetRobloxUserId: parseInt(targetUid, 10),
		command,
		args,
	});

	if (!result.ok) {
		return Response.json({ error: result.error }, { status: result.status });
	}
	return Response.json({ status: 'queued', id: result.id });
}

export { handleCommand };
