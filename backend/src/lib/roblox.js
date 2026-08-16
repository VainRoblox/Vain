// Talks to Roblox's public API to resolve a username to a UserId.

async function lookupUserId(username) {
	const res = await fetch('https://users.roblox.com/v1/usernames/users', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ usernames: [username], excludeBannedUsers: false }),
	});
	if (!res.ok) return null;
	const data = await res.json();
	const match = data.data?.[0];
	return match ? { userId: match.id, username: match.name } : null;
}

// Bulk version - backs the targets embed's per-player avatars (see syncTargetEmbed in
// routes/discord.js), one request for the whole list instead of one per target.
// requestedUsername on each result mirrors the input exactly, so callers can map a
// result back to the name they asked about regardless of Roblox's canonical casing.
async function lookupUserIds(usernames) {
	if (!usernames.length) return [];
	const res = await fetch('https://users.roblox.com/v1/usernames/users', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ usernames, excludeBannedUsers: false }),
	});
	if (!res.ok) return [];
	const data = await res.json();
	return (data.data ?? []).map((m) => ({ userId: m.id, username: m.name, requestedUsername: m.requestedUsername }));
}

async function getAvatarThumbnails(userIds) {
	if (!userIds.length) return {};
	const res = await fetch(
		`https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=${userIds.join(',')}&size=150x150&format=png&isCircular=false`
	);
	if (!res.ok) return {};
	const data = await res.json();
	const map = {};
	for (const entry of data.data ?? []) {
		if (entry.state === 'Completed' && entry.imageUrl) map[entry.targetId] = entry.imageUrl;
	}
	return map;
}

export { lookupUserId, lookupUserIds, getAvatarThumbnails };
