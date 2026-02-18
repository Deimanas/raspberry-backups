# Raspberry Docker Backup System (Production-Ready)

Stabilus backup sprendimas Debian / Raspberry Pi OS serveriui, skirtas 10+ WordPress projektų (multi-site) aplinkai.

## 1) Katalogų struktūra

```text
/workspace/raspberry-backups/
├── .env.example
├── VERSION
├── RELEASE_NOTES.md
├── README.md
├── backups/
│   ├── YYYY-MM-DD_HH-MM/
│   │   ├── containers/
│   │   │   └── <container_name>/
│   │   │       └── volume-<volume_name>.tar.gz|tar.zst
│   │   ├── databases/
│   │   │   ├── <container_name>-mysql.sql
│   │   │   └── <container_name>-postgres.dump
│   │   └── metadata.env
│   ├── latest -> /backups/YYYY-MM-DD_HH-MM
│   └── weekly/
├── config/
│   └── cron.backup
├── logs/
│   ├── backup-YYYY-MM-DD_HH-MM.log
│   └── cron.log
└── scripts/
    ├── backup.sh
    └── restore.sh
```

## 2) Įdiegimas

1. **Pasirinktinai** susikurkite konfigūraciją iš pavyzdžio (nebūtina):
   ```bash
   cp .env.example .env
   ```
2. Jei `.env` nenaudojate, visus parametrus galite paduoti kaip shell ENV (pvz. per cron eilutę).
3. Suteikite vykdymo teises (jei reikia):
   ```bash
   chmod +x scripts/backup.sh scripts/restore.sh
   ```
4. Įdiekite cron:
   ```bash
   sudo cp config/cron.backup /etc/cron.d/docker-backup
   sudo chmod 644 /etc/cron.d/docker-backup
   sudo systemctl restart cron
   ```

## 3) Kas daroma per backup

- Aptinkami Docker containeriai pagal `CONTAINER_SCOPE`:
  - `all` (numatyta): visi konteineriai (`docker ps -a`)
  - `running`: tik aktyvūs konteineriai (`docker ps`)
- Kiekvienam containeriui daromas atskiras mount backup (Docker volume + bind mount).
- DB containeriams automatiškai aptinkamas tipas:
  - MariaDB/MySQL -> `mysqldump` per `docker exec` (jei nėra, naudojamas external DB client image)
  - Postgres -> `pg_dump` (jei nėra, naudojamas external DB client image)
- Jei `STOP_CONTAINERS=true`, prieš volume backup konteineris sustabdomas ir po to paleidžiamas.
- Atliktas laisvos vietos patikrinimas (`MIN_FREE_MB`).
- Veikia rotacija:
  - daily: laikoma `RETENTION_DAILY_DAYS`
  - weekly: laikoma `RETENTION_WEEKLY_WEEKS`
- Yra `--dry-run` režimas.
- Log'ai su success/error/duration.
- Optional Discord webhook notifikacijos.

## 4) Paleidimas rankiniu būdu

> `.env` failas **nėra privalomas**. Jei jo nėra, script tyliai naudoja numatytas reikšmes (be papildomo WARN) ir `BACKUP_BASE_DIR=./backups`.


```bash
# Pilnas backup su default reikšmėmis (be .env, rašoma į ./backups)
scripts/backup.sh

# Pilnas backup su laikinais ENV parametrais
BACKUP_BASE_DIR=/srv/backups MIN_FREE_MB=4096 scripts/backup.sh

# Testinis režimas (nieko nerašo)
scripts/backup.sh --dry-run

# Priverstinis weekly snapshot
scripts/backup.sh --force-weekly
```

## 5) Testavimo scenarijus

1. **Sintaksės testas**
   ```bash
   bash -n scripts/backup.sh
   bash -n scripts/restore.sh
   ```
2. **Dry-run testas (be .env)**
   ```bash
   scripts/backup.sh --dry-run
   ```
3. **Tikras backup testas**
   ```bash
   scripts/backup.sh
   ```
4. **Patikrinkite rezultatą**
   ```bash
   ls -lah backups/
   ls -lah logs/
   ```
5. **Restore testas atskiroje test aplinkoje**
   ```bash
   scripts/restore.sh <timestamp> <container_name>
   ```

## 6) Restore pavyzdys: WordPress + MariaDB

Tarkime:
- WordPress containeris: `wp_project1`
- MariaDB containeris: `mariadb_project1`
- Backup timestamp: `2026-01-05_12-00`

### 6.1 Atkurkite MariaDB duomenis

```bash
scripts/restore.sh 2026-01-05_12-00 mariadb_project1 --db-only
```

### 6.2 Atkurkite WordPress failus (volume)

```bash
scripts/restore.sh 2026-01-05_12-00 wp_project1 --volume-only
```

### 6.3 Pilnas MariaDB atstatymas (volume + db)

```bash
scripts/restore.sh 2026-01-05_12-00 mariadb_project1
```

## 7) Stabilumo rekomendacijos production aplinkai

- Naudokite atskirą diską backupams (`BACKUP_BASE_DIR=/backups`).
- `MIN_FREE_MB` nustatykite pagal realų augimą (pvz. 10-20 GB).
- `EXCLUDE_CONTAINERS` naudokite trumpalaikiams/ephemeral containeriams.
- Bent kartą per savaitę atlikite pilną restore testą į staging.
- Jei infrastruktūra didelė (10+ WP), rekomenduojama centralizuoti log surinkimą ir webhook alertus.
