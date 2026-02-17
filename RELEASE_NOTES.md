# Release v1.0.3

- Pašalintas nereikalingas įspėjimas apie nerastą `.env` failą (kai `.env` nenaudojamas).
- `backup.sh` išplėstas: dabar backupina ne tik Docker volume, bet ir bind mount katalogus.
- Pridėtas DB dump fallback: jei konteineryje nėra `mysqldump`/`pg_dump`, naudojami external DB client image (`mariadb:11`, `postgres:16`).
- Atnaujinta dokumentacija ir `.env.example` su fallback image parametrais.
