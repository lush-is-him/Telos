# Home server setup (Ubuntu)

The phone works fine on its own. This adds a backup copy, weekly dumps, and the forecast model.

What you get:

- **Postgres + API in Docker.** Both restart automatically whenever the PC boots.
- **Sync.** The phone pushes changes on open, on close, and a few seconds after edits. If the PC is off, changes queue on the phone and go through next time. Nothing is lost.
- **Weekly `pg_dump`** on Sunday 03:00. It uses `Persistent=true`, so if the PC was off at that time, the backup runs soon after the next boot. The last 8 weeks are kept, with an optional second copy.
- **Weekly retrain** on Sunday 04:00, same catch-up rule. It refreshes the model and `data/reports/REPORT.md`.

## 1. Tailscale (phone ↔ PC without opening ports)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # note the 100.x.y.z address
```

Install Tailscale on the phone and sign in to the same account.

## 2. Docker

```bash
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER   # log out and back in
```

## 3. Telos

```bash
sudo git clone https://github.com/lush-is-him/Telos.git /opt/telos
sudo chown -R $USER /opt/telos
cd /opt/telos/deploy
cp .env.example .env
openssl rand -hex 32            # paste as TELOS_TOKEN
nano .env                       # set POSTGRES_PASSWORD, TELOS_TOKEN, TELOS_TZ, TAILSCALE_IP
./install.sh
```

`install.sh` builds and starts the containers, then enables both timers. Check them with:

```bash
systemctl list-timers 'telos-*'
curl -H "Authorization: Bearer $TELOS_TOKEN" http://127.0.0.1:8000/health
```

## 4. Phone

Go to Progress → ⚙ Settings. Enter `http://<tailscale-ip>:8000` and the token, then tap **Save & sync**.

## Backups

| Task | Command |
|---|---|
| Run one now | `sudo systemctl start telos-backup.service` |
| See the log | `journalctl -u telos-backup.service -n 50` |
| Restore | `./restore.sh /var/backups/telos/telos-YYYY-MM-DD.sql.gz` |
| New phone | Install the app, enter the server and token, then tap **Restore from server** |

Set `BACKUP_MIRROR` to a second disk or a mounted external drive. A single disk is not a backup. If the mirror isn't mounted, the script warns and keeps the local copy.

## Security notes

- The API listens only on localhost and the Tailscale interface, never the LAN or the internet.
- Every request needs the bearer token. The server refuses to start without one.
- `.env` holds secrets and is git-ignored.
