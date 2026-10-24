# Publishing Your Lab to GitHub: The Beginner's Guide

**Put the hybrid cloud lab on GitHub so people can read it, without leaking a single secret or real address.**

Version 1.0 · Written for the `hybrid-cloud-lab` repository that comes with the Beginner's Build Guide.

---

## Read this first

### Who this is for

You have never published a project on GitHub, or you have but never thought hard about what you might leak. You can open a terminal and copy a command. That is enough.

### What you will have at the end

A public GitHub repository that shows your lab, with:

- Your real IPs, project ID, hostnames and email kept **out**
- Two automatic guards that **refuse a commit** if a secret or real value sneaks in
- GitHub's own scanning turned on as a third guard
- A clean front page that explains what you built
- A safe routine for making changes later

### How this guide works

Each step has the same layout: **what you are doing**, **why**, **do this**, **you should see**, and, where useful, **if it goes wrong**. Do the steps in order. Several of them depend on the one before.

### The three golden rules

1. **Once something is pushed to a public repository, assume it is copied forever.** Bots scan new public commits within minutes. Deleting a file later does not remove it from history or from copies.
2. **If a secret ever leaks, change the secret first, clean up second.** Cleaning history does not un-leak it. Rotating it makes the leaked copy useless. Step 17 covers this.
3. **Publish privately first, look at it with your own eyes, then make it public.** It costs five minutes and catches what tools miss.

### Placeholders used in this guide

| You see | Replace with |
|---|---|
| `your-username` | Your GitHub username |
| `Your Name` | The name you want on your commits |
| `hybrid-cloud-lab` | Your repository name, if you choose a different one |

---

# PART 1: WORDS YOU NEED

| Word | Plain meaning | Everyday comparison |
|---|---|---|
| **Git** | A program on your computer that records every version of your files | A save history you can always go back through |
| **GitHub** | A website that stores Git projects online and lets others see them | A public library for those save histories |
| **Repository (repo)** | One project folder tracked by Git | One book in the library |
| **Commit** | A saved snapshot of your changes, with a message | A dated page in the book's diary |
| **Stage (`git add`)** | Choosing which changes go into the next commit | Putting items in the box before you seal it |
| **Push** | Sending your commits from your computer to GitHub | Mailing the sealed box to the library |
| **Remote** | The GitHub copy of your repository | The library's copy of the book |
| **Branch** | A separate line of work you can merge later | A draft copy you edit before replacing the original |
| **Pull request (PR)** | A request to merge a branch, with a review page | Handing the draft to an editor before it goes in the book |
| **`.gitignore`** | A list of files Git must never track | A "do not pack" list on the box |
| **Hook** | A script Git runs automatically, for example before each commit | A guard who checks every box before it is sealed |
| **pre-commit** | A tool that manages those hooks | The guard's employer |
| **gitleaks** | A scanner that recognises passwords, keys and tokens | A guard trained to spot keys |
| **Secret** | Anything that grants access: passwords, keys, tokens, PSKs | A house key |
| **CI (GitHub Actions)** | Scripts GitHub runs for you on every change | An inspector at the library who checks every new page |
| **SHA** | A unique fingerprint of a commit, 40 characters long | A serial number that cannot be faked |

---

# PART 2: WHAT IS IN THE REPOSITORY

Unzip `hybrid-cloud-lab-repo.zip`. You get this:

```
hybrid-cloud-lab/
├── README.md                         front page of the repo
├── SECURITY.md                       how people should report a problem privately
├── .gitignore                        files Git must never track
├── .gitattributes                    forces Linux line endings, even when edited on Windows
├── .env.example                      template for your private values file (fake values)
├── .pre-commit-config.yaml           the commit guards
├── .github/
│   ├── dependabot.yml                keeps the CI actions up to date
│   └── workflows/terraform-plan.yml  optional CI check
├── scripts/check-sanitized.sh        guard that blocks your real values
├── configs/vyos/vyos-edge.commands.example   VyOS config with placeholders
├── docs/
│   ├── BEGINNER_GUIDE.md             the build guide
│   └── PUBLISHING_GUIDE.md           this guide
└── terraform/                        Google Cloud side as code
    ├── *.tf                          the code
    ├── terraform.tfvars.example      template, fake values
    └── backend.hcl.example           template, fake values
```

### What is safe to publish and what is not

| Publish (tracked) | Never publish (ignored) | Why it is dangerous |
|---|---|---|
| `*.tf` code | `terraform.tfvars` | Your real IPs, project ID, email |
| `*.example` templates | `backend.hcl` | Your real bucket name |
| `.terraform.lock.hcl` | `*.tfstate`, `tfplan` | **Contain your PSKs in plaintext** |
| `.env.example` | `.env`, `~/.hybrid-lab.env` | Your real values |
| `vyos-edge.commands.example` | `config.boot` | Real VyOS config with the PSK inside |
| `docs/` | OPNsense XML backups | Full firewall config with the PSK |

The `.gitignore` already blocks everything in the right-hand column. You will prove that in Step 6.

> **Why `.terraform.lock.hcl` IS published:** it records the exact fingerprint of the Terraform provider you used. Anyone running your code then gets the same verified build. It contains no secrets.

---

# STEP 1: SECURE YOUR GITHUB ACCOUNT

📍 **GitHub website**

### What you are doing
Making sure nobody can push to your account even if they learn your password, and that your personal email never appears in your commits.

### Why
Your repo is only as safe as the account that owns it. And every commit permanently records an email address. If that is your personal Gmail, it is published forever.

### Do this

1. **Two-factor authentication:** profile picture → **Settings → Password and authentication** → turn on two-factor authentication. Use an authenticator app or a passkey, not SMS. Save the recovery codes in your password manager.
2. **Hide your email:** **Settings → Emails**:
   - Tick **Keep my email addresses private**.
   - Tick **Block command line pushes that expose my email**.
   - Copy the address shown that looks like `12345678+your-username@users.noreply.github.com`. You need it in Step 3.

### You should see
Two-factor shows as enabled, and the noreply address is visible on the Emails page.

---

# STEP 2: INSTALL THE TOOLS

📍 **Your computer's terminal** (Linux, macOS, Windows with WSL or Git Bash) or **Google Cloud Shell**

### What you are doing
Installing Git, the GitHub command-line tool, and the commit guards.

### Do this

**Git** (Cloud Shell already has it):

```bash
git --version
```

If it is missing: Ubuntu/Debian `sudo apt install -y git`, Fedora `sudo dnf install -y git`, macOS `xcode-select --install`.

**GitHub CLI** (`gh`), optional but makes Steps 4 and 11 easier. Install it from the official instructions at `https://cli.github.com`, then:

```bash
gh --version
```

**pre-commit**, in its own isolated environment so it cannot break other Python tools:

```bash
python3 -m pip install --user pipx
python3 -m pipx ensurepath
source ~/.bashrc          # or open a new terminal
pipx install pre-commit
pre-commit --version
```

> **Why `pipx`?** It installs each tool in a private virtual environment. Installing with plain `pip` mixes packages together and can break your system's Python.

### You should see
A version number from each command.

---

## Step 2 on Windows (PowerShell, then Git Bash)

The commands in this guide are written for a bash terminal. On Windows, do the installs below in **PowerShell**, then use **Git Bash** (installed with Git for Windows) for every other step. That avoids translating each command.

> **Do not use an "Administrator" PowerShell for this.** It starts in `C:\WINDOWS\system32`, and anything you create there lands in a system folder. Open a normal PowerShell instead.

**1. Install Python and the GitHub CLI** with Windows' built-in package manager:

```powershell
winget install -e --id Python.Python.3.13
winget install -e --id GitHub.cli
```

Accept any prompts. **Close PowerShell and open a new one**, so it sees the new programs.

**2. Stop Windows hijacking the word `python`.** If you saw `Python was not found; run without arguments to install from the Microsoft Store`, that was a Store shortcut, not real Python. Turn it off: **Settings → Apps → Advanced app settings → App execution aliases** → switch **off** `python.exe` and `python3.exe`.

**3. Install pre-commit**, using `py` (the Windows Python launcher) instead of `python3`:

```powershell
py --version
py -m pip install --user pipx
py -m pipx ensurepath
```

Close and reopen PowerShell again, then:

```powershell
pipx install pre-commit
pre-commit --version
gh --version
```

**4. Make Git safe for files that also run on Linux:**

```powershell
git config --global core.autocrlf input
```

Windows uses a different line ending from Linux. Without this, Git can save `scripts/check-sanitized.sh` with Windows endings, and bash then refuses to run it with `bad interpreter: /usr/bin/env bash^M`. The repository's `.gitattributes` enforces the same rule from its side.

**5. From now on, use Git Bash.** Start menu → **Git Bash**. It opens in your home folder (`/c/Users/<you>`), which is where `~/projects` and `~/.hybrid-lab-denylist` will live. In Git Bash:

| Guide says | On Windows Git Bash |
|---|---|
| `python3` | `py` |
| `nano` | works, or use `notepad ~/.hybrid-lab-denylist` |
| `chmod 600` | has little effect on Windows; the file is already private to your Windows account |
| `~/Downloads/...` | same path, Git Bash maps it to your Downloads folder |

Check that pre-commit is visible from Git Bash:

```bash
pre-commit --version
```

If it says `command not found`, close and reopen Git Bash; `ensurepath` only applies to new windows.

---

# STEP 3: TELL GIT WHO YOU ARE

### What you are doing
Setting the name and email that go into every commit you make.

### Why
Git stamps every commit with these two values, publicly and permanently. Use the private noreply address from Step 1, never your personal email.

### Do this

```bash
git config --global user.name  "Your Name"
git config --global user.email "12345678+your-username@users.noreply.github.com"
git config --global init.defaultBranch main
git config --global pull.rebase false
```

### You should see

```bash
git config --global --list | grep -E "user\.|init\."
```

Your name, the **noreply** address, and `init.defaultbranch=main`.

---

# STEP 4: CONNECT YOUR COMPUTER TO GITHUB

### What you are doing
Giving your computer a way to prove to GitHub that it is you, without typing your password.

### Why
GitHub no longer accepts account passwords for pushing. You need either a key or a login token. Never paste a token into a file or a command that ends up in your history.

### Do this: Option A, the GitHub CLI (easiest)

```bash
gh auth login
```

Answer: **GitHub.com** → **SSH** → generate a new SSH key → add a passphrase → **Login with a web browser**. Copy the one-time code it shows, approve in the browser.

### Do this: Option B, an SSH key by hand

```bash
ssh-keygen -t ed25519 -C "github-$(hostname)"
```

Press Enter to accept the file location. **Type a passphrase** when asked. It protects the key if your computer is ever copied.

```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the whole line (it starts with `ssh-ed25519`). On GitHub: **Settings → SSH and GPG keys → New SSH key** → Type **Authentication Key** → paste → **Add**.

> **Only ever copy the file ending in `.pub`.** That is the public half. The file without `.pub` is your private key and must never leave your computer.

### You should see

```bash
ssh -T git@github.com
```

`Hi your-username! You've successfully authenticated, but GitHub does not provide shell access.` That message means it worked. The second half is normal.

---

# STEP 5: PREPARE THE PROJECT FOLDER

### What you are doing
Placing the project where you will work on it.

### Do this

```bash
mkdir -p ~/projects && cd ~/projects
unzip ~/Downloads/hybrid-cloud-lab-repo.zip        # adjust the path to where you saved it
mv hybrid-cloud-lab-repo hybrid-cloud-lab
cd hybrid-cloud-lab
ls -la
```

`ls -la` shows hidden files too (names starting with a dot). You should see `.gitignore`, `.env.example`, `.pre-commit-config.yaml` and `.github`.

Make sure the guard script can run:

```bash
chmod +x scripts/check-sanitized.sh
```

**On Windows**, `chmod` does not mark the file as executable inside Git. After `git init` in Step 6, also run this, so the script still runs for anyone who clones the repo on Linux or macOS:

```bash
git update-index --add --chmod=+x scripts/check-sanitized.sh
```

---

# STEP 6: PROVE THE IGNORE LIST WORKS

### What you are doing
Checking, before anything is tracked, that Git will refuse your real files.

### Why
A typo in `.gitignore` is invisible until the day it publishes your state file. Testing takes one minute.

### Do this

```bash
git init
for f in terraform/terraform.tfvars terraform/backend.hcl terraform/terraform.tfstate \
         terraform/tfplan .env config.boot \
         terraform/terraform.tfvars.example terraform/.terraform.lock.hcl .env.example; do
  if git check-ignore -q "$f"; then echo "IGNORED    $f"; else echo "PUBLISHED  $f"; fi
done
```

### You should see

```
IGNORED    terraform/terraform.tfvars
IGNORED    terraform/backend.hcl
IGNORED    terraform/terraform.tfstate
IGNORED    terraform/tfplan
IGNORED    .env
IGNORED    config.boot
PUBLISHED  terraform/terraform.tfvars.example
PUBLISHED  terraform/.terraform.lock.hcl
PUBLISHED  .env.example
```

If any real-value file says **PUBLISHED**, stop and fix `.gitignore` before going further.

> **Where your real values belong:** `~/.hybrid-lab.env` (in your home folder, outside the project), `terraform/terraform.tfvars` and `terraform/backend.hcl` (ignored). Your PSKs belong in Google Secret Manager and nowhere on disk.

---

# STEP 7: WRITE YOUR PRIVATE DENYLIST

### What you are doing
Listing every real value from your lab in a private file, so a guard can block any commit that contains one.

### Why
gitleaks recognises things that **look** like secrets: keys, tokens, passwords. It does not know that `203.0.113.13`-style addresses are *your* public IPs, or that a word is your switch's hostname. Only you know that. The denylist teaches the guard.

The file lives **outside** the project, so the list of what to hide is never itself published.

### Do this

```bash
nano ~/.hybrid-lab-denylist
```

One pattern per line. Put a backslash before every dot in an IP address (in patterns, a plain `.` means "any character"):

```
your-real-project-id
your-real-project-number
your-billing-account-id
203\.0\.113\.13
203\.0\.113\.14
your-switch-hostname
your-router-hostname
your\.personal@email\.com
```

Replace every line with **your real** values: public IPs, Google VPN IPs, project ID and number, billing account ID, device hostnames, ISP name if it identifies a site, personal email. Save with Ctrl+O, Enter, Ctrl+X.

```bash
chmod 600 ~/.hybrid-lab-denylist
```

`chmod 600` means only you can read it.

### Check the whole project right now

```bash
grep -rnEf ~/.hybrid-lab-denylist . --exclude-dir=.git && echo "FOUND REAL VALUES ABOVE" || echo "CLEAN"
```

You must see `CLEAN`. If anything is found, replace it with a placeholder before continuing.

---

# STEP 8: TURN ON THE COMMIT GUARDS

### What you are doing
Installing the hooks so every commit is checked automatically.

### Why
Checking by hand works until the one time you are tired. A hook checks every single time and **refuses** the commit if it finds a problem. Discipline fails; automation does not.

### Do this

```bash
pre-commit install
pre-commit run --all-files
```

The first run downloads the tools and takes a minute or two.

### You should see

```
Detect hardcoded secrets.....................................Passed
Block real lab addresses and identifiers.....................Passed
terraform fmt................................................Passed
```

### Now prove the guard actually blocks something

Never trust a guard you have not seen work.

```bash
head -1 ~/.hybrid-lab-denylist | tr -d '\\' > leak-test.txt
git add leak-test.txt
git commit -m "test: this must be blocked"
```

You should see `BLOCKED: leak-test.txt contains a real lab value` and **no commit is created**. Clean up:

```bash
git rm --cached -q leak-test.txt
rm leak-test.txt
```

### If it goes wrong

| Message | Fix |
|---|---|
| `check-sanitized: no denylist at ...` | Step 7 was skipped, or the file is empty |
| `terraform: command not found` (terraform fmt) | Terraform is not installed on this computer. Install it, or for this commit only run `SKIP=terraform-fmt git commit ...` |
| gitleaks fails to install, mentions Go | In `.pre-commit-config.yaml`, change `id: gitleaks` to `id: gitleaks-system` and install the gitleaks program itself from its official releases page |
| `Permission denied` on the script | `chmod +x scripts/check-sanitized.sh` |

> **Never use `git commit --no-verify`** to get past a guard. That flag switches the guards off. If a guard blocks you, it found something; fix that instead.

---

# STEP 9: LOOK AT EXACTLY WHAT WILL BE PUBLISHED

### What you are doing
Reading the list of files before the first commit, with your own eyes.

### Do this

```bash
git add .
git status
```

Read every line under **Changes to be committed**. Then see the size of what is going in:

```bash
git diff --cached --stat
```

### You should see
Only the files from Part 2's left-hand column. **None** of these may appear: `terraform.tfvars`, `backend.hcl`, any `.tfstate`, `tfplan`, `.env`, `config.boot`, any `.xml`, anything with `key`, `secret` or `credential` in its name.

If something wrong is listed:

```bash
git rm --cached path/to/the/file
```

Then add its pattern to `.gitignore` and run `git add .` again.

---

# STEP 10: THE FIRST COMMIT

```bash
git commit -m "Hybrid cloud lab: route-based IPsec with eBGP to GCP, built on OPNsense and VyOS"
```

The guards run first. When they all say **Passed**, the commit is created.

```bash
git log --oneline
git log -1 --format="%an <%ae>"
```

The second line must show your **noreply** address. If it shows your personal email, fix Step 3, then:

```bash
git commit --amend --reset-author --no-edit
```

> **Good commit messages tell a story.** Later commits like `Fix: PSK must use openssl rand -hex; base64 broke IKE_AUTH` show how you actually worked, which is more convincing to a reader than a single "initial commit".

---

# STEP 11: CREATE THE REPOSITORY, PRIVATE FIRST

### What you are doing
Creating the GitHub repository as **private**, pushing to it, and inspecting it before anyone else can see it.

### Why
Tools can miss things. Reading your repository on the website, the way a stranger would, catches what they miss. Making it private first means a mistake costs nothing.

### Do this: Option A, GitHub CLI

```bash
gh repo create hybrid-cloud-lab --private --source=. --remote=origin \
  --description "Route-based IPsec (VTI) with eBGP from an on-prem lab to GCP, on OPNsense and VyOS" \
  --push
```

### Do this: Option B, the website

1. Go to `https://github.com/new`.
2. Name: `hybrid-cloud-lab`. Visibility: **Private**.
3. **Do not** tick "Add a README", ".gitignore" or "license". You already have them, and ticking them creates a conflict.
4. **Create repository**, then in your terminal:

```bash
git remote add origin git@github.com:your-username/hybrid-cloud-lab.git
git push -u origin main
```

### You should see
The repository page on GitHub shows your files and the README rendered as the front page.

---

# STEP 12: INSPECT IT, THEN MAKE IT PUBLIC

### What you are doing
Reviewing the private repository like a stranger would, then switching it to public.

### Do this

1. Click through every folder on the website. Confirm there is no `terraform.tfvars`, `backend.hcl`, state file or `config.boot`.
2. Open `README.md` and `docs/BEGINNER_GUIDE.md` and confirm tables and diagrams display properly.
3. Use the search box at the top of the repo (press `/`) and search for your real project ID and one real public IP. Both must find **nothing**.
4. **Add a license** (the README says MIT): **Add file → Create new file**, name it `LICENSE`, click **Choose a license template → MIT License**, fill your name and year, **Commit**. Then pull it to your computer:

```bash
git pull
```

5. Make it public: **Settings → General → Danger Zone → Change visibility → Make public**. Read the warning and confirm.

---

# STEP 13: TURN ON GITHUB'S OWN PROTECTIONS

📍 **Repository → Settings**

### What you are doing
Adding a third guard (GitHub's scanning) and limiting what automation and strangers can do.

| Where | Setting | Value | Why |
|---|---|---|---|
| **Advanced Security** (or **Code security**) | Secret scanning | **Enable** | GitHub checks every push for known secret formats |
| same | Push protection | **Enable** | Refuses a push that contains a recognised secret |
| same | Dependabot alerts | **Enable** | Warns you about vulnerable dependencies and actions |
| same | Private vulnerability reporting | **Enable** | People can report a problem without posting it publicly (used by `SECURITY.md`) |
| **Actions → General** | Workflow permissions | **Read repository contents and packages permissions** | Every workflow starts with the least access |
| same | Allow GitHub Actions to create and approve pull requests | **Off** | Automation cannot approve its own changes |
| same | Fork pull request workflows | **Require approval for all external contributors** | Strangers cannot run your workflows |
| **Rules → Rulesets** (or **Branches**) | New branch ruleset for `main` | Require a pull request before merging; block force pushes; restrict deletions | Nobody, including you by accident, rewrites `main` directly |

> **On a free account with a public repo,** secret scanning and push protection are available. If a setting is missing on your plan, the local guards from Step 8 still protect you.

`.github/dependabot.yml` is already in the repository. Dependabot will now open a pull request whenever one of the pinned CI actions releases a new version, with the new commit SHA filled in for you.

---

# STEP 14: MAKE IT EASY TO FIND AND READ

### Description and topics

On the repo's front page, click the **gear** next to **About**:

- **Description:** `Route-based IPsec (VTI) with eBGP from an on-prem lab to GCP, built in parallel on OPNsense and VyOS.`
- **Topics:** `gcp`, `networking`, `bgp`, `ipsec`, `vpn`, `vyos`, `opnsense`, `terraform`, `hybrid-cloud`, `proxmox`, `infrastructure-as-code`

Topics are how other people find your repo.

### Pin it to your profile

Your profile page → **Customize your pins** → tick this repository.

### What makes a reader trust it

The README's real results (negotiated cipher, both BGP sessions established, measured round-trip time) and the guide's honest list of what went wrong and why are what make a lab repository credible. Keep them up to date as you change things.

---

# STEP 15: YOUR ROUTINE FOR EVERY FUTURE CHANGE

### What you are doing
Changing the project safely after it is public.

### Why
Working on a branch and merging through a pull request means the CI check and your own review happen before anything lands on `main`.

### Do this

```bash
cd ~/projects/hybrid-cloud-lab
git switch main
git pull                                   # get the latest
git switch -c fix/describe-your-change     # new branch
# ...edit files...
git status
git add -p                                 # review and approve each change piece by piece
git commit -m "Fix: short description of what and why"
git push -u origin fix/describe-your-change
gh pr create --fill                        # or open the link Git prints
```

On GitHub, read the pull request's **Files changed** tab one more time, wait for checks, then **Merge**. Afterwards:

```bash
git switch main
git pull
git branch -d fix/describe-your-change
```

> **`git add -p` instead of `git add .`** shows each change and asks yes or no. It is the habit that stops a stray file or a debugging line with a real value from slipping in.

### Updating the VyOS config later

Never publish `config.boot`. When your router config changes, update `configs/vyos/vyos-edge.commands.example` by hand with **placeholders**, then commit that.

---

# STEP 16: OPTIONAL, THE AUTOMATIC TERRAFORM CHECK

### What it does
On every pull request that touches `terraform/`, GitHub runs `terraform plan` against your real Google project and reports one line: `No changes` or `Plan: X to add...`. It never applies anything.

### Why it is safe to have in a public repository

| Risk | How the workflow handles it |
|---|---|
| A stored key gets stolen | There is no stored key. GitHub proves its identity to Google and receives a token that lasts minutes |
| A tampered action steals data | Each action is pinned to a full 40-character commit SHA, not a movable tag |
| The workflow is given too much power | It starts with `permissions: {}` and asks only for `contents: read` and `id-token: write` |
| Someone injects commands through a PR title | No user-controlled text is ever pasted into a script |
| A stranger's fork runs it | Fork pull requests are skipped |
| Logs reveal your project details | Public repo logs are public, so only the summary line is printed |

### Do this

Follow **Phase 10.5** in `docs/BEGINNER_GUIDE.md`. It creates the trust between GitHub and Google (Workload Identity Federation), a read-only service account, and lists the repository **Variables** to add under **Settings → Secrets and variables → Actions → Variables**.

> **None of those values are secrets, so they go in Variables, not Secrets.** The PSKs stay in Google Secret Manager; the CI identity reads them only during a plan.

### You should see
Open a small pull request that changes a comment in a `.tf` file. Under **Checks**, `terraform-plan` runs and shows `No changes.`

---

# STEP 17: IF YOU EVER PUSH A SECRET OR REAL VALUE

Follow this order. **Do not start by deleting the file.**

### 1. Make the leaked secret useless (minutes, not hours)

The secret is compromised the moment it was pushed. For this lab's PSK:

```bash
openssl rand -hex 24 | tr -d '\n' | gcloud secrets versions add psk-vyos --data-file=-
```

Set the same new value on the router, then `terraform apply` (the new secret version replaces just that tunnel). For a GitHub token or any other credential, revoke it in the service that issued it.

### 2. Remove it from the history

Deleting the file in a new commit leaves it visible in older commits. Rewrite history with `git-filter-repo`:

```bash
pipx install git-filter-repo
cd ~/projects/hybrid-cloud-lab
printf '%s==>REDACTED\n' 'the-exact-leaked-text' > ../replacements.txt
git filter-repo --replace-text ../replacements.txt --force
rm ../replacements.txt
git remote add origin git@github.com:your-username/hybrid-cloud-lab.git
git push --force --all
```

`git filter-repo` removes the remote link as a safety measure, which is why you add it back. Your branch ruleset blocks force pushes, so temporarily allow it for yourself, push, then turn the protection back on.

### 3. Ask GitHub to clear cached copies

Old commit pages can stay viewable by their SHA. Contact GitHub Support and ask for cached views of the removed commits to be purged. Check whether anyone forked the repo in that window (**Insights → Forks**).

### 4. Find out why the guards missed it

Add the missed value to `~/.hybrid-lab-denylist`, or the missed file type to `.gitignore`, so the same leak cannot happen twice.

---

# STEP 18: TROUBLESHOOTING

| Message or symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | GitHub does not recognise your key | Step 4; test with `ssh -T git@github.com` |
| `remote: ... push declined due to email privacy restrictions` | Commit uses your personal email | Step 3, then `git commit --amend --reset-author --no-edit` |
| `rejected ... (fetch first)` | GitHub has commits you do not, often a LICENSE made on the website | `git pull`, then push again |
| `remote origin already exists` | The remote was added before | `git remote set-url origin git@github.com:your-username/hybrid-cloud-lab.git` |
| `Updates were rejected ... protected branch` | Ruleset blocks direct pushes to `main` | Use a branch and pull request (Step 15) |
| `GH013: Repository rule violations ... secret` | Push protection found a secret | Do not bypass. Remove it from the commit, then Step 17 part 1 |
| `BLOCKED: ... contains a real lab value` | Your denylist matched | Replace the value with a placeholder |
| A file you wanted ignored shows in `git status` | It was tracked before being ignored | `git rm --cached <file>`, then commit |
| Tables look broken on GitHub | A blank line is missing before the table | Add an empty line above it |
| `Python was not found; run without arguments to install from the Microsoft Store` | Windows Store shortcut, Python not installed | Step 2 on Windows, parts 1 and 2 |
| `bad interpreter: /usr/bin/env bash^M` | Script saved with Windows line endings | `git config --global core.autocrlf input`, then `git add --renormalize .` |
| Hook says `Executable ... not found` on Windows | Commit made from PowerShell or CMD | Commit from **Git Bash** |
| CI shows `No changes` but you expected changes | Variables in **Settings → Variables** are out of date | Update `TF_TUNNELS_JSON` and friends |

---

# STEP 19: FINAL CHECKLIST

Tick every line before telling anyone about the repo.

**Account**
- [ ] Two-factor authentication on
- [ ] Commits use the noreply email, and command-line pushes that expose your email are blocked

**Content**
- [ ] `git check-ignore` proved real-value files are ignored (Step 6)
- [ ] Denylist search of the project returns `CLEAN` (Step 7)
- [ ] No `terraform.tfvars`, `backend.hcl`, state, plan, `.env`, `config.boot` or XML backup on GitHub
- [ ] Searching the repo for your real project ID and one real IP finds nothing
- [ ] `LICENSE` and `SECURITY.md` present

**Guards**
- [ ] `pre-commit install` done, all hooks **Passed**
- [ ] You watched the denylist guard **block** a test commit
- [ ] Secret scanning and push protection enabled on GitHub
- [ ] Dependabot alerts enabled, `.github/dependabot.yml` present

**Repository settings**
- [ ] Workflow permissions set to read-only by default
- [ ] Fork workflows require approval
- [ ] `main` protected: pull request required, no force pushes, no deletion

**Presentation**
- [ ] Description and topics set
- [ ] README renders correctly
- [ ] Pinned on your profile

---

## The three habits that keep a public repo safe

1. **Ignore first, add second.** Files that must never be published are in `.gitignore` before they exist.
2. **Let the guards do the remembering.** Hooks run on every commit; you only need to never switch them off.
3. **If something leaks, rotate before you clean.** A rotated secret is harmless wherever it was copied to.
