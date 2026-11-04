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

The installer asks three questions (panel web port, admin username, admin password; press Enter on the password for a random one), shows a summary, and installs after you confirm. Every Docker image download shows its size, speed and time left. When it is done it prints the panel URL and credentials. Open the panel, log in, and activate your license.

## The `wg-mate` command

After the first install, a shortcut is placed at `/usr/local/bin/wg-mate`. Type it from anywhere to open the manager:

```bash
wg-mate
```

```
  wg-mate  v0.3.1
  ──────────────────────────────────────────
  Panel     ● running  v0.2.4  ↑ v0.2.5
  URL       http://203.0.113.10:3000

  1) Update panel
  2) Restart
  3) Stop
  4) Logs
  5) Login info
  6) Backup / Restore
  7) Uninstall
  0) Exit

  ❯
```

The menu only lists what makes sense right now: before the panel is installed it offers just `Install`, and when the panel is stopped `Start` replaces `Restart` and `Stop`. After an action finishes, its result stays on screen; press Enter and the screen clears and the menu comes back. After an update you see the new version, channel, service status and panel URL.

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
sudo bash install.sh update       # pull newer images and recreate the stack
sudo bash install.sh start
sudo bash install.sh stop         # stop containers, keep data
sudo bash install.sh restart
sudo bash install.sh logs         # follow logs
sudo bash install.sh login        # panel URL and admin accounts
sudo bash install.sh status       # services, ports and server details
sudo bash install.sh backup       # database + config archive
sudo bash install.sh restore      # restore from a backup archive
sudo bash install.sh doctor       # diagnose a broken install
sudo bash install.sh selfupdate   # download the newest script
sudo bash install.sh uninstall    # remove everything, permanently
sudo bash install.sh version      # print the installer version
```

`upgrade` works as an alias of `update`, and `purge` / `remove` as aliases of `uninstall`.

The install always uses the stable channel. To install beta or an exact version, pass `--channel beta` or `--version v0.2.4`. Updates default to stable too, even if the panel was on beta or a pinned version: in the menu `Update panel` asks for the channel with `stable` as the default, and `wg-mate update` without flags always moves to stable.

Every command also takes flags, so a whole install can run unattended:

```bash
sudo bash install.sh install --channel stable --admin admin --password secret123 --web-port 3000
sudo bash install.sh update --version v0.2.4
sudo bash install.sh logs --service api
sudo bash install.sh restore --file /opt/wg-mate/backups/wg-mate-20260101-120000.tar.gz
sudo bash install.sh --help
```

An interrupted install is resumable: every finished phase (Docker, configuration, images, start) is recorded, and the next `install` run offers to continue from the last completed step without asking again for the answers you already gave.

`update` first asks the registry whether each image (api, web, postgres) has a new version and downloads only the ones that changed. The nginx helpers are reinstalled only when the script ships a new version of them, and the containers are recreated only when an image or the config actually changed; otherwise the panel keeps running untouched. The database, WireGuard keys, certificates and panel settings are never touched.

`uninstall` is destructive: it deletes the containers, the Docker volumes (including the database), `/opt/wg-mate`, the host helper systemd units and the nginx vhosts created by the panel. It asks for confirmation first, and the default answer is no.

The log of the last install, update or backup is kept at `/run/wg-mate/wg-mate.log`; when a step fails, its last lines are printed right away.

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

**`wg-mate: command not found`** — the shortcut is created by `install` and `update`. A panel installed with an older installer has neither the shortcut nor self-update, so run the one-liner once and pick `Update panel`:

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

اسکریپت فقط سه سؤال می‌پرسد: پورت پنل، نام کاربری و رمز مدیر (اگر برای رمز Enter بزنید، یک رمز تصادفی ساخته می‌شود). بعد داکر را در صورت نبودن خودش نصب می‌کند و دانلود هر ایمیج را با حجم، سرعت و زمان باقی‌مانده نشان می‌دهد. در پایان آدرس پنل و اطلاعات ورود نمایش داده می‌شود. بعد از ورود به پنل، لایسنس را فعال کنید.

بعد از نصب، هر جای سرور کافی است `wg-mate` را تایپ کنید تا منوی مدیریت باز شود:

```bash
wg-mate
```

دستورها را مستقیم هم می‌شود زد: `wg-mate update` ، `wg-mate logs` ، `wg-mate status`.

اگر نصب نیمه‌کاره بماند (قطع اینترنت یا ریست سرور)، دفعه‌ی بعد که `install` را بزنید از همان مرحله‌ی ناتمام ادامه می‌دهد و جواب‌هایی که قبلاً داده‌اید دوباره پرسیده نمی‌شود.

نکته‌ها:

- اگر پنل را با نسخه‌ی قدیمی اسکریپت نصب کرده‌اید، یک‌بار همان دستور نصب یک‌خطی را اجرا کنید و گزینه‌ی `Update panel` را بزنید تا میانبر `wg-mate` و آپدیت خودکار فعال شود.
- اسکریپت هر بار که اجرا می‌شود خودش را از همین ریپو آپدیت می‌کند؛ اگر اینترنت نبود یا فایل خراب بود، بی‌سروصدا با همان نسخه‌ی فعلی ادامه می‌دهد.
- آپدیت فقط تگ ایمیج را عوض می‌کند؛ دیتابیس، کلیدهای WireGuard و تنظیمات پنل دست‌نخورده می‌مانند.
- نام کاربری و رمز مدیر در هیچ فایلی ذخیره نمی‌شود؛ فقط یک‌بار موقع نصب برای ساخت حساب استفاده می‌شود. رمز به‌صورت bcrypt ذخیره می‌شود و فقط از داخل خود پنل قابل تغییر است — اسکریپت دستور تغییر رمز ندارد.
- گزینه‌ی `Uninstall` (دستور `wg-mate uninstall`) همه‌چیز را برای همیشه پاک می‌کند — دیتابیس، کانفیگ‌ها و پوشه‌ی `/opt/wg-mate`.
- قبل از هر تغییر مهم از دیتابیس بکاپ بگیرید (دستور `pg_dump` در بخش بالا).

---

## License

The installer is published for public use. The wg-mate panel itself requires a license activated from inside the panel after installation.
