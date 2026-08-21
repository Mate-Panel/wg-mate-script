# wg-mate installer

Installer and manager for the **wg-mate** VPN panel — a single Bash script that installs Docker, pulls the public images from GHCR, generates the compose stack and credentials, and gives you an interactive menu for day-to-day operations.

WireGuard · OpenVPN · Xray — one panel, one command.

---

## Install

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh)"
```

Or download first, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh -o install.sh
sudo bash install.sh
```

To run an action straight from the one-liner, separate it with `--`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh)" -- install
```

The installer asks for the image tag, the panel web port and the admin account, then prints the panel URL and credentials when it is done. Open the panel, log in, and activate your license.

## The `wg-mate` command

After the first install, a shortcut is placed at `/usr/local/bin/wg-mate`. Type it from anywhere to open the manager:

```bash
wg-mate
```

```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ▌ WG-MATE  — WireGuard / OpenVPN / Xray Panel
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ▌ Version
  ────────────────────────────────────────────────────
    Installer  : ● 4.1.0 (up to date)
    Panel      : ● v0.2.4
    Channel    : stable

  ▌ Panel Status
  ────────────────────────────────────────────────────
    State      : ● running
    Containers : 3/3 up
    URL        : http://203.0.113.10:3000
    API        : ● healthy (127.0.0.1:52653)
    Directory  : /opt/wg-mate

  ▌ Services
  ────────────────────────────────────────────────────
    web        : ● Up 2 hours
    api        : ● Up 2 hours
    db         : ● Up 2 hours (healthy)
    Port 3000  : ● ours (web)

  ▌ System
  ────────────────────────────────────────────────────
    OS         : Ubuntu 24.04 LTS
    Docker     : ● 27.3.1
    WireGuard  : ● kernel module ready
    Server IP  : 203.0.113.10

  ▌ Resources
  ────────────────────────────────────────────────────
    RAM        : 812MB / 3936MB  (20%)
    Disk       : 6.1G / 78G  (8%)
    Uptime     : 3 days, 4 hours

  ▌ Menu
  ────────────────────────────────────────────────────
    [1]  Install panel
    [2]  Update panel
    [3]  Change update channel
    [4]  Panel status
    [5]  Show logs
    [6]  Start services
    [7]  Stop services
    [8]  Restart services
    [9]  Remove panel
    [10] Purge everything
    [11] Help & Parameters
    [0]  Exit
  ────────────────────────────────────────────────────

  ❯ Select an option [0-11]:
```

Every action is also available directly:

```bash
wg-mate update
wg-mate logs
wg-mate status
```

## Self-updating

The script updates itself on every run. Before doing anything it fetches the newest version from this repository, validates it (shebang, syntax check, expected functions) and only then replaces itself and restarts. A failed download, a broken file or no internet connection is ignored silently — the installed version keeps working.

```bash
wg-mate version           # show the installer version
```

Self-update is skipped automatically when the script is run from a git clone, so development copies are never overwritten.

---

## Requirements

| | |
|---|---|
| OS | Ubuntu / Debian (apt), or RHEL / CentOS / Fedora (dnf, yum) |
| Access | root (`sudo`) |
| Docker | installed automatically if missing |
| Kernel | `wireguard` and `tun` modules (loaded automatically; install `linux-headers` if the module is missing) |

---

## Commands

```bash
sudo bash install.sh install      # first-time setup
sudo bash install.sh update       # pull a newer tag and recreate the stack
sudo bash install.sh channel      # switch the update channel
sudo bash install.sh status       # container state + api health
sudo bash install.sh logs         # follow logs
sudo bash install.sh restart
sudo bash install.sh start
sudo bash install.sh stop         # stop containers, keep data
sudo bash install.sh doctor       # diagnose a broken install
sudo bash install.sh backup       # database + config archive
sudo bash install.sh restore      # restore from a backup archive
sudo bash install.sh remove       # remove containers, keep data
sudo bash install.sh purge        # remove everything, permanently
sudo bash install.sh version      # print the installer version
```

`upgrade` and `uninstall` still work as aliases of `update` and `remove`.

Every command also takes flags, so a whole install can run unattended:

```bash
sudo bash install.sh install --channel stable --admin admin --password secret123 --web-port 3000
sudo bash install.sh update --version v0.2.4
sudo bash install.sh logs --service api
sudo bash install.sh restore --file /opt/wg-mate/backups/wg-mate-20260101-120000.tar.gz
sudo bash install.sh --help
```

An interrupted install is resumable: every finished phase (Docker, configuration, images, start) is recorded, and the next `install` run offers to continue from the last completed step without asking again for the answers you already gave.

`update` pulls the newest images and recreates the containers — the database, WireGuard keys, certificates and panel settings are untouched.

`purge` is destructive: it deletes the containers, the Docker volumes (including the database), `/opt/wg-mate`, the host helper systemd units and the nginx vhosts created by the panel. It asks you to type `DELETE` to confirm.

---

## Ports and credentials

The installer takes no environment variables at all — it asks for the panel web port and the admin account, and everything else is fixed in the script:

| | |
|---|---|
| **API port** | `52653`, fixed — the images default to it, so there is nothing to configure |
| **PostgreSQL** | bound to `127.0.0.1:5433` only, so it is not reachable from outside the server |
| **Admin login** | asked during install and handed to the panel through a one-shot file, which the installer removes once the api is up — it is never stored in `.env` or in any container environment |
| **Image tag** | the channel picked during install — `stable` (`latest`), `beta` (`dev`) or one pinned `vX.Y.Z`; it is stored in `.env` and changed from menu option 3. The panel version shown in the menu is read from the running api, not from the tag |

Because the admin credentials are not stored on disk, a password is never recovered. Change it from
inside the panel, under the admin account settings. The installer has no password-reset command.

---

## What gets installed

```
/opt/wg-mate/
├── docker-compose.yml     generated by the installer
├── .env                   generated secrets and settings (chmod 600)
├── install.sh             saved copy of this script (self-updating)
└── data/
    ├── openvpn/           OpenVPN server config and certificates
    ├── xray/              Xray config and geodata
    └── panel/             panel settings, SSL and network state
```

Services (all on the host network):

| Service | Image | Port |
|---|---|---|
| `web` | `ghcr.io/mate-panel/wg-mate-web` | `WEB_PORT` (3000) |
| `api` | `ghcr.io/mate-panel/wg-mate-api` | 52653, agent 9443 |
| `db` | `postgres:16-alpine` | 127.0.0.1:5433 |

Docker volumes `wg-mate_wg_data` and `wg-mate_pg_data` hold the WireGuard state and the database.

---

## Manual operations

```bash
cd /opt/wg-mate
docker compose ps
docker compose logs -f api
docker compose restart web
```

Backups — the database volume is the only thing you cannot regenerate:

```bash
cd /opt/wg-mate
docker compose exec -T db pg_dump -U wgmate wgmate | gzip > wgmate-$(date +%F).sql.gz
```

---

## Troubleshooting

**Panel does not open** — check that the port is reachable and the stack is up:

```bash
wg-mate status
```

**`wireguard kernel module not loaded`** — install the headers for your kernel and reboot:

```bash
sudo apt-get install -y linux-headers-$(uname -r) wireguard-tools
```

**Port already in use** — re-run the installer and give a different panel web port:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh)" -- install
```

**Lost admin password** — there is no CLI reset. The password is stored as a bcrypt hash and can only
be changed from inside the panel. If you are locked out entirely, the admin account has to be seeded
again, which means reinstalling.

**`wg-mate: command not found`** — the shortcut is created by `install` and `update`. A panel installed with an older installer has neither the shortcut nor self-update, so run the one-liner once and pick `2) Update panel`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh)"
```

From then on `wg-mate` works and the script keeps itself up to date.

---

## نصب سریع (فارسی)

نصب با یک دستور روی سرور اوبونتو یا دبیان:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mate-Panel/wg-mate-script/main/install.sh)"
```

اسکریپت داکر را در صورت نبودن خودش نصب می‌کند، سپس پورت پنل و نام کاربری و رمز مدیر را می‌پرسد و در پایان آدرس پنل و اطلاعات ورود را نشان می‌دهد. بعد از ورود به پنل، لایسنس را فعال کنید.

بعد از نصب، هر جای سرور کافی است `wg-mate` را تایپ کنید تا منوی مدیریت باز شود:

```bash
wg-mate
```

دستورها را مستقیم هم می‌شود زد: `wg-mate update` ، `wg-mate logs` ، `wg-mate status`.

اگر نصب نیمه‌کاره بماند (قطع اینترنت یا ریست سرور)، دفعه‌ی بعد که `install` را بزنید از همان مرحله‌ی ناتمام ادامه می‌دهد و جواب‌هایی که قبلاً داده‌اید دوباره پرسیده نمی‌شود.

نکته‌ها:

- اگر پنل را با نسخه‌ی قدیمی اسکریپت نصب کرده‌اید، یک‌بار همان دستور نصب یک‌خطی را اجرا کنید و گزینه‌ی `2) Update panel` را بزنید تا میانبر `wg-mate` و آپدیت خودکار فعال شود.
- اسکریپت هر بار که اجرا می‌شود خودش را از همین ریپو آپدیت می‌کند؛ اگر اینترنت نبود یا فایل خراب بود، بی‌سروصدا با همان نسخه‌ی فعلی ادامه می‌دهد.
- آپدیت فقط تگ ایمیج را عوض می‌کند؛ دیتابیس، کلیدهای WireGuard و تنظیمات پنل دست‌نخورده می‌مانند.
- نام کاربری و رمز مدیر در هیچ فایلی ذخیره نمی‌شود؛ فقط یک‌بار موقع نصب برای ساخت حساب استفاده می‌شود. رمز به‌صورت bcrypt ذخیره می‌شود و فقط از داخل خود پنل قابل تغییر است — اسکریپت دستور تغییر رمز ندارد.
- گزینه‌ی `purge` همه‌چیز را برای همیشه پاک می‌کند — دیتابیس، کانفیگ‌ها و پوشه‌ی `/opt/wg-mate`.
- قبل از هر تغییر مهم از دیتابیس بکاپ بگیرید (دستور `pg_dump` در بخش بالا).

---

## License

The installer is published for public use. The wg-mate panel itself requires a license activated from inside the panel after installation.
