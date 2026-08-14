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

export { lookupUserId };
