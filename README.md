# Pieceocraft

A Minecraft Bedrock Dedicated Server — the real thing (Mojang's own binary,
not a clone), reachable from any Bedrock client (phone, console, Windows)
over Tailscale, without opening anything to the public internet.

## Setup

Two machines are involved: the one you type these commands on (a laptop is
fine) just needs Ansible — it never runs Docker itself. The other is the
actual server that ends up running everything; it needs nothing but Ubuntu
(or any apt-based Linux), SSH, a user with sudo, and Tailscale already
connected (that's what lets your phone reach it later).

```bash
git clone https://github.com/pieceowater/pieceocraft.git
cd pieceocraft

cp ansible/vars.yml.example ansible/vars.yml         # 1. world name, ops, etc.
$EDITOR ansible/vars.yml

cp ansible/inventory.ini.example ansible/inventory.ini   # 2. point at your server
$EDITOR ansible/inventory.ini

make deploy ANSIBLE_ARGS="--ask-pass --ask-become-pass"  # 3. bring it up
```

`--ask-pass` is your SSH login password; `--ask-become-pass` is the sudo
password, needed only the first time (to install Docker) — harmless to keep
passing it after that. Using an SSH key instead of a password? Put it in
`inventory.ini` (the file has an example line) and drop both flags.

First run takes a minute or two: installing Docker, then the container
downloading the actual Bedrock server binary from Mojang and generating a
fresh world. `make deploy` prints the connect address when it's done.

## Connecting from your phone

1. Make sure Tailscale is connected on the phone (same tailnet as the server).
2. Open Minecraft → **Play** → **Servers** tab → **Add Server**.
3. **Server Address**: your server's Tailscale IP (whatever's in
   `inventory.ini`, e.g. `100.107.212.10`). **Port**: `19132`.

Works identically on Windows, console, or a second phone — anything running
the actual Bedrock client, anywhere that device has Tailscale connected.

## Everyday commands

| | |
|---|---|
| `make deploy` | Set everything up on the server (safe to re-run any time, e.g. after editing `vars.yml`) |
| `make up` / `make down` | Start / stop, keeping the world exactly as it is |
| `make logs` | Tail the server console (`make logs N=500` for more lines) |
| `make console` | Attach to the live console interactively (Ctrl-p Ctrl-q to detach without stopping it) |
| `make cmd CMD="say hello"` | Run one console command without attaching |
| `make backup` | Stop, download a full copy of the world to `backups/`, start again |

These (except `deploy`) just SSH to the server and run `docker compose`
there — no Ansible involved, since that's simpler for something this direct.
Run `make` with no arguments to see all of them, including `restore` and
`destroy`.

## Moving to a different server

The whole point of keeping this in Ansible: moving servers is editing one
line, not redoing any of this by hand.

```bash
make backup                              # 1. on the OLD server: save the world
$EDITOR ansible/inventory.ini            # 2. point at the NEW server
make deploy ANSIBLE_ARGS="--ask-pass --ask-become-pass"   # 3. bring the stack up there (fresh world)
make restore FILE=backups/pieceocraft-data-....tar.gz     # 4. drop your real world in
```

`vars.yml` (world name, gamemode, ops list, ...) travels with you automatically
— it's a local file, not tied to any one server. Only the world itself
(`data/`, which lives *on* whichever server is current) needs the explicit
backup/restore step above.

---

<details>
<summary><strong>Technical details</strong> — architecture, configuration, versions, troubleshooting</summary>

## How it works

`make deploy` runs `ansible/deploy.yml` from your machine against the server
named in `inventory.ini`. What it does there, in order:

0. **Bootstrap** — installs Docker and the Compose plugin if they're missing
   (the only part that needs sudo), adds your SSH user to the `docker`
   group, and checks out this repo on the server itself (default:
   `~/pieceocraft` — see `pieceocraft_dir` in `deploy.yml`'s `vars:` block).
1. Creates the `data/` directory the container bind-mounts.
2. Renders `.env` on the server from `vars.yml` plus `deploy.yml`'s own
   defaults — this is the *only* configuration surface. `docker-compose.yml`
   reads every setting from it via `${VAR:-default}`, which is what makes
   `docker compose up -d` alone (no Ansible) reproduce the exact same
   server — every non-`deploy` Makefile target relies on exactly that.
3. `docker compose up -d`, then waits for the Bedrock binary to print
   `Server started.` before finishing.

Re-running `make deploy` is always safe: step 0 does nothing once Docker is
installed and the repo is checked out (so `--ask-become-pass` stops being
necessary after the first run), and changing a value in `vars.yml` just
rewrites `.env` and lets `docker compose up -d` recreate the container with
the new setting — the world in `data/` is never touched by any of this.

Ansible modules run on the target you name in `inventory.ini`, not on the
machine you type `make deploy` on — that's *why* `docker compose` commands
throughout the Makefile work by SSHing over directly instead: the actual
compose project only ever exists on the server.

## Layout

```
pieceocraft/
├── docker-compose.yml       the one service — itzg/minecraft-bedrock-server
├── Makefile                 every command you need day to day
├── ansible/
│   ├── deploy.yml           the playbook — defaults and rationale live here
│   ├── templates/env.j2     renders .env from vars.yml + deploy.yml's defaults
│   ├── vars.yml.example     template — copy to vars.yml
│   ├── vars.yml             your real world name / gamemode / ops (gitignored)
│   ├── inventory.ini.example  template — copy to inventory.ini
│   ├── inventory.ini        your server's real address (gitignored)
│   └── ansible.cfg          so `ansible-playbook deploy.yml` just works
├── backups/                 downloaded by `make backup` (gitignored)
└── data/                    the world — lives on the SERVER (gitignored)
```

This tree exists twice: once here, wherever you cloned it to run `make
deploy` from, and once more on the server itself, at `~/pieceocraft` by
default — Ansible's bootstrap step puts it there. `data/` only ever
populates the *server's* copy, since that's where the container actually
runs; `.env` is generated there too, never committed.

## Configuration reference

**`ansible/vars.yml`** — the personal stuff: `mc_server_name`,
`mc_level_name`, `mc_level_seed` (empty = random), `mc_gamemode`,
`mc_difficulty`, `mc_allow_cheats`, `mc_max_players`, `mc_ops` (comma-separated
gamertags/XUIDs — auto-resolved to XUIDs at container startup, so a gamertag
needs to have signed into Xbox Live at least once already), and
`mc_allow_list_users`. Comments in `vars.yml.example` cover each one; copy it
to `vars.yml` and edit before your first deploy — nothing there is a secret,
it's gitignored purely because it's personal (like `inventory.ini`).

**The `vars:` block at the top of `ansible/deploy.yml`** — the generic,
non-personal defaults: ports (`mc_server_port` / `mc_server_port_v6`,
default `19132` / `19133`), `mc_online_mode`, `mc_view_distance`,
`mc_allow_list` (off by default — see below), `mc_timezone`, and where the
repo gets checked out on the server (`pieceocraft_dir`).

**Tailscale vs. `mc_allow_list`**: the real access control here is
Tailscale itself — only devices on your tailnet can reach the server's
address at all, allowlist or not. `mc_allow_list` (off by default) is an
optional second layer purely for who's allowed to *join*, useful if your
tailnet is ever shared more broadly than "just people who should be able to
play." Flip `mc_allow_list: true` in `deploy.yml` and fill in
`mc_allow_list_users` (strict `name:XUID` pairs, unlike `mc_ops`) to turn it on.

**`docker-compose.yml`** works standalone too — `docker compose up -d` with
no `.env` at all just uses the inline defaults baked into the file
(`Pieceocraft` / `PieceocraftWorld` / survival / etc.), which is handy for
testing locally before ever touching Ansible.

**`mc_gamerules`** in `deploy.yml`'s `vars:` block — a plain dict of
gamerule → value, reapplied on every `make deploy` (`keepinventory` and
`doimmediaterespawn` by default, aimed at two people playing casually
together rather than a hardcore survival run). Add or remove entries there
freely.

## Versions

Both the wrapper image (`itzg/minecraft-bedrock-server`) and the actual
Bedrock server binary inside it (`MC_VERSION` in `docker-compose.yml`, piped
through from `deploy.yml`'s `mc_version`) are pinned to exact versions, not
`:latest` / `VERSION=LATEST`.

This wasn't the original plan — `VERSION=LATEST` sounds like the right
default, since Bedrock's client/server protocol is version-sensitive and
mobile clients auto-update through the App/Play Store, so in *principle*
holding the server back is what should break connections, not prevent them.
In practice, the newest build available as of 2026-09-16 (`1.26.51.1`) is
simply broken on Linux: it logs `Accepting clients on [::]:19132` and
`Server started.` as if everything's fine, but never actually binds a
working socket — confirmed by checking the kernel's own UDP socket table
inside the container (no listener on `19132` in either protocol family),
reproduced identically under both Docker's default bridge network and
`--network host`. `1.26.45.1` is the last version confirmed to actually
bind and pass traffic.

**Bumping `mc_version` later**, once Mojang ships something past `1.26.51.1`
and you want to move off the pin: test it stands alone before trusting it in
the real deploy —

```bash
docker run --rm -e EULA=TRUE -e VERSION=LATEST -p 29132:19132/udp \
  itzg/minecraft-bedrock-server:2026.8.2
```

then check its logs for `IPv4 supported, port: 19132` — that line's
*presence* is what separates a real working boot from this exact silent
failure (a boot that's actually broken this way just stops after `Server
started.` instead). Only then update `mc_version` in `deploy.yml` and
`docker-compose.yml`'s own default and `make deploy`.

To move the wrapper image itself up (a separate thing from the Bedrock
binary version above), bump the tag in `docker-compose.yml` and run
`make pull`.

## Troubleshooting

**`ssh: connect to host ... port 22: Connection refused` (or similar).**
Check `inventory.ini` has the right address, Tailscale is up on both ends,
and the server is actually reachable — `ping <server>` from the same
machine you're running `make deploy` from.

**A bootstrap task fails asking for a password, or "Missing sudo password".**
You need `ANSIBLE_ARGS="--ask-pass --ask-become-pass"` (password auth) the
first time you deploy to a fresh server, so Ansible can log in and then sudo
to install Docker. Once Docker is installed this becomes unnecessary, but
it's harmless to keep passing it.

**Phone can't see/join the server.** Confirm Tailscale is actually connected
on the phone (not just installed), and that you typed the Tailscale IP, not
a LAN or public address — Bedrock's "Servers" tab doesn't auto-discover
anything outside your literal local network, this always has to be added by
hand. `make ps` on your laptop confirms the container itself is up.

**`make deploy` hangs on "Wait for the world to finish loading".** Usually
first-boot Bedrock binary download taking a while on a slow connection —
`make logs` in another terminal shows progress. If it's stuck for several
minutes with no log output at all, `make logs` and check for a crash instead.

**Phone shows a connection error with `WorldName` set to something other than
`PieceocraftWorld`, or the server just won't respond at all.** Check
`docker inspect pieceocraft-bedrock --format '{{.State.Health.Status}}'` on
the server. If it says `unhealthy`, the Bedrock binary itself has likely
silently failed to bind its port — see [Versions](#versions) above, this is
a known failure mode for a bad `mc_version` pin, not a networking problem on
your end. `docker compose logs bedrock` should show `IPv4 supported, port:
19132` on a genuinely healthy boot; its absence (log just stops after
`Server started.`) confirms it.

**Someone's gamertag in `mc_ops` isn't getting operator.** The image
resolves gamertags to XUIDs over the internet at container startup — a
brand new/never-used Xbox Live tag won't resolve. Check `make logs` right
after a deploy for a resolution failure, and confirm the exact spelling
against the player's actual Xbox gamertag (not their in-game display name,
which can differ).

</details>
