# Backups

Three layers protect production data:

| Layer | What | Kept | Protects against |
|---|---|---|---|
| Supabase Pro daily backups | Database | 7 days | Bad updates, deleted records (one-click restore in Supabase) |
| Nightly job → Cloudflare R2 (`.github/workflows/backup.yml`) | Database **and** uploaded files, encrypted | Database 30 days; files kept | Supabase account lost / locked / hacked; files deleted from Storage |
| Monthly test restore | Proves the backups work | — | Finding out on the worst day that a backup can't be restored |

Supabase's own backups do **not** include uploaded files (PODs, W-9s, agreements, photos). The nightly job does.

Everything in R2 is encrypted with `BACKUP_PASSPHRASE`. **If that password is lost, the R2 backups cannot be opened by anyone, including you.** Keep it in your password manager *and* on paper somewhere safe.

---

## One-time setup (about 20 minutes)

### 1. Supabase Pro
Supabase → **Project Settings → Billing** → upgrade to **Pro**. Then **Database → Backups** should list daily backups.

### 2. Cloudflare R2
1. Create a free Cloudflare account → **R2 Object Storage** (it asks for a card; the first 10 GB are free).
2. **Create bucket** → name `tdp-backups` → Create.
3. In the bucket → **Settings → Object lifecycle rules → Add rule**: name `delete old database copies`, prefix `db/`, **delete objects after 30 days**. (No rule for `files/`.)
4. R2 overview → **Manage API tokens → Create API token**: permission **Object Read & Write**, apply to **tdp-backups only** → Create. Copy the **Access Key ID** and **Secret Access Key** (shown once).
5. Copy the **Account ID** from the R2 overview page.

### 3. Values from Supabase
* **Database connection string**: Supabase → **Connect** (top of the dashboard) → **Session pooler** → copy the URI and put your database password in place of `[YOUR-PASSWORD]`. (GitHub can't reach the "Direct connection" address.) Forgot the password? **Project Settings → Database → Reset database password** -- the app itself does not use it.
* **Project URL**: `https://zteixenjpcygjvznueuo.supabase.co`
* **Service role / secret key**: **Project Settings → API Keys** → the `service_role` key (or a `sb_secret_...` key).

### 4. GitHub secrets
GitHub → the repository → **Settings → Secrets and variables → Actions → New repository secret**, seven times:

| Name | Value |
|---|---|
| `SUPABASE_DB_URL` | Session pooler URI with the password filled in |
| `SUPABASE_URL` | `https://zteixenjpcygjvznueuo.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role / secret key |
| `R2_ACCOUNT_ID` | Cloudflare Account ID |
| `R2_ACCESS_KEY_ID` | R2 token Access Key ID |
| `R2_SECRET_ACCESS_KEY` | R2 token Secret Access Key |
| `BACKUP_PASSPHRASE` | A long password you make up (16+ characters). Save it in your password manager **and** on paper. |

### 5. First run
GitHub → **Actions → Nightly backup → Run workflow**. After a few minutes it should be green, and R2 should show `db/<date>/db.tar.gz.gpg` and a `files/` folder. From then on it runs every night at about 3 AM Chicago time. If a run fails, GitHub emails you.

---

## Restore

You need: the backup password, the `psql` and `gpg` tools (Mac: `brew install libpq gnupg`, then `brew link --force libpq`), and Python 3.

### Database
1. Cloudflare → R2 → `tdp-backups` → `db/` → newest date → download `db.tar.gz.gpg`.
2. Decrypt and unpack:
   ```
   gpg --decrypt -o db.tar.gz db.tar.gz.gpg     # asks for the backup password
   tar xzf db.tar.gz                             # gives db/roles.sql, db/schema.sql, db/data.sql
   ```
3. Restore into a **new, empty** Supabase project (never over the live one unless that is the decision), using that project's Session pooler URI:
   ```
   psql --single-transaction --variable ON_ERROR_STOP=1 \
     --file db/roles.sql --file db/schema.sql \
     --command 'SET session_replication_role = replica' \
     --file db/data.sql \
     --dbname "<NEW PROJECT SESSION POOLER URI>"
   ```

### Uploaded files
1. Download the whole `files/` folder from R2 (Cloudflare dashboard, or `aws s3 cp --recursive s3://tdp-backups/files ./files --endpoint-url https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).
2. Put them into the restored project:
   ```
   export SUPABASE_URL=https://<new-project>.supabase.co
   export SUPABASE_SERVICE_ROLE_KEY=<new project's service_role key>
   export BACKUP_PASSPHRASE='<backup password>'
   python3 scripts/backup/restore_files.py ./files
   ```

### Switch the app over (only for a real disaster)
Vercel → **Settings → Environment Variables**: set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to the new project's values → Redeploy. Then redo Supabase **Authentication → URL Configuration** and the Google sign-in provider in the new project.

---

## Monthly test restore (15 minutes, first Monday of the month)
1. Create a free Supabase project called `tdp-restore-test`.
2. Restore last night's database into it (steps above).
3. In its **Table Editor**, check that `loads`, `carriers` and `invoices` have about the same number of rows as production.
4. Restore a handful of files and open one POD to see it is readable.
5. Delete the `tdp-restore-test` project.

If any step fails, the backups are not working -- fix that before anything else.
