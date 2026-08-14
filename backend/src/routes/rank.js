import { verifyOrRegisterClientKey } from '../lib/db.js';
import { resolveRankForRobloxUserId } from '../lib/commands.js';

const MAX_UIDS = 50; // one Roblox server's worth of players, generously

// Rank info isn't sensitive on its own, so this only needs light abuse-prevention: the
// caller must be a registered client (same key scheme as /poll) for *some* uid, not
// necessarily the ones it's asking about.
async function handleRank(request, env) {
	const url = new URL(request.url);
	const callerUid = url.searchParams.get('uid');
	const key = url.searchParams.get('key');
	const uidsRaw = url.searchParams.get('uids');

	if (!callerUid || !key || !uidsRaw) {
		return Response.json({ error: 'missing params' }, { status: 400 });
	}

	const owns = await verifyOrRegisterClientKey(env.DB, parseInt(callerUid, 10), key);
	if (!owns) {
		return Response.json({ error: 'key does not match this uid' }, { status: 401 });
	}

	const uids = uidsRaw
		.split(',')
		.map((s) => parseInt(s, 10))
		.filter((n) => Number.isFinite(n))
		.slice(0, MAX_UIDS);

	const ranks = {};
	for (const uid of uids) {
		ranks[uid] = await resolveRankForRobloxUserId(env, uid);
	}
	return Response.json({ ranks });
}

export { handleRank };
