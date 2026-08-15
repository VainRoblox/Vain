// Bedwars kit catalog, for the /addkit /removekit autocomplete.
//
// This is a best-effort transcription from a screenshot of the in-game kit picker -
// NOT guaranteed complete or free of typos, and Bedwars adds new kits over time (new
// seasons, new bundles) that this won't include automatically. It's just a plain
// array, so fixing/extending it later is a one-line edit, not a schema change - no
// kit "catalog" table exists on purpose, since this list is expected to need manual
// upkeep anyway.
const KIT_LIST = [
	// Free Kits
	'Isabel',
	'Ragnar',
	'Marcel',
	// Regular Kits
	'Abaddon',
	'Aedutole',
	'Archer',
	'Axolotl Amy',
	'Baker',
	'Barbarian',
	'Builder',
	'Crypt',
	'Cyber',
	'Death Adder',
	'Eldertree',
	'Eldric',
	'Evelynn',
	'Farmer Cletus',
	'Freiya',
	'Grim Reaper',
	'Grove',
	'Hannah',
	'Infernal Shielder',
	'Kaida',
	'Lassy',
	'Lian',
	'Lyla',
	'Marina',
	'Marrow',
	'Martin',
	'Melody',
	'Milo',
	'Miner',
	'Nahla',
	'Nazar',
	'Pirate Davey',
	'Ramil',
	'Silas',
	'Skoll',
	'Trinity',
	'Triton',
	'Trixie',
	'Uma',
	'Vanessa',
	'Void Knight',
	'Vulcan',
	'Wren',
	'Yuzi',
	'Zarrah',
	'Zenith',
	'Zeno',
	// Level Kits
	'Whisper',
	'Taliyah',
	// Battle Pass Kits - Season 1
	'Warrior',
	'Bounty Hunter',
	'Beekeeper Beatrix',
	'Jade',
	'Raven',
	'Spirit Catcher',
	'Pyro',
	// Season 2
	'Trapper',
	'Gompy',
	'Fisherman',
	'Jack',
	'Ares',
	// Season 3
	'Santa',
	'Gingerbread Man',
	'Smoke',
	'Yeti',
	'Frosty',
	'Aery',
	// Season 4
	'Metal Detector',
	'Alchemist',
	'Sheep Herder',
	'Crocowolf',
	'Conqueror',
	'Nyx',
	// Season 5
	'Lucía',
	'Merchant Marco',
	'Dino Tamer Dom',
	'Cobalt',
	'Star Collector Stella',
	'Zephyr',
	// Season 6
	'Lani',
	'Whim',
	"Xu'rot",
	'Warden',
	'Kaliyah',
	// Season 7
	'Drill',
	'Flora',
	'Umbra',
	'Caitlyn',
	// Season 8
	'Ignis',
	'Fortuna',
	'Elektra',
	// Season 9
	'Umeko',
	'Yamini',
	'Cogsworth',
	'Noelle',
	'Terra',
	// Season X
	'Agni',
	'Styx',
	'Nyoka',
	'Bekzat',
	'Hephaestus',
	// Spring Battle Pass
	'Zola',
	// Bundle Kits
	'Ember',
	'Lumen',
	'Void Regent',
	'Sheila',
	'Sigrid',
	'Krystal',
	'Sophia',
];

function searchKits(query) {
	const q = (query || '').toLowerCase();
	return KIT_LIST.filter((k) => k.toLowerCase().includes(q)).slice(0, 25);
}

export { KIT_LIST, searchKits };
