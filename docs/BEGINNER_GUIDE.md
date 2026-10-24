# Hybrid Cloud Lab: The Beginner's Build Guide

**Connect a home lab to Google Cloud with an encrypted tunnel and dynamic routing, step by step, explained in plain language.**

Version 1.0 · Rebuilt from a real build, with every mistake and fix from that build folded in.

---

## Read this first

### Who this is for

You know what an IP address is and you can type commands into a terminal. That is enough. Every new idea is explained in everyday language the first time it appears, and every step tells you what you should see when it worked.

### What you will have at the end

Two separate encrypted tunnels from your home lab into Google Cloud, one from an **OPNsense** firewall and one from a **VyOS** router, both talking to the same cloud router at the same time. Routes are exchanged automatically. Traffic is filtered on both sides. You get an email if a tunnel drops. The whole Google side is described as code, and the project is safe to publish on GitHub.

### How this guide works

The build is split into **phases**. Each phase ends with a **GATE**: a short test that must pass before you continue.

> **Never skip a gate.** Almost every painful moment in the original build came from a problem in one layer showing up as a symptom in a different layer. Gates stop problems from stacking on top of each other.

Each step uses the same layout:

| Part | What it tells you |
|---|---|
| **What you are doing** | One plain sentence |
| **Why** | The reason, in everyday language |
| **Do this** | The exact clicks or commands |
| **You should see** | What success looks like |
| **If it goes wrong** | The most likely cause |

### Where you type each thing

You will move between five places. Every phase starts with a 📍 line telling you where you are.

| What the instruction looks like | Where you type it |
|---|---|
| `Firewall → Rules → ...`, `VPN → IPsec → ...` | **OPNsense web page** |
| `gcloud ...`, `terraform ...` | **Google Cloud Shell** (the terminal inside the Google Cloud website) |
| `set ...`, `show ...`, `commit` | **VyOS console** |
| `ping`, `nmcli`, `curl` | **Your test computer** on the lab network |
| Datacenter, Hardware, Bridge | **Proxmox web page** |

An arrow `→` always means "click through menus". A grey box always means "type this in a terminal".

### The placeholder rule

This guide is written to be published, so it contains **no real addresses and no secrets**. Wherever you see a value in this table, use your own:

| In this guide | Means | Example used here |
|---|---|---|
| `<OPNSENSE_WAN_IP>` | Public IP your ISP gave the OPNsense WAN | `203.0.113.13` |
| `<VYOS_WAN_IP>` | A second public IP for VyOS | `203.0.113.14` |
| `<ISP_GATEWAY_IP>` | Your ISP's gateway | `203.0.113.9` |
| `<ISP_VLAN>` | VLAN your ISP handoff uses, if any | `900` |
| `$PROJECT_ID` | Your Google Cloud project ID | `your-project-id` |
| `<GCP_VPN_IP0>` / `<GCP_VPN_IP1>` | The two addresses Google gives your VPN gateway | read them in Phase 2 |

`203.0.113.x` and `198.51.100.x` are special "documentation only" ranges. They are safe to print anywhere because they never exist on the real internet.

---

# PART 1: THE BIG PICTURE

## The story in everyday language

Imagine your home lab is a **house** and Google Cloud is an **office building** across town.

- The **internet** is the public road between them. Anyone can see what drives on it.
- The **IPsec tunnel** is an **armoured van** that drives that road. Outsiders can see a van going past, but nobody can see inside it.
- The **VTI** (Virtual Tunnel Interface) is a **loading dock door** built into each building just for that van. Because it is a real door with a number on it, the building's internal signs can point at it: "parcels for the office, use dock 10."
- **BGP** is the two **mail rooms phoning each other** every few seconds: "these are the rooms I can deliver to." If the phone call stops, each side immediately stops sending mail that way.
- The **Cloud Router** is Google's **mail room clerk**. The clerk never carries parcels. The clerk only answers the phone and updates the signs inside the office building.
- The **VPC** is the **office building** itself, and the **subnet** is one **floor** of it.
- **Prefix lists and route maps** are the **mail room's rules** about which addresses they are willing to accept and announce.

Hold on to that picture. Every technical step below is one piece of it.

## The design on one page

```
        HOME LAB (Proxmox)                                   GOOGLE CLOUD (us-west1)
 ┌──────────────────────────────┐                     ┌──────────────────────────────────┐
 │                              │                     │                                  │
 │  Test PC 10.2.10.60          │                     │   vm-hub-test  10.8.10.x         │
 │      │                       │                     │        │                         │
 │  OPNsense  AS 65002          │   IPsec tunnel 0    │   VPC "vpc-hub"                  │
 │  LAN 10.2.10.1  ─────────────┼──── over internet ──┼─▶ subnet 10.8.10.0/24            │
 │  WAN <OPNSENSE_WAN_IP>       │  BGP 169.254.10.x   │        ▲                         │
 │                              │                     │        │ routes written here     │
 │  Test CT 10.2.20.60          │                     │   Cloud Router  AS 65001         │
 │      │                       │   IPsec tunnel 1    │        ▲                         │
 │  VyOS  AS 65003              │                     │        │ BGP                     │
 │  LAN 10.2.20.1  ─────────────┼──── over internet ──┼─▶ HA VPN gateway                 │
 │  WAN <VYOS_WAN_IP>           │  BGP 169.254.20.x   │   interface 0 / interface 1      │
 └──────────────────────────────┘                     └──────────────────────────────────┘
```

## The address plan (decide once, never change)

| Block | Purpose | Why this block |
|---|---|---|
| `10.2.10.0/24` | Lab network behind OPNsense | Private range, easy to remember |
| `10.2.20.0/24` | Lab network behind VyOS | Separate on purpose, see below |
| `10.8.10.0/24` | Google Cloud subnet | Must never overlap with home |
| `169.254.10.0/30` | The "phone line" for BGP, tunnel 0 | Link-local, cannot leak to the internet |
| `169.254.20.0/30` | The "phone line" for BGP, tunnel 1 | Same reason |
| `10.8.0.0/24` | **Never use** | OpenVPN's default. A future remote-access setup would collide |

**Private ASNs** (the "phone numbers" of each mail room): Google `65001`, OPNsense `65002`, VyOS `65003`. All three are different on purpose. That makes every conversation "external BGP", which has built-in loop protection.

> **Why two separate home networks?** If OPNsense and VyOS both announced the same network, Google would see two roads to one house and could send replies down the other road. You would be debugging that instead of learning. Separate networks mean each tunnel can be proven on its own.

> **Overlap is silent.** Google blocks you from creating overlapping subnets inside one VPC. Nothing blocks overlap between home and cloud. If it happens, each side thinks the destination is local and traffic disappears with no error. Pick ranges once and write them down.

---

# PART 2: WORDS YOU NEED

Only the words this build actually uses, each with an everyday comparison.

| Word | Plain meaning | Everyday comparison |
|---|---|---|
| **IPsec** | A standard for encrypting traffic between two gateways | The armoured van |
| **IKE (phase 1)** | The two gateways proving who they are and agreeing on a private channel | Two guards checking each other's badges |
| **CHILD_SA (phase 2)** | The keys that actually encrypt your data | The lock on the van's cargo doors |
| **PSK** (pre-shared key) | A long password both gateways already know | The secret handshake. Never sent over the road, only proven |
| **Route-based VPN** | The routing table decides what goes into the tunnel | Signs in the building decide which parcels go to dock 10 |
| **Policy-based VPN** | The tunnel itself has a fixed list of what it carries | A van that will only carry parcels from a printed list |
| **VTI** | An interface that represents the tunnel | The loading dock door with a number |
| **reqid** | The number that ties a tunnel to its VTI | The dock number painted on both the van and the door |
| **BGP** | A protocol for routers to tell each other which networks they can reach | Mail rooms phoning each other with address lists |
| **ASN** | A router's BGP identity number | The mail room's phone number |
| **Prefix list** | A list of networks you will accept or announce | The mail room's address rulebook |
| **Route map** | Applies a prefix list to one neighbour, in one direction | "Use this rulebook for calls from the office" |
| **MTU** | The biggest packet an interface will send | The van's cargo door size |
| **MSS clamping** | Telling computers to make their parcels smaller than the door | A sign at the warehouse: "boxes max 1360" |
| **DPD** | Regular "are you still there?" checks between gateways | A heartbeat |
| **VPC** | Your private network inside Google Cloud | The office building |
| **Cloud Router** | Google's BGP speaker. Does not forward traffic | The mail room clerk who only answers the phone |
| **HA VPN gateway** | Google's tunnel endpoint, with two public IPs | The office's two loading docks |
| **Terraform** | A tool that describes cloud resources as text files | A blueprint the builder follows exactly |
| **State file** | Terraform's record of what exists | The builder's site diary. Contains secrets |
| **Secret Manager** | Google's locked safe for passwords | A key safe on the wall |

---

# PART 3: SECURITY RULES BEFORE YOU TOUCH ANYTHING

## The five rules

1. **No secret ever goes into a file you might commit.** Not in code, not in a config, not in a "notes.txt". PSKs live in **Google Secret Manager** and are read only at the moment you need them.
2. **Treat every file as if it will be public.** This guide, the Terraform code and the VyOS config all use placeholders. Your real values live in one local file outside the project (`~/.hybrid-lab.env`).
3. **Least privilege.** Every firewall rule names a source. Nothing listens on the internet unless a tunnel needs it, and then only from Google's address.
4. **Every change must be reversible.** Back up before you change a firewall. Test before you save.
5. **Cost is a security property.** An abandoned tunnel or a forgotten speed test is money leaking out. You tear down at the end of every session.

## A security review of the original build

These are the risks that existed in the first version of this lab, and what this guide does instead. If you followed an older guide, fix these.

| # | Risk in the original build | Why it matters | What this guide does |
|---|---|---|---|
| 1 | PSK generated with `openssl rand -base64` | The `+ / =` characters get mangled when copied into a console. Caused a real authentication failure | `openssl rand -hex 24`: 48 characters of `0-9a-f` only |
| 2 | PSK kept in a notepad file and in `terraform.tfvars` | Plaintext secret on disk, one `git add .` away from public | Stored in **Secret Manager**, read on demand |
| 3 | Terraform state on Cloud Shell disk | State contains the PSK in plaintext | State in a locked, versioned Cloud Storage bucket |
| 4 | `.terraform.lock.hcl` listed in `.gitignore` | Without it, a different provider build could be downloaded next time | Lock file **is committed** |
| 5 | VM uses the default Compute service account | Broad default identity | Flagged; a dedicated account is the production fix (Part 12) |
| 6 | No BGP authentication | Anyone who could inject packets into the tunnel could speak BGP | Flagged; MD5 is an optional hardening step |
| 7 | OPNsense config backup downloaded unencrypted | The XML contains the PSK | Use the **encrypt** option when downloading |
| 8 | Allow-everything firewall rule left on the tunnel | Wider than needed | Replaced with named rules in Phase 7 |
| 9 | Real public IPs and hostnames in the documentation | Discloses someone else's production network | Documentation ranges and placeholders only |
| 10 | CI printing a full Terraform plan | In a public repo, Actions logs are public and show project IDs | CI prints the summary line only |

## What will cost money

| Item | Cost | When |
|---|---|---|
| VPC, subnet, firewall rules, Cloud Router, HA VPN gateway, peer gateways | Free | Always |
| `e2-micro` VM with 30 GB standard disk in `us-west1` | Free tier | While running |
| **Each VPN tunnel** | **About USD 0.05 per hour** | From the moment it is created |
| Traffic out through the tunnel | About USD 0.12 per GB | Only when you send data |
| Secret Manager | A few cents per month | Always |
| Monitoring alerts | Free for these metrics | Always |

> **The one dangerous step:** a speed test left running. One hour at 1 Gbps is about 450 GB, roughly USD 54. Always run speed tests for a fixed 20 seconds and never in the background.

> **On a Google Cloud free trial, never press "Activate full account".** While on the trial you cannot be charged; the account simply stops when credit runs out. Activating switches you to pay-as-you-go.

---

# PART 4: PREPARE YOUR VALUES FILE

📍 **Google Cloud Shell** (open it with the `>_` icon at the top right of the Google Cloud console)

### What you are doing
Creating one private file that holds every non-secret value for this lab, so every command can use names like `$PROJECT_ID` instead of you retyping values.

### Why
Cloud Shell forgets everything typed with `export` when the session times out. Only your home folder survives. A file in your home folder, loaded automatically, means the values are always there. It also keeps real values out of anything you might publish.

### Do this

```bash
cat > ~/.hybrid-lab.env <<'EOF'
export PROJECT_ID="your-project-id"
export REGION="us-west1"
export ZONE="us-west1-b"
export TF_STATE_BUCKET="${PROJECT_ID}-tfstate"
export OPNSENSE_WAN_IP="203.0.113.13"
export VYOS_WAN_IP="203.0.113.14"
EOF

chmod 600 ~/.hybrid-lab.env
nano ~/.hybrid-lab.env        # replace the example values with your real ones, Ctrl+O, Enter, Ctrl+X
```

Make Cloud Shell load it every time it starts, and point `gcloud` at your project:

```bash
grep -q hybrid-lab.env ~/.bashrc || cat >> ~/.bashrc <<'EOF'

# Hybrid lab
[ -f ~/.hybrid-lab.env ] && source ~/.hybrid-lab.env
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
EOF

source ~/.bashrc
```

### You should see

```bash
echo "PROJECT=[$PROJECT_ID] REGION=[$REGION] ZONE=[$ZONE]"
gcloud config list --format="value(core.project)"
```

All three brackets filled, and your project ID printed by the second command.

### If it goes wrong

| Symptom | Cause |
|---|---|
| `could not parse resource []` in any later command | A variable is empty. Run `source ~/.bashrc` and recheck |
| The prompt shows `cs-123456-default` and no project name | Normal. That is the Cloud Shell machine's hostname, not your project. Trust `gcloud config list` |

> **Why the PSK is not in this file:** the file is private, but it is still a file. Secrets go in Secret Manager, which has access control and an audit log. You will set that up in Phase 2.

---

# PHASE 0: PREPARE THE HOME LAB

📍 **Proxmox web page**, your **switch**, the **OPNsense console**, and your **test computer**.

## 0.1 Get the ISP connection to the firewall

### What you are doing
Giving the OPNsense virtual machine a direct path to your ISP's handoff, so it can own a public IP.

### Why
The tunnel needs a fixed public address on both ends. Google's side asks for your exact public IP; it cannot use a name or a changing address. That address is also typed into nine different places across both sides, so it must never change.

### The trap from the original build

The ISP handoff was on VLAN `<ISP_VLAN>` on one switch. The Proxmox host was on a second switch. The VLAN was allowed on the Proxmox port but **not on the links between the two switches**. OPNsense sent out "who has the gateway?" and nobody heard it.

Every individual piece was correct. The break was in the middle. You can prove it on the switch nearest Proxmox:

```
show mac address-table vlan <ISP_VLAN>
```

If you only see your firewall's own MAC address and never the ISP gateway's, the VLAN is not reaching the ISP.

### Do this: Option A (recommended, no production risk)

Use a spare physical network port on the Proxmox host and a cable straight to the ISP switch.

1. On the switch, make the port an **access** port in the ISP VLAN:

```
interface GigabitEthernet1/0/X
 description FW-WAN-LAB
 switchport mode access
 switchport access vlan <ISP_VLAN>
 spanning-tree portfast
 no shutdown
```

2. In Proxmox: **Datacenter → your node → System → Network → Create → Linux Bridge**

| Field | Value | Why |
|---|---|---|
| Name | `vmbr1` | The WAN bridge |
| IPv4/CIDR | **leave empty** | The Proxmox host must not have an address on the internet side |
| Gateway | **leave empty** | Same reason |
| Bridge ports | your spare NIC, e.g. `enp1s0` | The physical cable |
| VLAN aware | unchecked | The switch port already untags the VLAN |

3. Create a second bridge for the lab network: name `vmbr2`, **no IP, no bridge port**. It is a private switch that only lives inside Proxmox.

4. **Apply Configuration.**

### Do this: Option B (only if a cable is impossible)

Add the VLAN to the switch-to-switch trunk links.

> ## Read before typing
> The word **`add`** is the difference between a lab change and an outage. `switchport trunk allowed vlan <ISP_VLAN>` **without** `add` replaces the whole list and cuts every other VLAN on that link.
>
> ```
> show run interface Port-channel1          ! copy this output somewhere safe first
> configure terminal
> interface Port-channel1
>  switchport trunk allowed vlan add <ISP_VLAN>
> end
> ```
>
> Do it on both ends of the link, in a change window, with out-of-band access ready.

### You should see
On the switch nearest Proxmox, `show mac address-table vlan <ISP_VLAN>` now lists the ISP gateway's MAC address.

## 0.2 Create the OPNsense VM

**Proxmox → Create VM**

| Setting | Value | Why |
|---|---|---|
| VM ID | `400` | Any free number |
| OS | OPNsense ISO | Download from the official OPNsense site and verify the checksum |
| Machine / BIOS | `q35` / SeaBIOS | Works reliably |
| CPU / RAM | 2 to 4 cores / 4 to 8 GB | Enough for IPsec plus routing |
| Disk | 20 GB | |
| Network device 1 (`net0`) | Bridge `vmbr1`, model VirtIO | WAN |
| Network device 2 (`net1`) | Bridge `vmbr2`, model VirtIO | LAN |
| **Firewall checkbox on both NICs** | **unchecked** | Otherwise Proxmox filters packets in front of your firewall, which produces failures that look like IPsec problems |
| VLAN tag | **empty** (Option A) or `<ISP_VLAN>` on `net0` (Option B with a VLAN-aware bridge) | |

Install OPNsense, then on its console:

1. **Assign interfaces:** `vtnet0` = WAN, `vtnet1` = LAN.
2. **Set interface IP:** WAN = `<OPNSENSE_WAN_IP>/29`, gateway `<ISP_GATEWAY_IP>`. LAN = `10.2.10.1/24`, DHCP range `10.2.10.100` to `10.2.10.200`.
3. Browse to `https://10.2.10.1` from a machine on `vmbr2` and finish the setup wizard. **Change the default root password.**

**WAN interface settings to confirm** (`Interfaces → [WAN]`): Block private networks ✓, Block bogon networks ✓. Your WAN is genuinely public, so both protections apply.

## 0.3 Create a test computer on the lab network

A small VM on `vmbr2` you can ping from. Fedora, Ubuntu or Debian are all fine.

> ## If you boot a live ISO, install it to disk before Phase 4
> A prompt like `liveuser@localhost-live` means nothing you configure survives a reboot. Run the installer and choose **Use entire disk** (not "Reinstall", which keeps an old layout you did not create). After installing and **before rebooting**: Proxmox → VM → Hardware → CD/DVD Drive → **Do not use any media**. Otherwise it boots the live ISO again and the install looks like it failed.

Give it a **static** address outside the DHCP pool. On Fedora, from the Proxmox console (not SSH, the connection drops when you do this):

```bash
nmcli connection show                       # find the connection name
sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 10.2.10.60/24 \
  ipv4.gateway 10.2.10.1 \
  ipv4.dns 10.2.10.1
sudo nmcli connection up "Wired connection 1"
```

> **Why `.60` and not `.100`?** `.100` is the first address the DHCP server hands out. A static host there eventually collides with a DHCP client, and the result is intermittent connectivity that is very hard to trace. Static hosts live in `.1` to `.99`.

---

## GATE 0: The firewall reaches the internet

**OPNsense:** `Interfaces → Diagnostics → Ping`, source **WAN**, host `<ISP_GATEWAY_IP>`. Then host `1.1.1.1`.

**Test computer:**

```bash
ping -c 3 10.2.10.1
ping -c 3 1.1.1.1
curl -s https://ifconfig.me; echo
```

**The last line must print `<OPNSENSE_WAN_IP>`.** If it prints anything else, traffic is leaving through a different router and the path is wrong.

| Symptom | Where to look |
|---|---|
| Cannot ping the ISP gateway | `Interfaces → Diagnostics → ARP Table`. No entry for the gateway means a layer 2 problem: back to 0.1 |
| Gateway pings, `1.1.1.1` does not | `System → Gateways`: is the WAN gateway online? |
| OPNsense works, test computer does not | `Firewall → NAT → Outbound` should be **Automatic** |

**Cost so far: zero.**

---

# PHASE 1: BUILD THE GOOGLE CLOUD FOUNDATION

📍 **Google Cloud console** for 1.1 and 1.2, **Cloud Shell** for everything else. Nothing on OPNsense today.

## 1.1 Project, billing and a budget alert

1. Create a project dedicated to this lab. A separate project means one command deletes everything at the end.
2. Link it to your billing account. Check in Cloud Shell:

```bash
gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)"
```

You should see `True`.

3. **Billing → Budgets & alerts → Create budget**

| Field | Value | Why |
|---|---|---|
| Define | **Alerts only** | "Spend cap enforcement" is a preview feature that can pause services. For a lab, an alert is enough |
| Name | `hybrid-lab-guard` | |
| Scope | this project only | |
| Credits | **untick** "include credits" | So the alert reflects real usage even while free credit covers it |
| Amount | `50` | A tripwire, far above what this lab should cost |
| Thresholds | 50%, 90%, 100% | |

## 1.2 Quotas

On a free trial, VPN quotas show **Adjustable: No**. That is fine. Skip this. Your real cost control is the teardown habit, not a quota.

## 1.3 Turn on the services you need

```bash
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  dns.googleapis.com \
  monitoring.googleapis.com \
  secretmanager.googleapis.com
```

It can look frozen for two or three minutes. That is normal. Enabling services is free.

## 1.4 Create the VPC and subnet

```bash
gcloud compute networks create vpc-hub \
  --subnet-mode=custom \
  --bgp-routing-mode=global \
  --description="Hybrid lab hub network"

gcloud compute networks subnets create sn-hub-usw1 \
  --network=vpc-hub \
  --region="$REGION" \
  --range=10.8.10.0/24 \
  --enable-private-ip-google-access
```

### Why each flag

| Flag | Plain reason |
|---|---|
| `--subnet-mode=custom` | "Auto" mode creates a subnet in every region from a huge range and wrecks your address plan. You cannot switch back |
| `--bgp-routing-mode=global` | The Cloud Router will announce **every** subnet in the VPC, in any region, and routes from home apply everywhere |
| `--enable-private-ip-google-access` | Lets the VM reach Google services without a public IP |

> **The single biggest difference from AWS:** a Google VPC has **no address range of its own**. Only subnets have ranges. So Google announces each subnet individually, never one big summary. Remember this; it causes a real failure in Phase 6 if you forget it.

> **Flow logs are deliberately off.** They are billed through Cloud Logging. Turn them on only while investigating.

## 1.5 Firewall rules

Google Cloud **denies all incoming traffic by default**. Nothing works until you allow it.

```bash
gcloud compute firewall-rules create hub-allow-iap-ssh \
  --network=vpc-hub --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --description="SSH via Identity-Aware Proxy"

gcloud compute firewall-rules create hub-allow-from-home \
  --network=vpc-hub --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=icmp,tcp:22,tcp:80,tcp:443,tcp:53,udp:53,tcp:5201,tcp:8080 \
  --source-ranges=10.2.10.0/24 \
  --description="Allow lab LAN over the VPN"
```

`35.235.240.0/20` is the published address range of Google's Identity-Aware Proxy. It lets you SSH into the VM **without giving the VM a public IP**, which is both cheaper and safer.

## 1.6 The test VM

```bash
gcloud compute instances create vm-hub-test \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --subnet=sn-hub-usw1 \
  --no-address \
  --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=30GB --boot-disk-type=pd-standard \
  --description="Hybrid lab target"
```

> **Three settings keep this free:** `e2-micro`, `pd-standard` (balanced and SSD disks are not free), and `--no-address` (public IPs are not in the free tier).

> **Consequence you must remember:** with no public IP and no Cloud NAT, **this VM has no internet**. It can reach Google services only. `apt install` from Debian's servers will fail with `Network is unreachable`. That is expected, not broken.

Save its address:

```bash
gcloud compute instances describe vm-hub-test --zone="$ZONE" \
  --format="get(networkInterfaces[0].networkIP)"
```

It will be `10.8.10.x`. Write it into `~/.hybrid-lab.env` as `export GCP_VM_IP="10.8.10.x"`.

Log in once through IAP:

```bash
gcloud compute ssh vm-hub-test --zone="$ZONE" --tunnel-through-iap
```

The first time, it says `You do not have an SSH key for gcloud` and offers to create one. Answer `Y`. For the passphrase, press Enter twice (no passphrase) or use one and keep it in a password manager. It may retry once or twice while the key spreads; give it 30 seconds. Then:

```bash
hostname; ip -4 addr show; exit
```

---

## GATE 1: Google side ready, nothing billing yet

- [ ] `gcloud services list --enabled` shows compute, iap, dns, monitoring, secretmanager
- [ ] VPC `vpc-hub` and subnet `10.8.10.0/24` exist
- [ ] Two firewall rules exist
- [ ] You logged into `vm-hub-test` through IAP
- [ ] `GCP_VM_IP` is in your values file

**Cost so far: zero** (the VM is in the free tier).

---

# PHASE 2: BUILD THE GOOGLE END OF THE TUNNEL

📍 **Cloud Shell**. Billing starts at step 2.6.

## 2.1 The Cloud Router

```bash
gcloud compute routers create rt-hub-vpn \
  --network=vpc-hub --region="$REGION" --asn=65001 \
  --description="BGP peer to home lab"
```

### What it is, plainly
The mail room clerk. It speaks BGP with your router, learns your home networks, and **writes them into the VPC's routing table**. It never carries a single packet. Forwarding is done by Google's network fabric on every machine that hosts a VM.

That is why you cannot log into it, cannot see a config, and cannot ping through it. It either learned a route or it did not, and one command tells you which. **Free.**

## 2.2 The HA VPN gateway

```bash
gcloud compute vpn-gateways create ha-vpn-hub --network=vpc-hub --region="$REGION"
```

Google immediately gives it **two** public IPs, one per "interface". Read both:

```bash
gcloud compute vpn-gateways describe ha-vpn-hub --region="$REGION" \
  --format="yaml(name,vpnInterfaces)"
```

Add them to your values file:

```bash
echo "export GCP_VPN_IP0=\"$(gcloud compute vpn-gateways describe ha-vpn-hub --region="$REGION" --format='value(vpnInterfaces[0].ipAddress)')\"" >> ~/.hybrid-lab.env
echo "export GCP_VPN_IP1=\"$(gcloud compute vpn-gateways describe ha-vpn-hub --region="$REGION" --format='value(vpnInterfaces[1].ipAddress)')\"" >> ~/.hybrid-lab.env
source ~/.hybrid-lab.env
echo "interface 0 = [$GCP_VPN_IP0]   interface 1 = [$GCP_VPN_IP1]"
```

> **Never delete this gateway during teardown.** Its two IPs are fixed for its lifetime. Delete it and both addresses change, and you must retype them in six places on OPNsense and five on VyOS. The gateway itself is free; only tunnels cost money.

> **Correction from the original build:** an older guide used `--format='flatten(...)'`. `flatten` is not a valid format and the command fails. Valid choices include `yaml(...)`, `value(...)`, `table(...)`, `get(...)` and `flattened`.

Interface 0 is for OPNsense. Interface 1 is for VyOS later. Both exist already; nothing needs to be "turned on".

## 2.3 Describe your router to Google (peer gateway)

```bash
gcloud compute external-vpn-gateways create peer-home \
  --interfaces 0="$OPNSENSE_WAN_IP" \
  --description="OPNsense at home"
```

This is Google's record of "the thing at the other end". It takes an exact IP, never a name. **Free.**

> The description you type here matters more than it looks. In Phase 9, Terraform discovers that changing this text **forces the whole object to be deleted and recreated**. Type it once and keep it.

## 2.4 Create the pre-shared key, safely

### What you are doing
Generating a long random password and putting it straight into Google's secret safe, without it ever touching a file or your command history.

### Why
- **`-hex`, not `-base64`.** Base64 output contains `+`, `/` and `=`. In the original build, one of those got mangled when pasted into a router console and authentication failed with `MAC mismatched`. Hex is only `0-9a-f`: same strength, nothing to mangle.
- **Secret Manager, not a notepad.** A text file is readable by anything on that machine and one careless `git add` away from public. Secret Manager has access control and logs every read.

### Do this

```bash
openssl rand -hex 24 | tr -d '\n' | \
  gcloud secrets create psk-opnsense --replication-policy=automatic --data-file=-
```

The key went from the random generator directly into the safe. It never appeared on screen.

### You should see

```bash
gcloud secrets versions access latest --secret=psk-opnsense | wc -c
```

`48`.

## 2.5 Billing starts here: create the tunnel

```bash
gcloud compute vpn-tunnels create tun-home-0 \
  --peer-external-gateway=peer-home \
  --peer-external-gateway-interface=0 \
  --region="$REGION" \
  --ike-version=2 \
  --shared-secret="$(gcloud secrets versions access latest --secret=psk-opnsense)" \
  --router=rt-hub-vpn \
  --vpn-gateway=ha-vpn-hub \
  --interface=0
```

The `$(...)` part reads the secret at the moment the command runs. Your shell history records the literal text `$(gcloud secrets ...)`, never the key itself.

Google will warn that one tunnel is not enough for the 99.99% availability promise. That is true and expected for a lab. Real high availability is covered in Part 12.

## 2.6 Give the Cloud Router a "phone line" on the tunnel

```bash
gcloud compute routers add-interface rt-hub-vpn \
  --interface-name=if-tun-home-0 \
  --ip-address=169.254.10.1 --mask-length=30 \
  --vpn-tunnel=tun-home-0 --region="$REGION"

gcloud compute routers add-bgp-peer rt-hub-vpn \
  --peer-name=bgp-home-0 \
  --interface=if-tun-home-0 \
  --peer-ip-address=169.254.10.2 \
  --peer-asn=65002 \
  --region="$REGION" \
  --advertisement-mode=DEFAULT
```

### Why `169.254.x.x/30`
- `169.254.0.0/16` is **link-local**: by definition it never leaves the link it is on. Perfect for a private phone line that must never leak or collide with anything real. Google requires it here.
- `/30` gives exactly **two** usable addresses: one for Google (`.1`), one for you (`.2`).

`DEFAULT` means "announce every subnet in this VPC".

---

## GATE 2: Google is ready and waiting

```bash
gcloud compute vpn-tunnels describe tun-home-0 --region="$REGION" \
  --format="value(status,detailedStatus)"
```

You expect **`FIRST_HANDSHAKE`** or **`NO_INCOMING_PACKETS`**. That is correct: Google is ready and nobody is answering yet.

```bash
gcloud compute routers describe rt-hub-vpn --region="$REGION" \
  --format="yaml(interfaces,bgpPeers)"
```

You should see `169.254.10.1/30` and a peer `169.254.10.2` with ASN `65002`.

**If you stop here, run the teardown in Part 11.** The tunnel is now billing.

---

# PHASE 3: BUILD THE HOME END OF THE TUNNEL (OPNSENSE)

📍 **OPNsense web page** (`https://10.2.10.1`). Keep a Cloud Shell tab open for the final checks.

Have these ready:

| Item | Value |
|---|---|
| Google VPN IP (interface 0) | `echo $GCP_VPN_IP0` in Cloud Shell |
| PSK | `gcloud secrets versions access latest --secret=psk-opnsense; echo` (copy it, then type `clear`) |
| Your tunnel address | `169.254.10.2/30` |
| Google's tunnel address | `169.254.10.1` |
| reqid | `10` |

You will type `<GCP_VPN_IP0>` into **six** fields in this phase: two WAN rules, the PSK remote identifier, the VTI remote address, the connection remote address, and the remote authentication ID.

## 3.1 Let Google's IKE and ESP through the WAN

`Firewall → Rules → WAN → + Add`

**Rule 1: key exchange**

| Field | Value |
|---|---|
| Action | Pass |
| Interface | WAN |
| Direction | in |
| TCP/IP version | IPv4 |
| Protocol | UDP |
| Source | Single host or network: `<GCP_VPN_IP0>/32` |
| Destination | **WAN address** (not "WAN net", which means the whole subnet) |
| Destination port | 500 to 4500 |
| Description | `GCP IKE and NAT-T` |

**Rule 2: encrypted data**: same, but Protocol **ESP**, no ports, description `GCP ESP`.

**Save → Apply changes.**

> **Why only Google's IP?** Your WAN is a real public address. Open UDP 500 to the world and scanners find it within hours.

> **Apply is not optional.** In OPNsense every rule change sits **pending** until you click **Apply changes**. A pending rule looks exactly like an active one. If a change "did nothing", this is the first thing to check.

## 3.2 Turn on IPsec

`VPN → IPsec → Connections` → tick **Enable** at the top → **Apply**.

> In OPNsense 25.7 and later, the old "Tunnel Settings" screen is a legacy plugin. You do not need it. If an internet guide says "Tunnel Settings", it is out of date.

## 3.3 The pre-shared key

`VPN → IPsec → Pre-Shared Keys → + Add`

| Field | Value |
|---|---|
| Local identifier | `<OPNSENSE_WAN_IP>` |
| Remote identifier | `<GCP_VPN_IP0>` |
| Pre-Shared Key | paste from Secret Manager |
| Type | PSK |

**Save.** Then clear your clipboard by copying any other text.

## 3.4 The tunnel interface (VTI)

`VPN → IPsec → Virtual Tunnel Interfaces → + Add`

| Field | Value |
|---|---|
| Enabled | ✓ |
| Description | `GCP-VTI` |
| **Request ID (reqid)** | **`10`** |
| Local address | `<OPNSENSE_WAN_IP>` |
| Remote address | `<GCP_VPN_IP0>` |
| Tunnel local address | `169.254.10.2` |
| Tunnel local mask | `30` |
| Tunnel remote address | `169.254.10.1` |

**Save.**

### Why a VTI exists at all
A routing table can only point at an **interface** or a **next hop**. It cannot point at "an encryption agreement". The VTI is an interface that stands for the tunnel, so the routing table has something to point at. Once it exists, everything you know about routing, MTU and firewalls applies to the tunnel as if it were a cable.

### Why reqid
Something has to glue the encryption agreement to this interface. `reqid` is that glue: the same number on the VTI and on the Child (step 3.6). **Two separate screens, same number, nothing checks it for you.** A mismatch gives you phase 1 up and phase 2 never arriving.

## 3.5 The connection (phase 1)

`VPN → IPsec → Connections → + Add`. Turn on **advanced mode** (switch at the top of the form).

| Field | Value | Why |
|---|---|---|
| Enabled | ✓ | |
| Description | `GCP-HAVPN` | |
| Proposals | `aes256-sha256-modp2048` | AES-256, SHA-256, DH group 14. Universally supported; chosen for compatibility |
| Version | IKEv2 | Google requires IKEv2 for HA VPN |
| MOBIKE | unchecked | Your address never moves |
| Local address | `<OPNSENSE_WAN_IP>` | |
| Remote address | `<GCP_VPN_IP0>` | |
| Unique | Replace | |
| **DPD delay** | **`30`** | See below |

**Save.** The entry expands.

**Local authentication → + Add:** Round 0, Pre-Shared Key, Id `<OPNSENSE_WAN_IP>`.
**Remote authentication → + Add:** Round 0, Pre-Shared Key, Id `<GCP_VPN_IP0>`.

> **DPD delay lives here, DPD action lives on the Child.** DPD is the "are you still there?" heartbeat. The *delay* belongs to the control channel (this screen). The *action* belongs to the data tunnel (next screen). **If the delay is `0` or empty, DPD never runs and the action you set next never fires**, even though both screens look correct.

> **Why not AES-GCM?** It is faster and Google supports it, but every vendor spells it differently. Get the tunnel up with CBC first; optimise later.

## 3.6 The child (phase 2)

Inside the same connection: **Children → + Add**

| Field | Value |
|---|---|
| Enabled | ✓ |
| Description | `GCP-child` |
| **Request ID (reqid)** | **`10`** (must match 3.4) |
| Mode | Tunnel |
| **Policies** | **UNCHECKED** |
| Local network | `0.0.0.0/0` |
| Remote network | `0.0.0.0/0` |
| ESP proposals | `aes256-sha256-modp2048` |
| Start action | `start` |
| **Close action** | **`start`** |
| **DPD action** | **`start`** |

**Save → Apply** on the Connections page.

### Why `0.0.0.0/0` is not "allow everything"
In a route-based tunnel, the tunnel says "I will encrypt whatever arrives at my door". The **routing table** decides what arrives. `0.0.0.0/0` just means the tunnel does not second-guess routing.

### Why `start` and not `trap`, and why there is no "Restart"
OPNsense moved to a newer IPsec engine (swanctl) and renamed the options. The dropdowns offer `none`, `trap`, `start` (and `clear` for DPD). Older guides that say "Restart" are out of date.

`trap` waits for a matching packet to wake the tunnel up. That only works with **Policies** ticked. You unticked Policies, so there is nothing to wake it. With `trap`, the tunnel comes up once and, the first time it drops at 2 a.m., **never comes back**. `start` reconnects immediately.

> ## The most dangerous checkbox in this guide
> If **Policies** is ticked with `0.0.0.0/0` on both sides, OPNsense installs a kernel rule that captures **every packet on the box**, including your browser session to the web page. You lose the GUI instantly.
>
> **Recovery:** Proxmox → VM 400 → Console → option `8` (Shell) → type `configctl ipsec stop`. Then untick Policies.

## 3.7 Make the tunnel a real interface

`Interfaces → Assignments`

At the bottom, pick the new device `ipsec10` from the dropdown and press **+ Add**. It appears as `OPT1`. Click it:

| Field | Value | Why |
|---|---|---|
| Enable | ✓ | |
| Description | `GCPVTI` | |
| IPv4 configuration type | **None** | The address already exists from step 3.4. Adding one here gives the interface two addresses |
| MTU | `1400` | Leaves room for encryption overhead inside a 1500-byte internet path |
| MSS | `1360` | 1400 minus 20 bytes IP header minus 20 bytes TCP header |

**Save → Apply changes.**

> **`+` creates, the pencil edits.** If `ipsec10` is already in the list, use the **pencil** on its row. Pressing `+` while the device dropdown says `vtnet0` creates a second assignment on your WAN card and breaks the WAN.

### Why both MTU and MSS
MTU stops your firewall *sending* oversized packets. But computers decide their own packet size during the TCP handshake, based on **their own** network card, which knows nothing about your tunnel. The mechanism meant to fix that ("path MTU discovery") relies on error messages that are often filtered on the internet. MSS clamping quietly rewrites the size in the handshake so both computers agree on something the tunnel can carry.

The symptom it prevents is the most confusing one in networking: **ping works, file transfers hang.**

## 3.8 Allow traffic that comes out of the tunnel

> ## Read this before creating the rule
> The tunnel interface appears in the menu as `GCPVTI`, but **rules placed on `GCPVTI` do not apply**. Decrypted traffic surfaces on a hidden interface group that OPNsense 25.7+ labels **`IPsec encapsulation`** (older versions said just "IPsec"). All tunnel rules go there.
>
> If you put them on GCPVTI: the tunnel comes up, BGP never does, and you stare at a rule that looks perfect for hours.

1. `Firewall → Rules`. The page opens on **All rules**, which is **view only**.
2. Click the **All rules** dropdown at the top left, and under **Interfaces** choose **IPsec encapsulation**.
3. The page title changes to `Firewall: Rules: IPsec encapsulation`. Now press **+**.

| Field | Value |
|---|---|
| Action | Pass |
| Interface | IPsec encapsulation |
| Direction | in |
| Protocol | any |
| Source / Destination | any / any |
| Description | `TEMP lab allow all over IPsec` |

**Save → Apply changes.** This rule is temporary; Phase 6 replaces it.

> **Do not confuse it with "Automatically generated rules".** In the All rules view there is a row named `IPsec encapsulation` with the description `IPsec in host to host`. OPNsense made that itself. It has a wrench icon and no pencil. Yours appears under **Interface rules** with a pencil and a bin.

---

## GATE 3: The tunnel is up

**OPNsense:** `VPN → IPsec → Status Overview`

| You should see | Meaning |
|---|---|
| `GCP-HAVPN`, IKEv2, **Connected** | Phase 1 done: the two sides trust each other |
| Local ID and local IP identical | No NAT in front of you. Good |
| Child **INSTALLED**, `0.0.0.0/0` both sides | Phase 2 done: data keys exist |
| Bytes counting up | Something (BGP trying to connect) is already using it |

**OPNsense:** `Interfaces → Diagnostics → Ping`

| Field | Value |
|---|---|
| Hostname | `169.254.10.1` |
| Source address | **`GCPVTI`, picked from the dropdown** |

> **`bind: Can't assign requested address`** means you typed an IP into Source that OPNsense does not own. The classic mistake is typing `169.254.10.1`, which is **Google's** address. Pick the interface name from the dropdown and this error cannot happen.

**Cloud Shell:**

```bash
gcloud compute vpn-tunnels describe tun-home-0 --region="$REGION" \
  --format="value(status,detailedStatus)"
```

`ESTABLISHED   Tunnel is up and running.`

### If it does not come up

Read the log: `VPN → IPsec → Log File`. It tells you how far the negotiation got.

| Log says | Meaning | Fix |
|---|---|---|
| Nothing at all | Packets are not arriving | 3.1 rules, then Gate 0 |
| `NO_PROPOSAL_CHOSEN` | Encryption settings differ | 3.5 and 3.6 must both say `aes256-sha256-modp2048` |
| `MAC mismatched` or `AUTHENTICATION_FAILED` | **Only the PSK is wrong** | Re-paste from Secret Manager in 3.3 |
| `no matching peer config found` | Wrong identifier | Local identifier must be your WAN IP |
| Phase 1 up, no child | reqid mismatch | Both 3.4 and 3.6 must say `10` |
| Comes up, drops, never returns | `trap` chosen, or DPD delay `0` | 3.5 and 3.6 |
| You lost the web page | Policies ticked | Console, `configctl ipsec stop` |

---

# PHASE 4: TURN ON BGP (OPNSENSE)

📍 **OPNsense web page**, then **Cloud Shell** to verify.

## 4.1 Install the routing engine

`System → Firmware → Plugins` → find **os-frr** → **+** to install → wait a minute → refresh the browser. A new **Routing** menu appears.

`Routing → General` → **Enable** ✓ → Save.

## 4.2 BGP settings

`Routing → BGP → General`

| Field | Value | Why |
|---|---|---|
| Enable | ✓ | |
| BGP AS Number | `65002` | Your mail room's phone number |
| Router ID | `10.2.10.1` | A stable unique identity; your LAN IP is a good choice |
| Network | `10.2.10.0/24` | **What you announce to Google.** Without this, BGP connects and announces nothing |

> **Enter the exact `/24`, not `10.2.0.0/16`.** This BGP engine only announces a network it can see in its own routing table, and you only have the `/24`. Each new home subnet needs its own Network entry.

**Save.**

## 4.3 The neighbour (Google)

`Routing → BGP → Neighbors → + Add`

| Field | Value | Why |
|---|---|---|
| Enabled | ✓ | |
| Peer-IP | `169.254.10.1` | Google's end of the phone line |
| Remote AS | `65001` | Google's number |
| Update-Source Interface | `GCPVTI` | Call from the tunnel interface |
| **Soft reconfiguration inbound** | **✓** | Keeps a copy of what Google sent *before* your filters. Your best diagnostic in Phase 6 |
| Description | `GCP Cloud Router` | |

**Save → Apply.**

## 4.4 Let BGP through to the firewall itself

BGP is a conversation **with** OPNsense, not traffic passing through it. The temporary allow-all in 3.8 already covers it, but add an explicit rule now so Phase 6 is easier:

`Firewall → Rules → IPsec encapsulation → +`

| Field | Value |
|---|---|
| Action | Pass |
| Protocol | TCP |
| Source | Single host `169.254.10.1` |
| Destination | **This Firewall** |
| Destination port | BGP (179) |
| Description | `BGP from Cloud Router` |

**Save → Apply changes.**

---

## GATE 4: Routes are exchanged

**OPNsense:** `Routing → Diagnostics → BGP` → **summary**. The neighbour `169.254.10.1` must show a **number** under State/PfxRcd, not `Idle`, `Connect` or `Active`. Choose **routes**: `10.8.10.0/24` must be there.

**Cloud Shell:**

```bash
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bgpPeerStatus)"
```

| Field | Expected | Meaning |
|---|---|---|
| `state` | `Established` | The phone call is connected |
| `status` | `UP` | |
| `numLearnedRoutes` | `1` | Google accepted your `10.2.10.0/24` |
| `advertisedRoutes` | `10.8.10.0/24` | What Google sends you |

```bash
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bestRoutes)"
```

`destRange: 10.2.10.0/24` with AS path `65002`.

> **`nextHopOrigin: INCOMPLETE` is normal.** It is a BGP label meaning "this route was imported from somewhere else rather than declared by hand". Google always imports its subnets that way. It is only used as a tie-breaker between two paths to the same network, and you have one path per network, so it never matters. Do not change anything over it.

| If BGP shows | Cause | Fix |
|---|---|---|
| `Idle` | Cannot reach `169.254.10.1` | Gate 3 ping first |
| `Active` / `Connect` looping | TCP 179 blocked, **or rules on GCPVTI instead of IPsec encapsulation** | 3.8 and 4.4 |
| `Established`, `numLearnedRoutes: 0` | You announce nothing | 4.2 Network field |
| Flapping | MTU | Lower the VTI MTU to `1360` and MSS to `1320` |

---

# PHASE 5: PROVE IT WORKS END TO END

📍 **Test computer** (`10.2.10.60`) and the **Google VM** (through Cloud Shell).

## 5.1 Ping both ways

From the test computer:

```bash
ping -c 5 <GCP_VM_IP>
```

From Cloud Shell, log into the VM and ping home:

```bash
gcloud compute ssh vm-hub-test --zone="$ZONE" --tunnel-through-iap
ping -c 5 10.2.10.60
exit
```

| Only this direction fails | Look at |
|---|---|
| Home to Google | The Google firewall rule `hub-allow-from-home`: is the source `10.2.10.0/24`? |
| Google to home | `Routing → Diagnostics → BGP → routes` on OPNsense, and the IPsec encapsulation rules |

## 5.2 Prove the packet size settings

From the test computer:

```bash
ping -M do -s 1372 -c 3 <GCP_VM_IP>    # must succeed: 1372 + 28 header bytes = 1400
ping -M do -s 1450 -c 2 <GCP_VM_IP>    # must fail with "Frag needed" or "Message too long"
```

`-M do` means "do not let anyone split this packet". The first proves a full-size packet fits through the tunnel. The second proves your MTU is actually being enforced.

## 5.3 Optional: a throughput test

> ## Read first
> Traffic through the tunnel costs about USD 0.12 per GB. A 20-second test costs cents. A forgotten one costs tens of dollars per hour. **Always use `-t 20`. Never run it in the background.**

The Google VM has no internet, so it cannot install `iperf3` on its own. Give it internet for two minutes, then take it away:

```bash
gcloud compute instances add-access-config vm-hub-test --zone="$ZONE"
gcloud compute ssh vm-hub-test --zone="$ZONE" --tunnel-through-iap \
  --command="sudo apt-get update && sudo apt-get install -y iperf3 dnsutils"
gcloud compute instances delete-access-config vm-hub-test --zone="$ZONE" \
  --access-config-name="external-nat"
```

**Do not skip the last command.** A public IP on the VM is both a cost and an exposure.

Then: on the VM `iperf3 -s`, on the test computer `iperf3 -c <GCP_VM_IP> -t 20`. If ping works but iperf3 stalls, it is MTU: lower the VTI to MTU `1360` and MSS `1320`.

## 5.4 Optional: hybrid DNS

This part is optional and has more moving pieces than it looks. Skip it on your first pass.

### Home asking Google for names

```bash
gcloud dns policies create hybrid-inbound \
  --networks=vpc-hub --enable-inbound-forwarding \
  --description="Allow on-prem to query GCP internal DNS"

gcloud compute addresses list --filter="purpose=DNS_RESOLVER" \
  --format="table(name,address,region)"
```

Note the address (`10.8.10.x`). On OPNsense: `Services → Unbound DNS → Query Forwarding → + Add`

| Field | Value |
|---|---|
| Domain | `c.<PROJECT_ID>.internal` |
| Server IP | the `10.8.10.x` address above |
| Port | `53` |

> **Correction from the original build:** an older guide forwarded `google.internal`. Google VM names actually look like `vm-hub-test.us-west1-b.c.<PROJECT_ID>.internal`, which is **not** under `google.internal`, so those lookups never reached Google.

If the lookup reaches Google but returns no address, OPNsense's DNS rebinding protection is removing private answers: add `c.<PROJECT_ID>.internal` under `Services → Unbound DNS → Advanced → Private Domains`.

### Google asking home for names

```bash
gcloud dns managed-zones create lab-local \
  --dns-name="lab.home.arpa." \
  --networks=vpc-hub --visibility=private \
  --forwarding-targets=10.2.10.1 \
  --description="Forward lab.home.arpa to OPNsense"
```

`home.arpa` is the domain officially reserved for home networks. Avoid `.local`, which belongs to multicast DNS and causes odd behaviour on some systems.

> ## Three things the original build missed
> Google sends these forwarded queries **from `35.199.192.0/19`**, not from your subnet. For replies to come back:
>
> 1. **Google must announce `35.199.192.0/19` to you** over BGP. Set the BGP peer to custom advertisement (all subnets plus that range). In Terraform, set `advertise_dns_forwarding_range = true`. By `gcloud`:
>    ```bash
>    gcloud compute routers update-bgp-peer rt-hub-vpn --peer-name=bgp-home-0 \
>      --region="$REGION" --advertisement-mode=CUSTOM \
>      --set-advertisement-groups=ALL_SUBNETS \
>      --set-advertisement-ranges=35.199.192.0/19
>    ```
> 2. **Your `FROM-GCP` prefix list (Phase 6) must also permit `35.199.192.0/19`**, or your own filter drops that route.
> 3. **OPNsense must accept DNS from that range:** a Pass rule on IPsec encapsulation for TCP/UDP 53 from `35.199.192.0/19` to This Firewall, and an Allow entry for `35.199.192.0/19` under `Services → Unbound DNS → Access Lists`.

Add a host record so there is something to find: `Services → Unbound DNS → Overrides → Host Overrides`: host `fedora`, domain `lab.home.arpa`, address `10.2.10.60`.

### Test

From the test computer: `dig vm-hub-test.us-west1-b.c.<PROJECT_ID>.internal @10.2.10.1`

From the Google VM (which has no `dig` unless you installed it in 5.3):

```bash
getent hosts fedora.lab.home.arpa
```

`getent` uses the same resolver path as every program on the machine, so it tests exactly what you care about, with nothing to install.

---

## GATE 5: Data path complete

- [ ] Ping works in both directions
- [ ] 1372-byte no-fragment ping passes, 1450 fails
- [ ] (Optional) 20-second iperf3 runs without stalling
- [ ] (Optional) DNS works in both directions

---

# PHASE 6: HARDEN THE OPNSENSE SIDE

📍 **OPNsense web page**, then **Cloud Shell**.

## 6.1 Back up before you touch anything

`System → Configuration → Backups → Download configuration`. **Tick the option to encrypt the file** and use a strong password from your password manager. The file contains your PSK.

OPNsense also keeps its own change history: `System → Configuration → History` lets you see differences and revert a single change. Know where it is before you need it.

## 6.2 Replace allow-all with named rules

`Firewall → Rules → IPsec encapsulation`. Add these, then **disable** the `TEMP lab allow all` rule.

| # | Action | Protocol | Source | Destination | Port | Description |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP | `169.254.10.1` | This Firewall | 179 | BGP from Cloud Router |
| 2 | Pass | ICMP | `10.8.0.0/16` | `10.2.10.0/24` | | Ping **from** GCP |
| 3 | Pass | ICMP | `10.2.10.0/24` | `10.8.0.0/16` | | Ping **to** GCP |
| 4 | Pass | TCP | `10.8.0.0/16` | `10.2.10.0/24` | 22, 80, 443, 5201 | Services **from** GCP |
| 5 | Pass | TCP | `10.2.10.0/24` | `10.8.0.0/16` | 22, 80, 443, 5201 | Services **to** GCP |
| 6 | Block | any | any | any | | Default deny |

**Apply changes**, then immediately test: ping both ways, BGP summary, a short iperf3.

> ## You need one rule per direction that can START a conversation
> A stateful firewall remembers a conversation and lets the **replies** back. It does **not** let the other side **start** a new conversation.
>
> The original guide only had rules 2 and 4. The result was that **both** directions broke:
>
> | Attempt | What happened |
> |---|---|
> | Home to GCP | No rule allows it to leave |
> | GCP to home | The request gets in on rule 2, but the reply is a brand-new flow with no rule |
>
> Rules 3 and 5 are the fix.

## 6.3 Filter what BGP accepts and announces

### Prefix lists

`Routing → BGP → Prefix Lists → + Add`

| Name | Seq | Action | Network |
|---|---|---|---|
| `TO-GCP` | 10 | permit | `10.2.10.0/24` |
| `FROM-GCP` | 10 | permit | `10.8.0.0/16` **with `le 32`** |

> ## The `le 32` is not optional. Leaving it out takes everything down.
> A prefix list matches a network **and its exact length**. `permit 10.8.0.0/16` alone matches only `10.8.0.0/16` itself.
>
> Google never sends `10.8.0.0/16`. Because a Google VPC has no range of its own (Phase 1.4), Google announces each **subnet**: `10.8.10.0/24`. That address is *inside* the `/16` but its length is `/24`, so it does not match.
>
> Every route map ends with an invisible "deny everything else". Nothing matched, so OPNsense received **zero routes from Google**, and **both** directions of traffic died while the tunnel and BGP looked perfectly healthy.
>
> `le 32` means "anything inside `10.8.0.0/16`, at any length from /16 to /32". New Google subnets are then accepted automatically.

How to enter it depends on your plugin version:

1. If the form has a separate **le** field (try advanced mode), set it to `32`.
2. If not, type `10.8.0.0/16 le 32` in the Network field.
3. If that is rejected, add one permit entry per Google subnet instead (`10.8.10.0/24`, and so on).

If you set up hybrid DNS in 5.4, add `FROM-GCP` seq 20 permit `35.199.192.0/19`.

### Route maps

`Routing → BGP → Route Maps → + Add`

| Name | Action | ID | Prefix list |
|---|---|---|---|
| `GCP-IN` | permit | 10 | `FROM-GCP` |
| `GCP-OUT` | permit | 10 | `TO-GCP` |

`Routing → BGP → Neighbors` → edit `169.254.10.1` → Route-Map In `GCP-IN`, Route-Map Out `GCP-OUT` → **Save → Apply**.

### Prove the filter did not eat your routes

This is why you ticked **Soft reconfiguration inbound** in 4.3. `Routing → Diagnostics → BGP`, run:

```
show ip bgp neighbors 169.254.10.1 received-routes
show ip bgp
show ip bgp neighbors 169.254.10.1 advertised-routes
```

| Result | Meaning |
|---|---|
| `received-routes` has `10.8.10.0/24`, `show ip bgp` does too | Filter is correct |
| `received-routes` has it, `show ip bgp` does not | **Your inbound filter is dropping it.** Check `le 32` |
| `received-routes` is empty | Google is not sending. Look at the Google side |
| `advertised-routes` does not list `10.2.10.0/24` | You announce nothing. Check 4.2 and `TO-GCP` |

---

## GATE 6: Hardened and still working

- [ ] Encrypted backup downloaded
- [ ] Allow-all rule disabled, six named rules active, both ping directions work
- [ ] `show ip bgp` contains `10.8.10.0/24` after the route maps are applied
- [ ] Google still reports `numLearnedRoutes: 1`

---

# PHASE 7: GET AN EMAIL WHEN SOMETHING BREAKS

📍 **Google Cloud console → Observability → Monitoring** (on some layouts it sits under **Operations**).

> **Build these while the tunnel is UP.** The metric picker only shows metrics with recent data by default. With the tunnel torn down, `tunnel_established` is invisible and you will think it does not exist. If you must build them while down, untick the **Active** filter in the picker.

## The setting that decides whether this is useful

You delete the tunnel every evening (Part 11). When the tunnel is deleted, its metric does not report `0`; it **stops reporting at all**. Configured the obvious way, that triggers an alert email every night, and within a week you stop reading them.

The fix is one setting: **Missing data: `Missing data empty`**.

| Situation | Metric | With "Missing data empty" |
|---|---|---|
| Tunnel up | reports `1` | quiet |
| Tunnel genuinely down | reports `0` | **alert** |
| Tunnel deleted by your teardown | no data | quiet |

## 7.1 The email channel

`Monitoring → Alerting → Edit notification channels` → **Email → Add new** → your address, display name `Lab email` → Save.

## 7.2 VPN tunnel alert

`Monitoring → Alerting → + Create policy`

| Step | Field | Value |
|---|---|---|
| Select a metric | Metric | `VPN Gateway → Vpn → Tunnel established` (`vpn.googleapis.com/tunnel_established`) |
| Transform data | Rolling window / function | `5 min` / `mean` |
| | Time series aggregation / group by | `min` / `tunnel_name` |
| Configure trigger | Condition type | Threshold |
| | Alert trigger | Any time series violates |
| | **Threshold position** | **Below threshold** |
| | **Threshold value** | **`1`** |
| | Advanced: Retest window | `5 min` |
| | **Advanced: Missing data** | **Missing data empty** |
| Notifications | Channel / autoclose / name | `Lab email` / `30 min` / `VPN tunnel down` |

Grouping by tunnel name means the VyOS tunnel in Phase 8 is covered automatically.

> **A common mistake from the original build:** the form defaulted to **Above** threshold with an empty value. "Above 1" would alert when the tunnel is *healthy*. It must be **Below 1**.

### Check your work with "View Code"

Top right of the policy editor is **View Code**. It shows the policy as JSON, which is the same no matter how Google rearranges the form. Confirm these four lines:

```json
"comparison": "COMPARISON_LT",
"thresholdValue": 1,
"duration": "300s",
"evaluationMissingData": "EVALUATION_MISSING_DATA_INACTIVE"
```

## 7.3 BGP session alert

Same flow, with metric `Cloud Router → BGP session status` (`router.googleapis.com/bgp/session_up`), grouped by `bgp_peer_name`, named `BGP session down`. Every other value identical.

## 7.4 Prove the alert works

An alert you have never seen fire is a guess.

**OPNsense:** `VPN → IPsec → Connections` → untick **Enable** → Apply. Wait 6 to 7 minutes. The email should arrive, and both policy graphs should show the line dropping to `0`. Re-enable and watch the incident close.

> The two graphs dropping and recovering at the same moment is a nice lesson in itself: when the tunnel (layer below) goes, BGP (layer above) goes with it, every time.

---

## GATE 7: Monitoring proven

- [ ] Two policies, both **Below 1**, both **Missing data empty**
- [ ] You received the email from a deliberate break
- [ ] The incident closed on its own after recovery

Monitoring these metrics costs nothing.

---

# PHASE 8: BUILD THE SAME THING AGAIN ON VYOS, IN PARALLEL

📍 **Proxmox**, the **VyOS console**, and **Cloud Shell**.

## Why build it twice

OPNsense is a firewall with a web page. VyOS is a router where the entire configuration is a text file of `set` commands. Building the same tunnel on both, at the same time, against the same Google router, teaches you what is the *protocol* and what is just the *product*.

> **Do not tear down the OPNsense tunnel first.** It is your known-good reference. When VyOS misbehaves, OPNsense working beside it proves the ISP path, the public IP block, and the Google side are all fine, which removes most of the search.

## Do it in three sessions, sorted by cost

| Session | Steps | Google cost |
|---|---|---|
| **1** | 8.1 to Gate 8A: build the VM, install, base config, internet | **$0.00** |
| **2** | 8.6 to 8.8: second secret, firewall rule, peer gateway | **$0.00** |
| **3** | 8.9 to Gate 8D: second tunnel, IPsec, BGP, testing | **~USD 0.10/hr** with both tunnels up |

A careful build costs well under one dollar. Stop at the end of Session 2 if you run out of time; nothing is billing.

## 8.1 Get the right VyOS image

**No, you do not install Ubuntu and then VyOS.** VyOS is a complete operating system with its own installer. Layering it on Ubuntu would throw away the configuration system that makes it worth using.

| Channel | Access | Use it? |
|---|---|---|
| **Stream** | Free, quarterly | **Yes.** A tested snapshot that feeds the next long-term release |
| Rolling / nightly | Free | Only for testing new features. Expect bugs |
| LTS | Subscription, or build it yourself from public source | Production |

Download the **Stream** generic ISO from `https://vyos.net/get/` and verify its signature as the download page describes. Upload it in Proxmox: **local storage → ISO Images → Upload**.

## 8.2 A private lab network for VyOS

**Proxmox → System → Network → Create → Linux Bridge:** name `vmbr3`, **no IP, no ports, not VLAN aware**. Apply.

## 8.3 Create the VM

| Setting | Value |
|---|---|
| VM ID / name | `420` / `vyos-edge` |
| ISO | VyOS Stream |
| Machine / BIOS | `q35` / SeaBIOS |
| Disk | 10 GB, VirtIO Block |
| CPU / RAM | 2 cores / 2048 MB |
| NIC 1 | Bridge `vmbr1` (WAN), VirtIO, **Firewall unchecked** |
| NIC 2 | Bridge `vmbr3` (LAN), VirtIO, **Firewall unchecked** |

The first NIC becomes `eth0` (WAN), the second `eth1` (LAN). Order matters.

## 8.4 Install

1. Start the VM, open the Console. Log in as `vyos` / `vyos`.
2. Type `install image` and answer: continue **Yes**, partition **Auto**, disk **sda**, default sizes, **set a strong password** (save it in your password manager), GRUB on **sda**.
3. `poweroff`. In Proxmox: Hardware → CD/DVD Drive → **Do not use any media**. Start again.
4. Log in with the new password. `show version` should print the Stream version.

## 8.5 The two modes, and your safety net

| Mode | Prompt | You can |
|---|---|---|
| Operational | `vyos@vyos-edge:~$` | `show`, `ping`, `reset`, `restart`, `reboot` |
| Configuration | `vyos@vyos-edge# ` | `set`, `delete`, `compare`, `commit`, `save` |

`configure` enters configuration mode. `exit` leaves it. Inside configuration mode, put `run` in front of an operational command (`run show interfaces`).

> ## `commit` and `save` are two different things
> - **`commit`** makes the change live **now**.
> - **`save`** writes it to disk so it survives a reboot.
>
> Only committing means your work disappears at the next reboot. That sounds like a trap, and it is also your **safety net**: as long as you have not saved, rebooting from the Proxmox console brings back the last saved configuration.
>
> For risky changes (firewall), use **`commit-confirm 10`** instead of `commit`. If you do not type `confirm` within 10 minutes (because you locked yourself out), VyOS reverts by itself. Check what it does on your version with `set system config-management commit-confirm ?`.

> **Correction from the original build:** earlier notes said `rollback 0` undoes the last commit. That is wrong. Revision 0 is the *current* configuration. Use the not-saved-plus-reboot safety net or `commit-confirm` instead, and check `rollback ?` on your version before relying on it.

> ## The habit that would have saved four failures
> When you paste a block of `set` commands, **the last line sometimes goes missing.** VyOS does not warn you, because a half-finished block is still valid syntax. In the original build this silently removed the encryption proposals, then the Diffie-Hellman group, then the BGP `network` line, then part of the firewall.
>
> Before every `commit`, count:
>
> ```
> show configuration commands | match <section-name>
> ```
>
> Each block below tells you the number to expect.

The complete configuration, with placeholders, is in `configs/vyos/vyos-edge.commands.example`. The blocks below come from that file.

## 8.5a Base configuration

```
configure
set system host-name 'vyos-edge'
set system name-server '1.1.1.1'
set system name-server '9.9.9.9'
set system time-zone 'America/Vancouver'

set interfaces ethernet eth0 description 'WAN'
set interfaces ethernet eth0 address '<VYOS_WAN_IP>/29'
set interfaces ethernet eth1 description 'LAB-LAN-VYOS'
set interfaces ethernet eth1 address '10.2.20.1/24'
set protocols static route 0.0.0.0/0 next-hop '<ISP_GATEWAY_IP>'

set service ssh listen-address '10.2.20.1'
set service ssh port '22'

set nat source rule 100 description 'LAN to internet'
set nat source rule 100 outbound-interface name 'eth0'
set nat source rule 100 source address '10.2.20.0/24'
set nat source rule 100 translation address 'masquerade'

set service dhcp-server shared-network-name LAB subnet 10.2.20.0/24 subnet-id '1'
set service dhcp-server shared-network-name LAB subnet 10.2.20.0/24 option default-router '10.2.20.1'
set service dhcp-server shared-network-name LAB subnet 10.2.20.0/24 option name-server '10.2.20.1'
set service dhcp-server shared-network-name LAB subnet 10.2.20.0/24 range POOL start '10.2.20.100'
set service dhcp-server shared-network-name LAB subnet 10.2.20.0/24 range POOL stop '10.2.20.200'

set service dns forwarding listen-address '10.2.20.1'
set service dns forwarding allow-from '10.2.20.0/24'
set service dns forwarding system
commit
save
exit
```

Why each piece:

| Piece | Why |
|---|---|
| SSH listens on the LAN address only | Never expose management on a public interface |
| `outbound-interface name 'eth0'` | The `name` keyword is required from VyOS 1.4. Without it the command is rejected |
| `subnet-id '1'` | Required from 1.4 (new DHCP engine). Leave it out and commit fails |
| DHCP pool `.100` to `.200` | Same rule as OPNsense: static hosts live below `.100` |

## 8.5b A small test host for the VyOS network

No need for a full VM. **Proxmox → Create CT:** ID `450`, hostname `vyos-test`, template `debian-12-standard`, 4 GB disk, 512 MB RAM, bridge `vmbr3`, static `10.2.20.60/24`, gateway `10.2.20.1`, DNS `10.2.20.1`.

---

## GATE 8A: VyOS reaches the internet (Session 1 ends here)

On VyOS: `ping 1.1.1.1 count 3`. On the test container:

```bash
ping -c 3 10.2.20.1
curl -s https://ifconfig.me; echo
```

**Must print `<VYOS_WAN_IP>`.** Anything else means the wrong bridge or VLAN on NIC 1.

---

## 8.6 Session 2 (free): the second secret

📍 **Cloud Shell**

```bash
openssl rand -hex 24 | tr -d '\n' | \
  gcloud secrets create psk-vyos --replication-policy=automatic --data-file=-
```

A **different** key from OPNsense. If one leaks, the other tunnel is unaffected.

## 8.7 Allow the VyOS network into Google

```bash
gcloud compute firewall-rules create hub-allow-from-vyos \
  --network=vpc-hub --direction=INGRESS --priority=1000 --action=ALLOW \
  --rules=icmp,tcp:22,tcp:80,tcp:443,tcp:53,udp:53,tcp:5201 \
  --source-ranges=10.2.20.0/24 \
  --description="Allow VyOS lab LAN over the VPN"
```

Skip this and the tunnel and BGP both come up perfectly while no traffic passes.

## 8.8 Tell Google about VyOS

```bash
gcloud compute external-vpn-gateways create peer-home-vyos \
  --interfaces 0="$VYOS_WAN_IP" \
  --description="VyOS at home"
```

**Stop here if you need to.** Everything so far is free. The next step bills.

---

## 8.9 Session 3: the second tunnel, on interface 1

📍 **Cloud Shell**. If OPNsense's tunnel was torn down, bring it back first (Part 11).

```bash
gcloud compute vpn-tunnels create tun-home-1 \
  --peer-external-gateway=peer-home-vyos \
  --peer-external-gateway-interface=0 \
  --region="$REGION" --ike-version=2 \
  --shared-secret="$(gcloud secrets versions access latest --secret=psk-vyos)" \
  --router=rt-hub-vpn --vpn-gateway=ha-vpn-hub \
  --interface=1

gcloud compute routers add-interface rt-hub-vpn \
  --interface-name=if-tun-home-1 --ip-address=169.254.20.1 --mask-length=30 \
  --vpn-tunnel=tun-home-1 --region="$REGION"

gcloud compute routers add-bgp-peer rt-hub-vpn \
  --peer-name=bgp-home-1 --interface=if-tun-home-1 \
  --peer-ip-address=169.254.20.2 --peer-asn=65003 \
  --region="$REGION" --advertisement-mode=DEFAULT
```

Check the tunnel points at the right place:

```bash
gcloud compute vpn-tunnels list \
  --format="table(name,status,vpnGatewayInterface,peerExternalGateway.basename())"
```

`tun-home-1` must show interface **`1`** and peer **`peer-home-vyos`**. One word away from `peer-home`; if it says that, Google waits for the wrong IP and ignores VyOS forever.

## 8.10 IPsec on VyOS

📍 **VyOS**. Paste through **SSH from the test container** (`ssh vyos@10.2.20.1`) rather than the Proxmox web console. Web console clipboards drop characters, which is exactly the kind of damage a secret cannot survive.

Get the key ready in Cloud Shell, copy it, then clear the screen:

```bash
gcloud secrets versions access latest --secret=psk-vyos; echo
clear
```

### Phase 1: who you are and how you talk (expect **11** lines)

```
configure
set vpn ipsec ike-group GCP-IKE key-exchange 'ikev2'
set vpn ipsec ike-group GCP-IKE lifetime '36000'
set vpn ipsec ike-group GCP-IKE close-action 'start'
set vpn ipsec ike-group GCP-IKE dead-peer-detection action 'restart'
set vpn ipsec ike-group GCP-IKE dead-peer-detection interval '30'
set vpn ipsec ike-group GCP-IKE dead-peer-detection timeout '120'
set vpn ipsec ike-group GCP-IKE proposal 1 dh-group '14'
set vpn ipsec ike-group GCP-IKE proposal 1 encryption 'aes256'
set vpn ipsec ike-group GCP-IKE proposal 1 hash 'sha256'
set vpn ipsec ike-group GCP-IKE proposal 1 prf 'prfsha256'
```

> **`dh-group` is mandatory.** Without a Diffie-Hellman group, phase 1 cannot complete. Google reports `NEGOTIATION_FAILURE` and VyOS's own log says almost nothing useful. VyOS sorts output alphabetically, so `dh-group` should appear **above** `encryption`.

> **One proposal is enough.** Do not add extra proposals "to be safe". They add noise to the log and make it harder to tell an encryption problem from an authentication problem.

### Phase 2: how data is encrypted (expect **6** lines)

```
set vpn ipsec esp-group GCP-ESP lifetime '10800'
set vpn ipsec esp-group GCP-ESP mode 'tunnel'
set vpn ipsec esp-group GCP-ESP pfs 'dh-group14'
set vpn ipsec esp-group GCP-ESP proposal 1 encryption 'aes256'
set vpn ipsec esp-group GCP-ESP proposal 1 hash 'sha256'
```

Phase 1 lives 10 hours, phase 2 lives 3 hours. Data keys change more often to limit what one stolen key could expose.

### The key

```
set vpn ipsec authentication psk GCP id '<VYOS_WAN_IP>'
set vpn ipsec authentication psk GCP id '<GCP_VPN_IP1>'
set vpn ipsec authentication psk GCP secret '<PASTE_THE_48_CHARACTERS>'
```

### The tunnel interface

```
set interfaces vti vti0 address '169.254.20.2/30'
set interfaces vti vti0 description 'GCP HA VPN interface 1'
set interfaces vti vti0 mtu '1400'
set interfaces vti vti0 ip adjust-mss '1360'
```

> **Correction from the original build:** older guides said `set firewall options interface vti0 adjust-mss`. That was removed in VyOS 1.4. MSS clamping is now a property of the interface. When a command is rejected, type the start and press `?`. Tab completion on your box always beats any written guide.

### The peer

```
set vpn ipsec interface 'eth0'
set vpn ipsec site-to-site peer GCP-TUN1 description 'GCP HA VPN tunnel 1'
set vpn ipsec site-to-site peer GCP-TUN1 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer GCP-TUN1 authentication local-id '<VYOS_WAN_IP>'
set vpn ipsec site-to-site peer GCP-TUN1 authentication remote-id '<GCP_VPN_IP1>'
set vpn ipsec site-to-site peer GCP-TUN1 connection-type 'initiate'
set vpn ipsec site-to-site peer GCP-TUN1 ike-group 'GCP-IKE'
set vpn ipsec site-to-site peer GCP-TUN1 local-address '<VYOS_WAN_IP>'
set vpn ipsec site-to-site peer GCP-TUN1 remote-address '<GCP_VPN_IP1>'
set vpn ipsec site-to-site peer GCP-TUN1 vti bind 'vti0'
set vpn ipsec site-to-site peer GCP-TUN1 vti esp-group 'GCP-ESP'
```

`vti bind 'vti0'` is the VyOS version of OPNsense's matching `reqid` numbers. One line, by name, in one place. It cannot be half-configured.

### Count, commit, save

```
show configuration commands | match GCP-IKE
show configuration commands | match GCP-ESP
commit
save
exit
```

11 and 6. Fewer means the paste was short.

---

## GATE 8B: The VyOS tunnel is up

```
show vpn ipsec sa
show interfaces vti
ping 169.254.20.1 count 5
```

`GCP-TUN1-vti` **up** with `AES_CBC_256/HMAC_SHA2_256_128`, `vti0` showing **`u/u`**, ping working. In Cloud Shell, `tun-home-1` should read `ESTABLISHED`.

> ## `A/D` and "Packet filtered" are one problem, not two
> Before the tunnel is up, `show interfaces vti` says `A/D`: Admin up, link Down. A tunnel interface only comes up when its encryption agreement does.
>
> If you ping `169.254.20.1` then, there is no route through the tunnel, so the packet follows the default route out to your ISP, and the ISP router replies `From <ISP_GATEWAY_IP> ... Packet filtered`. That is the ISP correctly refusing to route link-local addresses. **Read the source address in an error:** it tells you the packet left your building.

### If it does not come up: read the log as checkpoints

```
reset vpn ipsec site-to-site peer GCP-TUN1
show log | match charon | tail -40
```

Each line you reach proves everything before it is correct:

| Line you see | It proves |
|---|---|
| `sending packet: from <VYOS_WAN_IP>[500] to <GCP_VPN_IP1>[500]` | VyOS is trying. WAN and `connection-type` are fine |
| `received packet: from <GCP_VPN_IP1>[500]` | Google is answering. The peer gateway and tunnel are right |
| `selected proposal: IKE:AES_CBC_256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048` | **Encryption agreed.** Stop checking phase 1 settings |
| `selected peer config 'GCP-TUN1'` | **Identities matched** |
| `tried 1 shared key ... but MAC mismatched` | **Only the PSK is wrong.** Nothing else |
| `CHILD_SA GCP-TUN1-vti established` | Done |

> ## Why the error says "MAC mismatched" and not "wrong password"
> The key is **never sent**. Each side computes a fingerprint (a MAC) of the conversation using its own copy of the key, and they compare fingerprints. If the fingerprints differ, the gateway knows the keys differ but cannot know why. That is also why Google can never show you the key again: it only keeps a hash. In the original build, a `+` or `/` from a base64 key was mangled in a web console. Switching to a `-hex` key fixed it at once.

Useful commands on VyOS 1.4 and later:

| Purpose | Command |
|---|---|
| Force one tunnel to reconnect | `reset vpn ipsec site-to-site peer GCP-TUN1` |
| Restart the IPsec service | `restart ipsec` (not `restart vpn`, which no longer exists) |
| Watch the log live | `monitor log` |

After a reset, `WARNING: Peer's GCP-TUN1 SAs are not initiated. Nothing to terminate` and `initiate result: success` are both normal. "Success" means VyOS *sent* the request, not that the tunnel is up.

## 8.11 BGP on VyOS (expect **9** lines)

```
configure
set protocols bgp system-as '65003'
set protocols bgp parameters router-id '10.2.20.1'
set protocols bgp parameters log-neighbor-changes
set protocols bgp neighbor 169.254.20.1 remote-as '65001'
set protocols bgp neighbor 169.254.20.1 description 'GCP Cloud Router'
set protocols bgp neighbor 169.254.20.1 address-family ipv4-unicast soft-reconfiguration inbound
set protocols bgp neighbor 169.254.20.1 timers keepalive '20'
set protocols bgp neighbor 169.254.20.1 timers holdtime '60'
set protocols bgp address-family ipv4-unicast network '10.2.20.0/24'
show configuration commands | match 'protocols bgp'
commit
save
exit
```

> ## A BGP session can be "Established" and say nothing
> In the original build the `network` line (the last one) was lost from the paste. The session came up perfectly, received Google's route, and announced **nothing**. Google showed `numLearnedRoutes: 0`, and ping failed both ways.
>
> Worse, VyOS showed "1 prefix sent". It was echoing Google's own `10.8.10.0/24` back, and Google silently threw it away because it saw its own ASN in the path. That automatic loop protection is a benefit of using three different ASNs.
>
> **The session being up proves the phone line works. It does not prove anyone is talking.** This command is the real test:
>
> ```
> show ip bgp neighbors 169.254.20.1 advertised-routes
> ```
>
> Your own `10.2.20.0/24` must be in that list.

---

## GATE 8C: Two routers, three ASNs, one Cloud Router

On VyOS: `show ip bgp summary`, then `show ip bgp`. `10.8.10.0/24` must be there.

In Cloud Shell:

```bash
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bgpPeerStatus)" | grep -E "name:|state:|numLearnedRoutes"
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bestRoutes)" | grep -E "destRange|- 6500"
```

| Peer | ASN | Learned |
|---|---|---|
| `bgp-home-0` | 65002 | `10.2.10.0/24` |
| `bgp-home-1` | 65003 | `10.2.20.0/24` |

## GATE 8D: End to end

```bash
# test container
ping -c 5 <GCP_VM_IP>
ping -M do -s 1372 -c 3 <GCP_VM_IP>
```

```bash
# Google VM
ping -c 5 10.2.20.60
```

If Google to VyOS fails, check `hub-allow-from-vyos` (8.7).

## 8.12 Harden VyOS

### Route filtering

```
configure
set policy prefix-list TO-GCP rule 10 action 'permit'
set policy prefix-list TO-GCP rule 10 prefix '10.2.20.0/24'
set policy prefix-list FROM-GCP rule 10 action 'permit'
set policy prefix-list FROM-GCP rule 10 prefix '10.8.0.0/16'
set policy prefix-list FROM-GCP rule 10 le '32'
set policy route-map GCP-OUT rule 10 action 'permit'
set policy route-map GCP-OUT rule 10 match ip address prefix-list 'TO-GCP'
set policy route-map GCP-IN rule 10 action 'permit'
set policy route-map GCP-IN rule 10 match ip address prefix-list 'FROM-GCP'
set protocols bgp neighbor 169.254.20.1 address-family ipv4-unicast route-map export 'GCP-OUT'
set protocols bgp neighbor 169.254.20.1 address-family ipv4-unicast route-map import 'GCP-IN'
commit
```

Same `le 32` lesson as OPNsense. Check `show ip bgp` still has `10.8.10.0/24`, then `save`.

### Firewall: use `commit-confirm`

VyOS has had **no firewall at all** until now, on purpose: you were debugging IPsec, not rules. Paste the two firewall blocks from `configs/vyos/vyos-edge.commands.example` (input filter and forward filter), put Google's interface 1 address into rules 40 and 41, then:

```
show configuration commands | match firewall
commit-confirm 10
```

The count must be **42**.

Now test everything **within 10 minutes**: SSH still works, the test container reaches the internet, `ping` to the Google VM works both ways, `run show ip bgp summary` is Established. If all pass:

```
confirm
save
```

If you locked yourself out, do nothing; it reverts on its own.

Three details that went wrong in the original build:

| Detail | Correct form |
|---|---|
| Connection state match | `state 'established'` and `state 'related'` as two lines. The older `state established 'enable'` is rejected |
| Return path | Forward rule 30 accepts traffic **arriving on `vti0`**. Rule 20 only covers `eth1`. Without 30, new flows from Google hit the default drop |
| BGP to the router itself | Input rule 50, TCP 179, inbound on `vti0` |

### Optional: SSH keys only

Only after you have added your own public key (`set system login user vyos authentication public-keys ...`), set `set service ssh disable-password-authentication`. In the reverse order you lock yourself out of SSH (the Proxmox console still works).

### Keep the configuration as code

```bash
# from the test container
scp vyos@10.2.20.1:/config/config.boot ./vyos-edge.boot
```

> **That file contains the PSK in plaintext.** It is in `.gitignore` on purpose. What you publish is the placeholder version, `configs/vyos/vyos-edge.commands.example`.

---

# PHASE 9: DESCRIBE THE GOOGLE SIDE AS CODE (TERRAFORM)

📍 **Cloud Shell**. Files are in the `terraform/` folder of the repository that comes with this guide.

## Why bother

Right now, bringing the tunnels back each morning is a dozen commands typed in the right order. Terraform turns the whole Google side into text files and one command. More importantly, it shows you **every place your idea of the setup differs from what is really running**, before anything is changed.

## The one rule of this phase

> **Never apply a plan that says anything other than `0 to destroy`, unless you meant to destroy something.**
>
> In the original build, the first plan wanted to delete and recreate both peer gateways and both tunnels, over a text description and a secret Google will not reveal. Applying it would have dropped both live tunnels for no reason. The plan caught it. Read every plan.

## 9.1 Install Terraform where it survives

Cloud Shell does **not** have Terraform preinstalled, and anything installed outside your home folder is wiped when the session recycles. Install into `~/bin`, and verify the download:

```bash
mkdir -p ~/bin && cd ~/bin
TF_VER="X.Y.Z"   # pick the current release from https://developer.hashicorp.com/terraform/install
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_SHA256SUMS"
grep "linux_amd64.zip" "terraform_${TF_VER}_SHA256SUMS" | sha256sum -c -
unzip -o "terraform_${TF_VER}_linux_amd64.zip" && rm -f terraform_*.zip terraform_*_SHA256SUMS
cd ~
grep -q 'HOME/bin' ~/.bashrc || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
terraform version
```

`sha256sum -c` must print `OK`. If it does not, delete the file and download again. Never run a binary that fails its checksum.

> **Do not run `gcloud auth application-default login` in Cloud Shell.** Cloud Shell is already signed in as you. That command is only for running Terraform on your own laptop or VM.

## 9.2 A safe place for Terraform's state

The state file records everything Terraform manages, **including the PSKs in plaintext**. It must not live on a laptop or in Git.

```bash
gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
  --location="$REGION" \
  --uniform-bucket-level-access \
  --public-access-prevention
gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
```

| Setting | Why |
|---|---|
| Uniform bucket-level access | Permissions come only from IAM, no per-file exceptions |
| Public access prevention | The bucket can never be made public, even by mistake |
| Versioning | A damaged state file can be restored from a previous version |

## 9.3 Prepare the files

```bash
cd ~/hybrid-cloud-lab/terraform        # wherever you cloned the repository
cp backend.hcl.example backend.hcl     # set bucket = your TF_STATE_BUCKET
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

`terraform.tfvars` holds **no secrets**. Fill it with the truth from Google, not from memory:

```bash
gcloud compute instances describe vm-hub-test --zone="$ZONE" --format="yaml(serviceAccounts)"
gcloud compute external-vpn-gateways describe peer-home      --format="value(description,redundancyType)"
gcloud compute external-vpn-gateways describe peer-home-vyos --format="value(description,redundancyType)"
gcloud compute vpn-tunnels list --format="table(name,vpnGatewayInterface)"
```

Every name, every description and the service account must match **character for character**. A trailing space in a description is enough to make Terraform plan a replacement.

The PSKs are read from Secret Manager by name (`psk-opnsense`, `psk-vyos`). **Both secrets must exist before you plan**, even for a tunnel that is not currently enabled. **The secret values must be exactly what your routers use**, because Terraform will use them every time it recreates a tunnel after a teardown.

## 9.4 Start Terraform

```bash
terraform init -backend-config=backend.hcl
terraform validate
```

`Success! The configuration is valid.`

**Commit `.terraform.lock.hcl`.** Terraform creates it to record the exact provider build. An older guide listed it in `.gitignore`; that was wrong.

## 9.5 Path A: you built everything with `gcloud` (import)

Importing tells Terraform "this already exists, adopt it, do not create it". Run each command and read the result before the next:

```bash
P="$PROJECT_ID"; R="$REGION"; Z="$ZONE"

terraform import google_compute_network.vpc_hub              projects/$P/global/networks/vpc-hub
terraform import google_compute_subnetwork.sn_hub_usw1       projects/$P/regions/$R/subnetworks/sn-hub-usw1
terraform import google_compute_firewall.iap_ssh             projects/$P/global/firewalls/hub-allow-iap-ssh
terraform import google_compute_firewall.from_home           projects/$P/global/firewalls/hub-allow-from-home
terraform import google_compute_firewall.from_vyos           projects/$P/global/firewalls/hub-allow-from-vyos
terraform import google_compute_instance.vm_hub_test         projects/$P/zones/$Z/instances/vm-hub-test
terraform import google_compute_router.rt_hub_vpn            projects/$P/regions/$R/routers/rt-hub-vpn
terraform import google_compute_ha_vpn_gateway.ha_vpn_hub    projects/$P/regions/$R/vpnGateways/ha-vpn-hub
terraform import 'google_compute_external_vpn_gateway.peer["opnsense"]' projects/$P/global/externalVpnGateways/peer-home
terraform import 'google_compute_external_vpn_gateway.peer["vyos"]'     projects/$P/global/externalVpnGateways/peer-home-vyos
```

If the tunnels are **up right now**, import them too (if they are torn down, skip this; Terraform will create them):

```bash
terraform import 'google_compute_vpn_tunnel.tun["opnsense"]'       projects/$P/regions/$R/vpnTunnels/tun-home-0
terraform import 'google_compute_router_interface.if_tun["opnsense"]' $P/$R/rt-hub-vpn/if-tun-home-0
terraform import 'google_compute_router_peer.bgp["opnsense"]'      $P/$R/rt-hub-vpn/bgp-home-0
terraform import 'google_compute_vpn_tunnel.tun["vyos"]'           projects/$P/regions/$R/vpnTunnels/tun-home-1
terraform import 'google_compute_router_interface.if_tun["vyos"]'  $P/$R/rt-hub-vpn/if-tun-home-1
terraform import 'google_compute_router_peer.bgp["vyos"]'          $P/$R/rt-hub-vpn/bgp-home-1
```

Two details that trip people up:

- **Single quotes around addresses with `["..."]`.** Without them the shell eats the brackets and you get a confusing parse error.
- **Router interfaces and BGP peers use a short ID** (`project/region/router/name`), not a `projects/...` path.

If you created the Phase 7 alerts by hand, either import them, or let Terraform create its own and then delete the hand-made ones in the console so you do not get every email twice.

> **Migrating from an older version of this Terraform** that used a `psk_versions` variable? Run `terraform state rm 'terraform_data.psk_version'` once before planning. The marker is then created fresh, which does not touch the tunnels. Changing it in place would.

## 9.6 Path B: brand new project (no import)

Create the two secrets (Phase 2.4 and 8.6), fill `terraform.tfvars`, then go straight to 9.7. Terraform builds everything.

## 9.7 Read the plan

```bash
terraform plan -no-color -parallelism=2 | grep -E "will be destroyed|must be replaced|^Plan:"
```

`-parallelism=2` slows Terraform down from 10 simultaneous calls to 2. In Cloud Shell, the default sometimes produces `dial tcp ...:443: connect: connection refused` from the Google API. That error is not about your code; it aborts the plan halfway and gives misleading numbers. Re-run with fewer parallel calls.

When something says **must be replaced**, find out exactly why:

```bash
terraform plan -no-color -parallelism=2 | grep -B6 "forces replacement"
```

That prints the attribute. **Then change the code to match reality. Never change reality to match the code.**

### Every difference found in the original import, and what it means

| Plan shows | Meaning | Right response |
|---|---|---|
| Prompt `var.home_public_ip ... Enter a value` | A variable is declared in `variables.tf` but never set or used | Press Ctrl+C. Delete the leftover variable |
| `description ... # forces replacement` on a peer gateway | On **this** resource type, description cannot be edited, only replaced. On most resources it can | Copy the exact description from `gcloud` into tfvars |
| `redundancy_type` missing or different | Also cannot be edited | Copy it from `gcloud` |
| `+ shared_secret = (sensitive value) # forces replacement` | Google never returns the PSK, so after import Terraform holds nothing to compare | Already handled: `ignore_changes` in `main.tf` |
| `~ router = "https://www.googleapis.com/..." -> "projects/..."` | Same value written two ways | Already handled: `.self_link` in `main.tf` |
| `- service_account { ... } -> null` on the VM | You did not declare it, so Terraform plans to **remove** it | Already handled: declared from tfvars |
| `advertised_route_priority 0 -> 100` | Never set by `gcloud`, so Google stored 0 | Safe. Only matters when two paths compete for the same network |
| `goog-terraform-provisioned = "true"` labels added | Terraform tags what it manages | Safe |
| `terraform_data.psk_version` will be created | A marker that only lives in state | Safe. No call to Google |

> **The general rule behind all of these:** anything you did not specify when you built by hand, Google filled in with a default. Terraform treats your files as the truth and plans to remove whatever they do not mention. Import, plan, read every line, write reality into the files, plan again.

### Why the PSK handling is not a security shortcut

`ignore_changes = [shared_secret]` sounds like "stop checking the password". It is not:

| Question | Answer |
|---|---|
| Is the key any weaker? | No |
| Is it stored differently? | No, it is in the state file either way, which is why the state lives in a locked bucket |
| Could Terraform ever have detected a changed key? | No. Google only returns a hash |

What the setting prevents is a plan that permanently shows "destroy 2 tunnels". A warning that always fires is a warning nobody reads, and that is the real risk.

**Rotating a key is still deliberate and safe:** add a new version of the secret, set the same value on the router, then `terraform apply`. The new version number changes the marker, which replaces exactly that one tunnel.

```bash
openssl rand -hex 24 | tr -d '\n' | gcloud secrets versions add psk-vyos --data-file=-
```

## 9.8 Apply, then the milestone

When the plan shows `0 to destroy`:

```bash
terraform apply -parallelism=2
```

Read the summary at the prompt before typing `yes`. Then confirm nothing was rebuilt:

```bash
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bgpPeerStatus)" | grep -E "name:|state:|uptime:"
```

Uptime should keep counting, not reset to seconds. Then:

```bash
terraform plan -parallelism=2
```

```
No changes. Your infrastructure matches the configuration.
```

**That line is the whole point of this phase.** Your files now provably describe what is running.

---

# PHASE 10: PUBLISH TO GITHUB SAFELY

📍 **Your own computer** or Cloud Shell, plus the **GitHub website**.

## 10.1 Your private denylist

Make a file **outside** the repository listing every real value that must never be published, one pattern per line:

```bash
cat > ~/.hybrid-lab-denylist <<'EOF'
your-real-project-id
203\.0\.113\.13
your-real-switch-hostname
EOF
chmod 600 ~/.hybrid-lab-denylist
```

Replace the examples with your real public IPs, project ID, billing ID, hostnames and email. The patterns themselves never enter the repository, so publishing the check does not publish what it checks for.

## 10.2 Hooks that block a bad commit

```bash
cd ~/hybrid-cloud-lab
git init
pip install --user pre-commit
pre-commit install
pre-commit run --all-files
```

This runs **gitleaks** (finds anything that looks like a key or password) and the local **denylist** check on every commit. If either finds something, the commit is refused.

Test that it actually blocks:

```bash
head -1 ~/.hybrid-lab-denylist > leak-test.txt
git add leak-test.txt && git commit -m "test"     # must be BLOCKED
git rm --cached leak-test.txt && rm leak-test.txt
```

## 10.3 What gets committed and what never does

| Commit | Never commit |
|---|---|
| `*.tf`, `.terraform.lock.hcl` | `terraform.tfvars`, `backend.hcl` |
| `*.example` files | `*.tfstate`, `*.tfplan`, `.terraform/` |
| `.gitignore`, `.pre-commit-config.yaml` | `~/.hybrid-lab.env`, any `.env` |
| `configs/vyos/vyos-edge.commands.example` | `config.boot`, OPNsense XML backups |
| `docs/` | Anything containing a PSK |

Before the first commit, look with your own eyes:

```bash
git add .
git status
git diff --cached --stat
```

## 10.4 Create the repository

```bash
git commit -m "Hybrid cloud lab: route-based IPsec with eBGP to GCP, OPNsense and VyOS"
git branch -M main
gh repo create hybrid-cloud-lab --public --source=. --remote=origin --push
```

Then, on GitHub, **Settings**:

| Setting | Value | Why |
|---|---|---|
| Code security → Secret scanning | On | GitHub scans every push |
| Code security → Push protection | On | Blocks a push that contains a known secret format |
| Code security → Dependabot alerts | On | Warns about vulnerable dependencies and actions |
| Actions → General → Workflow permissions | **Read repository contents** | Least privilege for every workflow |
| Actions → General → Fork pull request workflows | Require approval | Strangers cannot run your workflows |
| Branches → protect `main` | Require a pull request and the `terraform-plan` check | No direct pushes |

## 10.5 Optional: plan on every pull request, with no stored keys

The workflow in `.github/workflows/terraform-plan.yml` is built to be safe in a public repository:

| Protection | How |
|---|---|
| No permissions unless asked | `permissions: {}` at the top, then only `contents: read` and `id-token: write` for the job |
| No long-lived keys | Workload Identity Federation: GitHub proves who it is, Google hands out a short-lived token |
| No stolen-action risk | Every third-party action pinned to a full commit SHA, with the version in a comment |
| No script injection | Values reach scripts through `env:`, never pasted into `run:` with `${{ }}` |
| No fork access | The job does not run for pull requests from forks |
| No leaked details | Only the `Plan:` summary line is printed, because public repo logs are public |
| Plan only | It never applies |

Create the identity Google will trust (replace `OWNER/REPO`):

```bash
gcloud iam workload-identity-pools create github --location=global --display-name="GitHub"

gcloud iam workload-identity-pools providers create-oidc github-repo \
  --location=global --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='OWNER/REPO'"

gcloud iam service-accounts create tf-plan --display-name="Terraform plan (CI)"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
gcloud iam service-accounts add-iam-policy-binding "tf-plan@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/OWNER/REPO"
```

Give it **read-only** access, and only to what a plan needs:

```bash
SA="serviceAccount:tf-plan@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role=roles/compute.viewer
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$SA" --role=roles/monitoring.viewer
gcloud storage buckets add-iam-policy-binding "gs://${TF_STATE_BUCKET}" --member="$SA" --role=roles/storage.objectViewer
for s in psk-opnsense psk-vyos; do
  gcloud secrets add-iam-policy-binding "$s" --member="$SA" --role=roles/secretmanager.secretAccessor
done
```

> **Honest trade-off:** a plan has to read the PSKs, so this identity can read them. That is why the provider only trusts **your** repository, forks are excluded, and only people with write access can open pull requests that run it. For a public repo with collaborators, consider running plans only on a private mirror.

In the repository, **Settings → Secrets and variables → Actions → Variables** (not Secrets; none of these are secret):

| Variable | Value |
|---|---|
| `WIF_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github/providers/github-repo` |
| `WIF_SERVICE_ACCOUNT` | `tf-plan@<PROJECT_ID>.iam.gserviceaccount.com` |
| `PROJECT_ID`, `TF_STATE_BUCKET`, `ALERT_EMAIL` | your values |
| `TERRAFORM_VERSION` | exactly what `terraform version` prints |
| `TF_TUNNELS_JSON`, `TF_VM_SERVICE_ACCOUNT_JSON` | the tfvars maps written as JSON |
| `TF_ENABLED_TUNNELS_JSON` | e.g. `["opnsense","vyos"]` |

---

# PART 11: DAILY OPERATIONS

📍 **Cloud Shell**

## End of every session (stops tunnel billing)

```bash
cd ~/hybrid-cloud-lab/terraform
terraform apply -var='enabled_tunnels=[]' -parallelism=2
gcloud compute instances stop vm-hub-test --zone="$ZONE" --quiet
gcloud compute vpn-tunnels list
```

An empty tunnel list means tunnel billing has stopped. Nothing changes on OPNsense or VyOS; they keep trying to reconnect, which is harmless.

## Start of a session

```bash
source ~/.bashrc
echo "PROJECT=[$PROJECT_ID] REGION=[$REGION]"
cd ~/hybrid-cloud-lab/terraform
terraform apply -parallelism=2           # uses enabled_tunnels from terraform.tfvars
gcloud compute instances start vm-hub-test --zone="$ZONE" --quiet
```

The routers reconnect on their own within two or three minutes, because both are set to start the connection themselves. Check:

```bash
gcloud compute vpn-tunnels list --format="table(name,status)"
gcloud compute routers get-status rt-hub-vpn --region="$REGION" \
  --format="yaml(result.bgpPeerStatus)" | grep -E "name:|state:|numLearnedRoutes"
```

## What to keep and what to delete

| Resource | At teardown | Why |
|---|---|---|
| Tunnels, router interfaces, BGP peers | **Delete** | The only real cost |
| `vm-hub-test` | **Stop** | Stops compute use |
| **HA VPN gateway** | **Keep** | Deleting it changes both public IPs, and you retype them in eleven places |
| Peer gateways, Cloud Router, VPC, firewall rules | Keep | Free |
| Secrets | Keep | The routers still use those values |

## Without Terraform (gcloud fallback)

```bash
for i in 0 1; do
  gcloud compute routers remove-bgp-peer  rt-hub-vpn --peer-name=bgp-home-$i      --region="$REGION" --quiet
  gcloud compute routers remove-interface rt-hub-vpn --interface-name=if-tun-home-$i --region="$REGION" --quiet
  gcloud compute vpn-tunnels delete tun-home-$i --region="$REGION" --quiet
done
```

Order matters: BGP peer first, then interface, then tunnel. Each depends on the one after it.

## Delete the whole lab

```bash
gcloud projects delete "$PROJECT_ID"
```

This is why the lab has its own project.

## Cost check

| Situation | Approximate cost |
|---|---|
| One tunnel, one hour | USD 0.05 |
| Both tunnels, one evening (4 h) | USD 0.40 |
| Five days with nightly teardown | USD 3 to 5 |
| Forgot both tunnels for a month | about USD 72 |
| iperf3 left running for an hour at 1 Gbps | about USD 54 |

Look at **Billing → Reports**, filtered to this project, at the end of each day. It takes thirty seconds.

---

# PART 12: LAB VERSUS PRODUCTION

Know where this lab is deliberately simplified. Being able to say this unprompted is worth as much as having built it.

> ## This lab is not a high-availability design
> Two routers on two **separate** networks give you two independent connections, not redundancy. If OPNsense fails, `10.2.10.0/24` loses connectivity and VyOS cannot help. You also used HA VPN interface 0 for one router and interface 1 for the other, which is not what the two interfaces are for.

| Lab choice | Production would |
|---|---|
| One tunnel per router | Two tunnels per router, one to each HA VPN interface (the 99.99% design) |
| Two routers, two networks | One network, a shared virtual gateway (VRRP/CARP), both routers announcing the same prefix with different priorities (MED) |
| DPD only (30 s detection) | Add **BFD** for sub-second failure detection; Cloud Router supports it |
| No BGP authentication | Enable **MD5 authentication** on every BGP session (must match on both ends) |
| `advertisement-mode=DEFAULT` | `CUSTOM` with an explicit list, so another team's new subnet is not announced to your WAN by accident |
| Default Compute service account on the VM | A dedicated service account with only the roles the workload needs |
| VM without Shielded VM or OS Login | Shielded VM (secure boot) and OS Login for IAM-controlled SSH |
| Single region | Cloud Routers and gateways in more than one region |
| Tunnel health from the control plane only | Also test the data path (a probe pinging through the tunnel). DPD can say healthy while no data passes |
| Allow lists by address range | Also tag-based firewall rules and hierarchical policies |

---

# PART 13: TROUBLESHOOTING, BY SYMPTOM

Start in the middle of the stack: **is the phase 2 child up?** If yes, everything below it is fine; look up. If no, everything above it is meaningless; look down. Three checks find any layer.

```
1  Switch / VLAN      show mac address-table vlan <ISP_VLAN>
2  IP to ISP          ping <ISP_GATEWAY_IP> from WAN
3  IKE (phase 1)      IPsec status overview / show vpn ipsec sa
4  CHILD (phase 2)    "INSTALLED" / "up"
5  VTI link           show interfaces vti  (u/u)
6  BGP session        BGP summary: a number, not Idle/Active
7  Routes             advertised-routes and received-routes
8  Forwarding         ping from a lab host
```

| Symptom | Layer | Most likely cause |
|---|---|---|
| `could not parse resource []` | Shell | A variable is empty. `source ~/.bashrc` |
| `Format must be one of ... received [flatten]` | Shell | Use `yaml(...)`, `value(...)` or `table(...)` |
| `Network is unreachable` from `apt` on the Google VM | Design | The VM has no internet. Expected (5.3) |
| `dig: command not found` on the Google VM | Design | Use `getent hosts <name>` |
| Firewall cannot ping the ISP gateway | 1 | VLAN path. Section 0.1 |
| No IKE log entries | 2 | WAN rules (3.1), or packets not arriving |
| `NO_PROPOSAL_CHOSEN` | 3 | Proposals differ |
| Google says `NEGOTIATION_FAILURE`, VyOS log says little | 3 | `dh-group` missing (8.10) |
| `MAC mismatched` / `AUTH_FAILED` | 3 | **Only** the PSK differs. Re-read it from Secret Manager |
| `no matching peer config found` | 3 | Local identifier is not your WAN IP |
| Phase 1 up, no phase 2 | 4 | reqid differs between VTI and Child |
| Tunnel drops and never returns | 4 | `trap` instead of `start`, or DPD delay `0` |
| Lost the OPNsense web page right after Apply | 4 | **Policies** ticked. Console, `configctl ipsec stop` |
| VTI `A/D`, ping says "Packet filtered" from the ISP | 5 | Same fault as phase 2 down. Fix the tunnel |
| `bind: Can't assign requested address` | 5 | Typed an address you do not own as ping source. Pick the interface |
| BGP `Active` looping | 6 | Rules on GCPVTI instead of **IPsec encapsulation**, or TCP 179 blocked |
| BGP up, Google `numLearnedRoutes: 0` | 7 | Your Network / `network` line is missing |
| BGP up, `show ip bgp` empty after adding route maps | 7 | `le 32` missing on `FROM-GCP` |
| Both directions dead after firewall hardening | 8 | Missing return-direction rules (6.2 rules 3 and 5, VyOS forward rule 30) |
| A rule change did nothing | 8 | OPNsense: you did not click **Apply changes** |
| Ping works, transfers hang | 8 | MTU / MSS |
| Alert email every night | Monitoring | **Missing data empty** not set |
| Alert fires while healthy | Monitoring | Threshold is **Above** instead of **Below** |
| Plan wants to destroy something you did not touch | Terraform | `grep -B6 "forces replacement"`, then copy reality into tfvars |
| `connection refused` during plan | Terraform | API hiccup. Re-run with `-parallelism=2` |
| Terraform asks you to type a value | Terraform | A leftover variable in `variables.tf` |
| Cisco log shows the ISP port going down and up | ISP | The circuit flapped. Not a configuration problem |

---

# PART 14: EVERY CORRECTION, IN ONE PLACE

If you ever find an older copy of the build notes, this list tells you what changed and why.

| # | Older instruction | Correct | Why |
|---|---|---|---|
| 1 | Cloud subnet in `172.31.x` or `10.100.x` | `10.8.10.0/24` | AWS default range; collided with the management network |
| 2 | `--format='flatten(...)'` | `yaml(...)` / `value(...)` | `flatten` is not a format |
| 3 | Values pasted into each new shell | `~/.hybrid-lab.env` loaded from `.bashrc` | Cloud Shell forgets `export` on timeout |
| 4 | Test VM at `.100` | `.60` | Collides with the DHCP pool |
| 5 | Child close/DPD action "Restart" | `start` | Renamed in swanctl; `trap` cannot work without Policies |
| 6 | No DPD delay on the Connection | `30` | With `0`, DPD never runs |
| 7 | Tunnel rules on GCPVTI | **IPsec encapsulation** | VTI rules do not apply |
| 8 | Firewall table with GCP-to-home rules only | Rules for both directions | Stateful rules do not allow the other side to start |
| 9 | `FROM-GCP` permit `10.8.0.0/16` | `... le 32` | Google sends `/24`s; exact match failed, everything denied |
| 10 | No soft reconfiguration | Enabled | Needed to see what a filter removed |
| 11 | PSK from `openssl rand -base64` | `-hex` | `+ / =` mangled in a console: `MAC mismatched` |
| 12 | PSK in notepad / tfvars | Secret Manager | Plaintext secret on disk |
| 13 | `.terraform.lock.hcl` ignored | Committed | Pins the exact provider build |
| 14 | `set firewall options interface vti0 adjust-mss` | `set interfaces vti vti0 ip adjust-mss` | Changed in VyOS 1.4 |
| 15 | `restart vpn`, `reset vpn ipsec-peer` | `restart ipsec`, `reset vpn ipsec site-to-site peer` | Changed in VyOS 1.4 |
| 16 | `state established 'enable'` | `state 'established'` | Changed syntax |
| 17 | No forward rule for traffic from the tunnel | Forward rule 30 on `vti0` | Return path |
| 18 | "`rollback 0` undoes the last commit" | Not saving + reboot, or `commit-confirm` | Revision 0 is the current config |
| 19 | "OPNsense can only recover from a full XML restore" | `System → Configuration → History` reverts single changes | OPNsense keeps a change history |
| 20 | BGP block "10 lines", firewall block "30 lines" | 9 and 42 | Miscounted |
| 21 | DNS forward domain `google.internal` | `c.<PROJECT_ID>.internal` | VM names live there |
| 22 | DNS from Google to home "just works" | Needs `35.199.192.0/19` advertised, permitted and allowed | That is where Google's forwarded queries come from |
| 23 | Terraform preinstalled in Cloud Shell | Install to `~/bin`, verify checksum | It is not, and `/usr` is wiped |
| 24 | `description` generated in Terraform | Copied exactly from Google | Forces replacement on peer gateways |
| 25 | `shared_secret` compared by Terraform | `ignore_changes` + replacement tied to the secret version | Google returns only a hash |
| 26 | References with `.id` | `.self_link` | Removes a permanent cosmetic diff |
| 27 | VM service account not declared | Declared | Otherwise Terraform removes it |
| 28 | Alerts with default "Missing data" | **Missing data empty** | Otherwise teardown fires nightly alerts |
| 29 | CI prints full plan | Summary line only | Public repo logs are public |
| 30 | Install VyOS on Ubuntu, nightly image | VyOS's own installer, **Stream** image | VyOS is a full OS; Stream is the stable free channel |

---

## The three habits that matter most

1. **Pass every gate before moving on.** Symptoms appear in a different layer from their cause.
2. **Ask the tool, not your memory.** `show log | match charon`, `grep "forces replacement"`, `advertised-routes`, and `?` tab completion each ended a guessing game in one command.
3. **Count before you commit, and read before you apply.** Four failures came from a short paste, and one plan would have deleted two live tunnels.
