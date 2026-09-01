# Vain API

Cloudflare Worker backend for the rank/command system. See `/home/vain/.claude/plans/shiny-popping-sutton.md` (or ask Claude) for the full design — this is just setup steps.

## One-time setup

1. **Install deps**: `npm install` (inside `backend/`)
2. **Create the D1 database**: `npx wrangler d1 create vain-api` — copy the `database_id` it prints into `wrangler.toml`
3. **Create the tables**: `npm run db:init:remote`
4. **Create a Discord application** at discord.com/developers/applications
   - Copy the **Public Key** → `wrangler.toml`'s `DISCORD_PUBLIC_KEY` is set as a secret, not a plain var (see below)
   - Bot tab → create a bot, copy its token
   - Under "Interactions Endpoint URL" you'll set this to `https://<your-worker>.workers.dev/discord/interactions` **after** deploying (step 6) — Discord verifies this URL is live before saving it
5. **Set secrets** (never go in `wrangler.toml` directly):
   ```
   npx wrangler secret put DISCORD_PUBLIC_KEY
   npx wrangler secret put DISCORD_BOT_TOKEN
   npx wrangler secret put DISCORD_APP_ID
   npx wrangler secret put GITHUB_TOKEN
   ```
   `GITHUB_TOKEN` is a fine-grained GitHub PAT scoped to **`VainRoblox/whitelist` only**,
   with `Contents: Read and write`. It is what `/whitelist edit` uses to commit the
   player whitelist that every game client reads — without it the command still links the
   account but reports that the rank is not live.
   There's no shared API secret to set up — see "How auth works" below for why.
6. **Fill in `wrangler.toml`**: `DISCORD_GUILD_ID` = your Discord server's ID
7. **Deploy**: `npm run deploy`
8. Go back to the Discord app's Interactions Endpoint URL field, paste your deployed Worker URL + `/discord/interactions`, save
9. **Register the slash commands** (one-time, or again whenever you change them):
   ```
   npm run register-commands
   ```
   It reads `backend/.dev.vars` — gitignored, one `KEY=value` per line:
   ```
   DISCORD_APP_ID=...
   DISCORD_BOT_TOKEN=...
   ```
   The guild id comes from `wrangler.toml`, so it does not need repeating. Real env vars
   still win if you prefer to pass them inline.
10. **Map Discord roles to ranks** — no admin UI yet (v1), insert rows directly:
    ```
    npx wrangler d1 execute vain-api --remote --command \
      "INSERT INTO rank_config (guild_id, discord_role_id, rank_level) VALUES ('<guild id>', '<role id>', 3)"
    ```
    rank_level: 1 = Premium, 2 = Privileged, 3 = Owner. (No row = Free.)

## Local dev

`npm run dev` runs the Worker locally against a local D1 copy (`npm run db:init` first). Discord's Interactions Endpoint requires a real HTTPS URL though, so testing the `/discord/interactions` route end-to-end needs a deployed Worker (or a tunnel like `cloudflared`) — `/poll`, `/command`, `/rank` can be tested locally directly.

## Linking is one command, no polling

`/whitelist edit roblox:<name>` binds that Roblox username to your Discord account immediately and hands back your personal key in the same reply — no code-in-profile step, no waiting, no background checks of any kind (a per-minute Cron Trigger was tried and dropped — running 1,440 times/day regardless of whether anyone's actually linking burns through the request budget for no reason).

This is intentionally **not** proof that you own that Roblox account. It doesn't need to be: rank is never derived from the Roblox username in a binding, only from the linked Discord account's real (Discord-signed) role membership, checked fresh every time a command is issued. Typing in a Roblox username that isn't really yours doesn't grant you or anyone else a rank they don't already hold on Discord — worst case, your own real commands just get logged as coming from the wrong Roblox account. `/whitelist edit` again with a different username re-binds and evicts the old one.

## How auth works (and why there's no shared secret)

Earlier drafts of this had one HMAC secret embedded in the script for every Vain install. **Don't do that** — the script is public, so anyone could read the secret out of it and forge a request claiming to be any Roblox account, including a real Owner's, and get treated as that rank. Instead:

- **`/command` (issuing a command)** requires `key` = that account's `binding_secret`, generated once at link time and shown to the user exactly once, privately, in their `/whitelist edit` reply. It's never in the script. Only linked (ranked) accounts have one, which is fine since an unranked account could never pass the rank check anyway.
- **`/poll` and `/rank` (a client checking in)** use a different, weaker key: each install generates its own random `pollKey` locally on first run and the server remembers "whoever shows up first with uid X owns X's key from then on" (trust-on-first-use). This only protects against someone else hijacking *your own* queued commands — it can't grant a rank, since `/command` never accepts it.

`src/games/universal - base/base.lua`'s `rankapi` block has no secrets hardcoded — `baseUrl` is the only thing to set after deploying. The command key is set either via the clipboard-based `;rank key` chat command, or the "Rank key" textbox under Settings → General in the GUI — never typed into chat either way, so it's never broadcast to other players.

## Wiring up the Lua client

Just set `rankapi.baseUrl` in `src/games/universal - base/base.lua` to your deployed Worker URL.

## Account roster

`/add`, `/remove`, `/update`, `/use`, `/done` manage a shared list of Roblox accounts the team owns and their current in-game rank/tier — a live Discord embed that anyone with the right role can update, instead of raw chat messages only the original poster can edit.

- `/add name:<account> rank:<tier>` — add an account
- `/update name:<account> rank:<tier>` — change its rank
- `/remove name:<account>` — remove it
- `/use name:<account>` — mark it as checked out by you (shows `in use by @you` on the embed; fails if someone else already has it)
- `/done name:<account>` — mark it free again

The embed lives in one fixed channel (`ROSTER_CHANNEL_ID` in `routes/discord.js`) and gets edited in place every time one of these runs, rather than posting a new message. All five are restricted to `ROSTER_ROLE_ID` (also in `routes/discord.js`) — Discord has no native way to gate a command to an arbitrary custom role, so this is enforced in code; anyone else gets an ephemeral "you don't have permission" reply.

## Trying it out

1. Deploy the Worker, register commands, map at least one Discord role to a rank (steps above)
2. `/whitelist edit roblox:<name>` in Discord — copy the personal key from the reply
3. Join a Roblox game running Vain as both the linked (ranked) account and a second unranked account
4. On the ranked account, either:
   - **Chat**: copy the key to your clipboard, type `;rank key`, then `;rank kick <targetusername> reason here`
   - **GUI**: Settings → General → paste the key into "Rank key", then in "Rank command" type `kick <targetusername> reason here` and press Enter
5. The target account should get kicked within ~25 seconds
