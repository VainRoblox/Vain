import { claimNextCommand, verifyOrRegisterClientKey } from '../lib/db.js';
import { parseUserId } from '../lib/validate.js';

const HOLD_SECONDS = 25;
const CHECK_INTERVAL_MS = 1500;

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function handlePoll(request, env) {
	const url = new URL(request.url);
	const uid = url.searchParams.get('uid');
	const key = url.searchParams.get('key');

	const targetRobloxUserId = parseUserId(uid);
	if (!targetRobloxUserId || !key) {
		return Response.json({ error: 'missing params' }, { status: 400 });
	}

	const owns = await verifyOrRegisterClientKey(env.DB, targetRobloxUserId, key);
	if (!owns) {
		return Response.json({ error: 'key does not match this uid' }, { status: 401 });
	}

	const deadline = Date.now() + HOLD_SECONDS * 1000;

	while (Date.now() < deadline) {
		const command = await claimNextCommand(env.DB, targetRobloxUserId);
		if (command) {
			return Response.json({
				status: 'command',
				id: command.id,
				command: command.command,
				args: JSON.parse(command.args),
				issuer_roblox_userid: command.issuer_roblox_userid,
			});
		}
		await sleep(CHECK_INTERVAL_MS);
	}

	return Response.json({ status: 'none' });
}

export { handlePoll };
