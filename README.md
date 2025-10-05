# install-heartbeat.sh

A single Bash installer that creates an **UptimeRobot Heartbeat monitor** via API and installs a **per-minute cron job** to ping it from the host. Designed for quick rollout across Linux boxes.

- Creates a new **Heartbeat (type=5)** monitor using UptimeRobot **v2 API**
- Attaches an existing **email alert contact** and optional **UptimeRobot App (iOS/Android) contact**
- **Interval and grace are specified in seconds** (defaults: 60s interval, 300s grace)
- Installs cron for the **invoking user** (if run with `sudo`, it targets `SUDO_USER`, not root)
- Sends one initial ping **5 seconds** after creation to mark the host up
- Installs needed packages (`curl`, `jq`, `cron`) via `apt` on Debian/Ubuntu systems

---

## Prerequisites

- A working UptimeRobot account with:
  - **Main API key**
  - An **email alert contact** already created (e.g., `alerts@example.com`)
  - Optional: an **App** alert contact (created automatically when the mobile app is logged in)
- A Debian/Ubuntu-like system (script uses `apt` to install dependencies)
- Ability to run commands with `sudo` if dependencies/services need to be installed/started

> Note on units: For Heartbeat monitors, both **`interval`** and **`grace`** are interpreted as **seconds** by the API. Your account plan may enforce minimums (e.g., `interval >= 30`).

---

## Quick Start

```bash
# Make executable
chmod +x install-heartbeat.sh

# Recommended: keep API key out of shell history via a variable
API_KEY="YOUR_UPTIMEROBOT_MAIN_API_KEY"

# Create a heartbeat monitor, attach email contact, attach app contact by ID
sudo ./install-heartbeat.sh   --api-key "$API_KEY"   --name "web-01 heartbeat"   --email alerts@example.com   --app-id 1234567
```

What this does:

1. Looks up your alert contacts and verifies the ones you specify.
2. Creates a **new** heartbeat monitor with defaults `interval=60` and `grace=300` seconds.
3. Waits **5 seconds**, then hits the heartbeat URL once.
4. Installs a **per-minute** cron entry for the user who ran the script.

---

## Usage

```
./install-heartbeat.sh --api-key APIKEY --name "Friendly Name" --email EMAIL [options]
```

### Required flags

- `--api-key` — UptimeRobot Main API key
- `--name` — Friendly name for the new monitor
- `--email` — Email address of an existing alert contact to attach

### Optional flags

- `--app-id ID` — Attach an App (mobile push) alert contact by **ID** (fails if not found)
- `--app-name NAME` — Attach the first alert contact whose `friendly_name` contains **NAME** (case-insensitive; fails if not found)
- `--interval SECONDS` — Heartbeat interval in **seconds** (default: `60`)
- `--grace SECONDS` — Grace period in **seconds** (default: `300`)
- `--list-contacts` — Print available alert contacts (ID, type, friendly_name, value) and exit
- `-h`, `--help` — Show help and exit

### Examples

Attach email only:

```bash
./install-heartbeat.sh   --api-key "$API_KEY"   --name "db-01 heartbeat"   --email alerts@example.com
```

Attach email + app contact by ID:

```bash
./install-heartbeat.sh   --api-key "$API_KEY"   --name "api-01 heartbeat"   --email alerts@example.com   --app-id 1234567
```

Attach email + app contact by name (case-insensitive contains):

```bash
./install-heartbeat.sh   --api-key "$API_KEY"   --name "cache-01 heartbeat"   --email alerts@example.com   --app-name "UptimeRobot App (iPhone)"
```

Custom interval/grace (seconds):

```bash
./install-heartbeat.sh   --api-key "$API_KEY"   --name "worker-01 heartbeat"   --email alerts@example.com   --interval 120   --grace 600
```

List available alert contacts (no changes made):

```bash
./install-heartbeat.sh --api-key "$API_KEY" --list-contacts
```

---

## What gets installed

- **New Heartbeat monitor** in UptimeRobot (type=5) with your interval/grace
- **Cron entry** for the invoking user (uses absolute path to `curl`):

```
* * * * * /usr/bin/curl -fsS --retry 2 --max-time 10 "https://heartbeat.uptimerobot.com/SECRET" >/dev/null 2>&1 # UptimeRobot Heartbeat (MONITOR_ID)
```

> If you run the script with `sudo`, it targets `SUDO_USER` so the entry lands in that user’s crontab, not root’s.

---

## Verifying

Check the user crontab:

```bash
crontab -l | grep 'UptimeRobot Heartbeat' || echo "No user cron line found"
```

Confirm the service is running:

```bash
sudo systemctl status cron || sudo systemctl status crond
```

Manual heartbeat test:

```bash
curl -fsS "https://heartbeat.uptimerobot.com/SECRET" && echo "OK"
```

---

## Troubleshooting

**Cron line didn’t appear**

- You ran as `sudo` and expected it under root. This installer intentionally installs for the **invoking user** (uses `SUDO_USER` when present).
  - Check both:
    ```bash
    crontab -l
    sudo crontab -l
    ```
- Cron service is not active:
  ```bash
  sudo systemctl start cron || sudo systemctl start crond
  ```
- `curl` not in cron’s PATH: the script uses the absolute path discovered at install time (e.g., `/usr/bin/curl`).

**API rejects interval value**

- Some plans enforce minimums (e.g., `interval >= 30`). Use a compliant value, e.g., `--interval 60`.

**App contact not found**

- Ensure the UptimeRobot mobile app is logged in to the same account.
- Use `--list-contacts` to confirm the App contact’s ID or friendly name.

**“unable to resolve host <hostname>” on sudo**

- Add your hostname to `/etc/hosts`, for example:
  ```bash
  echo "127.0.1.1 $(hostname)" | sudo tee -a /etc/hosts
  ```

---

## Uninstall

Remove the cron line:

```bash
crontab -l | grep -v 'UptimeRobot Heartbeat' | crontab -
```

Delete or disable the monitor in UptimeRobot (via UI or API) if desired.

---

## Security Notes

- Passing the API key on the command line can land in shell history or process listings. Prefer a shell variable:
  ```bash
  API_KEY="..." ./install-heartbeat.sh --api-key "$API_KEY" ...
  ```
- The script does not store keys or secrets on disk.

---

## Compatibility

- Tested on Debian/Ubuntu-like systems (uses `apt` for `curl`, `jq`, `cron`)
- On non-Debian systems, you may need to ensure those packages and the cron service are installed and active

---

## Contributing

- Open issues or pull requests for improvements or bug fixes
- Please keep the script POSIX-friendly where practical and avoid adding features not covered in this README without discussion

---

## License

Specify your project’s license (e.g., MIT) in a `LICENSE` file.
