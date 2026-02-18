#!/usr/bin/env python3
import os
import subprocess
import time
from datetime import timedelta
from datetime import datetime

import discord
from discord import app_commands

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
GUILD_ID = os.environ.get("DISCORD_GUILD_ID", "").strip()  # optional
ALLOWED_CHANNEL_ID = os.environ.get("DISCORD_STATS_CHANNEL_ID", "").strip()  # optional
ALLOW_DMS = os.environ.get("DISCORD_STATS_ALLOW_DMS", "1").strip() == "1"

X1200_CMD = os.environ.get("X1200_BATTERY_CMD", "/usr/local/bin/x1200-battery").strip()
BACKUP_BASE_DIR = os.environ.get("BACKUP_BASE_DIR", "/backups").strip()
BACKUP_FALLBACK_DIR = os.environ.get(
    "BACKUP_FALLBACK_DIR", os.path.expanduser("~/raspberry-backups/backups")
).strip()


def sh(cmd: list[str], timeout: int = 3) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, timeout=timeout)
        return out.decode("utf-8", errors="replace").strip()
    except Exception as e:
        return f"ERR: {e}"


def read_float(path: str) -> float | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return float(f.read().strip())
    except Exception:
        return None


def cpu_temp_c() -> str:
    t = read_float("/sys/class/thermal/thermal_zone0/temp")
    if t is None:
        return "n/a"
    return f"{t/1000:.1f}°C"


def uptime_str() -> str:
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            secs = float(f.read().split()[0])
        return str(timedelta(seconds=int(secs)))
    except Exception:
        return "n/a"


def loadavg_str() -> str:
    try:
        with open("/proc/loadavg", "r", encoding="utf-8") as f:
            a = f.read().split()
        return f"{a[0]} {a[1]} {a[2]}"
    except Exception:
        return "n/a"


def mem_str() -> tuple[str, str, str]:
    mem_total = None
    mem_available = None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1])  # kB
                elif line.startswith("MemAvailable:"):
                    mem_available = int(line.split()[1])  # kB
        if mem_total is None or mem_available is None:
            return ("n/a", "n/a", "n/a")
        used_kb = mem_total - mem_available
        used_pct = (used_kb / mem_total) * 100 if mem_total else 0
        return (f"{used_kb/1024:.0f} MiB", f"{mem_total/1024:.0f} MiB", f"{used_pct:.0f}%")
    except Exception:
        return ("n/a", "n/a", "n/a")


def disk_root_str() -> tuple[str, str]:
    out = sh(["df", "-h", "/"], timeout=3)
    lines = out.splitlines()
    if len(lines) < 2:
        return ("n/a", "n/a")
    parts = lines[1].split()
    if len(parts) < 5:
        return ("n/a", "n/a")
    size, used, avail, usep = parts[1], parts[2], parts[3], parts[4]
    return (f"{used}/{size} ({usep})", avail)


def cpu_usage_str() -> str:
    def read_stat():
        with open("/proc/stat", "r", encoding="utf-8") as f:
            cpu = f.readline().split()
        vals = list(map(int, cpu[1:]))
        total = sum(vals)
        idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
        return total, idle

    try:
        t1, i1 = read_stat()
        time.sleep(0.25)
        t2, i2 = read_stat()
        dt = t2 - t1
        di = i2 - i1
        if dt <= 0:
            return "n/a"
        usage = (1.0 - (di / dt)) * 100.0
        return f"{usage:.0f}%"
    except Exception:
        return "n/a"


def net_str() -> str:
    ip = sh(["bash", "-lc", "hostname -I | awk '{print $1}'"], timeout=2)
    gw = sh(["bash", "-lc", "ip route | awk '/default/ {print $3; exit}'"], timeout=2)
    if ip.startswith("ERR"):
        ip = "n/a"
    if gw.startswith("ERR"):
        gw = "n/a"
    return f"IP {ip}, GW {gw}"


def ups_line() -> str:
    out = sh([X1200_CMD], timeout=3)
    return out if out else "n/a"


def parse_backup_ts(name: str) -> datetime | None:
    try:
        return datetime.strptime(name, "%Y-%m-%d_%H-%M")
    except ValueError:
        return None


def list_backups() -> list[tuple[datetime, str, str]]:
    backups: list[tuple[datetime, str, str]] = []
    seen_dirs: set[str] = set()

    for base_dir in (BACKUP_BASE_DIR, BACKUP_FALLBACK_DIR):
        if not base_dir:
            continue
        base_dir = os.path.abspath(base_dir)
        if base_dir in seen_dirs:
            continue
        seen_dirs.add(base_dir)

        if not os.path.isdir(base_dir):
            continue

        try:
            with os.scandir(base_dir) as entries:
                for entry in entries:
                    if not entry.is_dir():
                        continue
                    ts = parse_backup_ts(entry.name)
                    if ts is None:
                        continue
                    backups.append((ts, entry.name, base_dir))
        except Exception:
            continue

    backups.sort(key=lambda item: item[0], reverse=True)
    return backups


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if size < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{int(num_bytes)} B"


def dir_size_bytes(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            file_path = os.path.join(root, name)
            try:
                if os.path.islink(file_path):
                    continue
                total += os.path.getsize(file_path)
            except OSError:
                continue
    return total


def backups_index_text() -> str:
    backups = list_backups()
    if not backups:
        return (
            "```\n"
            "Backup sąrašas tuščias.\n"
            f"Tikrinti katalogai: {BACKUP_BASE_DIR}, {BACKUP_FALLBACK_DIR}\n"
            "```"
        )

    lines = ["Backup sąrašas (naujausi viršuje):"]
    hidden = 0
    max_len = 1800
    current_len = sum(len(line) + 1 for line in lines)

    for idx, (ts, _folder, _base_dir) in enumerate(backups, start=1):
        line = f"{idx:>3}. {ts.strftime('%Y-%m-%d %H:%M')}"
        line_len = len(line) + 1
        if current_len + line_len > max_len:
            hidden += 1
            continue
        lines.append(line)
        current_len += line_len

    if hidden:
        lines.append(f"... ir dar {hidden} backup įrašų")

    return "```\n" + "\n".join(lines) + "\n```"


def backup_files_text(index: int) -> str:
    backups = list_backups()
    if not backups:
        return "```\nBackup sąrašas tuščias.\n```"
    if index < 1 or index > len(backups):
        return f"```\nNeteisingas numeris: {index}. Galimi: 1..{len(backups)}\n```"

    ts, folder, base_dir = backups[index - 1]
    backup_path = os.path.join(base_dir, folder)
    if not os.path.isdir(backup_path):
        return f"```\nBackup #{index} nerastas diske.\n```"

    files: list[tuple[str, int]] = []
    for root, _dirs, names in os.walk(backup_path):
        for name in names:
            full_path = os.path.join(root, name)
            rel_path = os.path.relpath(full_path, backup_path)
            try:
                size_bytes = os.path.getsize(full_path)
            except OSError:
                size_bytes = 0
            files.append((rel_path, size_bytes))

    files.sort(key=lambda item: item[0])
    if not files:
        return f"```\nBackup #{index} ({ts.strftime('%Y-%m-%d %H:%M')}) neturi failų.\n```"

    lines = [f"Backup #{index} failai ({ts.strftime('%Y-%m-%d %H:%M')}):"]
    hidden = 0
    max_len = 1800
    current_len = sum(len(line) + 1 for line in lines)

    for rel_path, size_bytes in files:
        line = f"{rel_path} ({human_size(size_bytes)})"
        line_len = len(line) + 1
        if current_len + line_len > max_len:
            hidden += 1
            continue
        lines.append(line)
        current_len += line_len

    if hidden:
        lines.append(f"... ir dar {hidden} failų")

    return "```\n" + "\n".join(lines) + "\n```"


def backups_summary_text() -> str:
    backups = list_backups()
    count = len(backups)
    total_bytes = 0
    for _ts, folder, base_dir in backups:
        path = os.path.join(base_dir, folder)
        if os.path.isdir(path):
            total_bytes += dir_size_bytes(path)
    lines = [
        f"Backup kopijų skaičius: {count}",
        f"Bendras backup dydis: {human_size(total_bytes)}",
        "",
        "Naujausi backup:",
    ]
    if not backups:
        lines.append("nėra")
    else:
        hidden = 0
        max_len = 1800
        current_len = sum(len(line) + 1 for line in lines)
        for idx, (ts, _folder, _base_dir) in enumerate(backups, start=1):
            line = f"{idx:>3}. {ts.strftime('%Y-%m-%d %H:%M')}"
            line_len = len(line) + 1
            if current_len + line_len > max_len:
                hidden += 1
                continue
            lines.append(line)
            current_len += line_len
        if hidden:
            lines.append(f"... ir dar {hidden} backup įrašų")

    return "```\n" + "\n".join(lines) + "\n```"


def docker_name_by_pid(pid: str) -> str | None:
    try:
        with open(f"/proc/{pid}/cgroup", "r", encoding="utf-8") as f:
            cgroups = f.read().splitlines()
    except Exception:
        return None

    container_id = None
    for line in cgroups:
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        path = parts[2]
        for marker in ("docker/", "docker-"):
            idx = path.find(marker)
            if idx == -1:
                continue
            tail = path[idx + len(marker) :]
            cid = tail.split("/", 1)[0].split(".", 1)[0]
            if len(cid) >= 12:
                container_id = cid
                break
        if container_id:
            break

    if not container_id:
        return None

    name = sh(["docker", "inspect", "--format", "{{.Name}}", container_id], timeout=2)
    if name.startswith("ERR") or not name:
        return None

    return name.lstrip("/")


def top5_processes(sort: str = "cpu") -> str:
    """
    Return top 5 by CPU or RAM, include both CPU% and MEM%.
    Format: PID CPU% MEM% CMD
    """
    order = "-pcpu" if sort == "cpu" else "-pmem"
    out = sh(
        ["bash", "-lc", f"ps -eo pid,pcpu,pmem,comm --sort={order} | head -n 6"],
        timeout=3,
    )
    lines = out.splitlines()
    if len(lines) < 2:
        return "n/a"

    # Drop header, compact formatting
    rows = []
    for ln in lines[1:]:
        parts = ln.split(None, 3)
        if len(parts) < 4:
            continue
        pid, pcpu, pmem, comm = parts
        suffix = ""
        if comm == "apache2":
            docker_name = docker_name_by_pid(pid)
            if docker_name:
                suffix = f" (docker: {docker_name})"
        rows.append(f"{pid:>5}  {pcpu:>5}%  {pmem:>5}%  {comm}{suffix}")

    return "\n".join(rows) if rows else "n/a"


def stats_text() -> str:
    ups = ups_line()
    cpu = cpu_usage_str()
    temp = cpu_temp_c()
    used, total, used_pct = mem_str()
    disk_used, disk_avail = disk_root_str()
    up = uptime_str()
    load = loadavg_str()
    net = net_str()
    top_cpu = top5_processes("cpu")
    top_ram = top5_processes("ram")

    return (
        "```\n"
        f"UPS:   {ups}\n"
        f"CPU:   {cpu} | Temp {temp} | Load {load}\n"
        f"RAM:   {used} / {total} ({used_pct})\n"
        f"Disk:  {disk_used} | Avail {disk_avail}\n"
        f"Uptime:{up}\n"
        f"Net:   {net}\n"
        "\n"
        "Top 5 (CPU):\n"
        " PID   CPU%  MEM%  CMD\n"
        f"{top_cpu}\n"
        "\n"
        "Top 5 (RAM):\n"
        " PID   CPU%  MEM%  CMD\n"
        f"{top_ram}\n"
        "```"
    )


def allowed_where(interaction: discord.Interaction) -> bool:
    if interaction.guild is None:
        return ALLOW_DMS
    if ALLOWED_CHANNEL_ID:
        try:
            return str(interaction.channel_id) == str(ALLOWED_CHANNEL_ID)
        except Exception:
            return False
    return True


intents = discord.Intents.default()
# Jei nori tik /stats (slash) DM'e, šito nereikia. Palieku įjungtą, jei naudoji tekstinį "stats".
intents.message_content = True


class Bot(discord.Client):
    def __init__(self):
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)

    async def setup_hook(self):
        if GUILD_ID:
            guild = discord.Object(id=int(GUILD_ID))
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
        else:
            await self.tree.sync()


bot = Bot()


@bot.tree.command(name="stats", description="Rodyti UPS bateriją ir sistemos resursus")
async def slash_stats(interaction: discord.Interaction):
    if not allowed_where(interaction):
        await interaction.response.send_message("Šitam kanale neleista.", ephemeral=True)
        return
    await interaction.response.send_message(stats_text())


@bot.tree.command(name="list", description="Rodyti backup sąrašą arba failus pagal numerį")
@app_commands.describe(numeris="Backup numeris iš /list sąrašo")
async def slash_list(interaction: discord.Interaction, numeris: int | None = None):
    if not allowed_where(interaction):
        await interaction.response.send_message("Šitam kanale neleista.", ephemeral=True)
        return
    if numeris is None:
        await interaction.response.send_message(backups_index_text())
    else:
        await interaction.response.send_message(backup_files_text(numeris))


@bot.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return
    text = message.content.strip().lower()
    if text in ("stats", "list"):
        if message.guild is None:
            if not ALLOW_DMS:
                return
        else:
            if ALLOWED_CHANNEL_ID and str(message.channel.id) != str(ALLOWED_CHANNEL_ID):
                return
        if text == "stats":
            await message.channel.send(stats_text())
        else:
            await message.channel.send(backups_summary_text())


def main():
    if not TOKEN:
        raise SystemExit("DISCORD_BOT_TOKEN not set")
    bot.run(TOKEN)


if __name__ == "__main__":
    main()
