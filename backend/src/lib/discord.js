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

async function getGuildMemberRoles(guildId, discordUserId, botToken) {
	const res = await fetch(`https://discord.com/api/v10/guilds/${guildId}/members/${discordUserId}`, {
		headers: { Authorization: `Bot ${botToken}` },
	});
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

export { verifyDiscordRequest, getGuildMemberRoles, replyMessage };
