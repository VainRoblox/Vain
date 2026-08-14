// Roblox UserIds are always positive integers. Parsing a malformed value with plain
// parseInt() can produce NaN, which then gets bound into a D1 query as a parameter of
// an unexpected type - better to reject it cleanly here than find out what D1 does
// with a stray NaN.
function parseUserId(raw) {
	if (raw === null || raw === undefined || raw === '') return null;
	const n = Number(raw);
	if (!Number.isInteger(n) || n <= 0) return null;
	return n;
}

export { parseUserId };
