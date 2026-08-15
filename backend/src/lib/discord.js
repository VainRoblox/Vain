// Discord interaction signature verification + REST helpers.
//
// NOTE: Ed25519 support in Cloudflare Workers' Web Crypto (crypto.subtle) is what this
// verification relies on. Flagged in the plan as something to confirm still holds for
// the Workers runtime version in use — if `importKey`/`verify` reject the 'Ed25519'
// algorithm name, swap in a small pure-JS ed25519 verify (e.g. @noble/ed25519) instead.

function hexToBytes(hex) {
	const bytes = new Uint8Array(hex.length / 2);
	for (let i = 0; i < bytes.length; i++) {
		bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
	}
	return bytes;
}

async function verifyDiscordRequest(request, bodyText, publicKeyHex) {
	const signature = request.headers.get('X-Signature-Ed25519');
	const timestamp = request.headers.get('X-Signature-Timestamp');
	if (!signature || !timestamp) return false;

	try {
		const key = await crypto.subtle.importKey('raw', hexToBytes(publicKeyHex), { name: 'Ed25519' }, false, ['verify']);
		const message = new TextEncoder().encode(timestamp + bodyText);
		return await crypto.subtle.verify('Ed25519', key, hexToBytes(signature), message);
	} catch (err) {
		return false;
	}
}

// Returns: an array of role IDs on success, 'not_member' if Discord confirms they're
// not (or no longer) in the guild (404 - left, kicked, banned), or null for anything
// else (rate limited, network error, Discord outage) - the caller needs to treat those
// two failure cases very differently: "not in the guild" must revoke rank, "we
// couldn't ask right now" should not.
async function getGuildMemberRoles(guildId, discordUserId, botToken) {
	const res = await fetch(`https://discord.com/api/v10/guilds/${guildId}/members/${discordUserId}`, {
		headers: { Authorization: `Bot ${botToken}` },
	});
	if (res.status === 404) return 'not_member';
	if (!res.ok) return null;
	const member = await res.json();
	return member.roles ?? [];
}

// Standard "reply with a message" interaction response (type 4 = CHANNEL_MESSAGE_WITH_SOURCE).
function replyMessage(content, ephemeral = true) {
	return {
		type: 4,
		data: { content, flags: ephemeral ? 64 : 0 },
	};
}

async function postMessage(channelId, payload, botToken) {
	const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
		method: 'POST',
		headers: { Authorization: `Bot ${botToken}`, 'Content-Type': 'application/json' },
		body: JSON.stringify(payload),
	});
	if (!res.ok) return null;
	return res.json();
}

// Returns false (rather than throwing) if the message was deleted or otherwise
// unreachable - callers use that to know they need to repost instead.
async function editMessage(channelId, messageId, payload, botToken) {
	const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages/${messageId}`, {
		method: 'PATCH',
		headers: { Authorization: `Bot ${botToken}`, 'Content-Type': 'application/json' },
		body: JSON.stringify(payload),
	});
	return res.ok;
}

export { verifyDiscordRequest, getGuildMemberRoles, replyMessage, postMessage, editMessage };
