// Constant-time string comparison. Both secret checks in this API (binding_secret in
// routes/command.js, poll_key in lib/db.js) need this instead of `===`/`!==` - a plain
// comparison exits as soon as it hits the first mismatched character, which leaks a
// tiny timing signal an attacker on the public internet could use to guess a secret
// byte-by-byte over enough requests. This always walks the full length regardless.
function constantTimeEqual(a, b) {
	if (typeof a !== 'string' || typeof b !== 'string') return false;
	if (a.length !== b.length) return false;

	let diff = 0;
	for (let i = 0; i < a.length; i++) {
		diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	}
	return diff === 0;
}

export { constantTimeEqual };
