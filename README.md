# Nagios XI — Infrastructure Monitoring
 
## Description
 
This project automates the deployment of Nagios XI as an infrastructure monitoring solution on AWS. It provides automated installation, Discord alerting integration, and environment-based configuration management. The main features are automated Nagios XI setup on Ubuntu 24.04, configurable HTTP/HTTPS ports, Discord webhook notifications, and license key injection.
 
## Getting Started
 
### Prerequisites
 
| Role | Tool | Version |
|------|------|---------|
| VCS | Git SCM | 2.40 or higher |
| Runtime | Ubuntu | 24.04 LTS |
| Monitoring | Nagios XI | 2026r1 or higher |
| Agent | NCPA | 3.4 or higher |
  
#### Licence
 
A Nagios XI licence must be requested at [nagios.com](https://www.nagios.com/contact-us/).
 
#### Environment Variables
 
```bash
cp config/nagios.env.example config/nagios.env
chmod 600 config/nagios.env
```
 
Update all variables according to your setup. See `config/nagios.env.example` for the full list of available variables.
 
## Deployment
 
### Nagios XI Installation
 
```bash
cd scripts/
bash script_install_nagiosxi.sh
```
 
### Discord Notifications
 
```bash
cd scripts/
bash install_discord_notify.sh
```
 
Requires `DISCORD_WEBHOOK_URL` to be set in your `nagios.env`.
 
## Directory Structure
 
```
project-root/
├── README.md
├── config/
│   └── nagios.env.example       # environment variables template
└── scripts/
    ├── script_install_nagiosxi.sh   # automated Nagios XI install
    ├── install_discord_notify.sh    # Discord alerting setup
    └── discord_curl.sh              # Discord webhook helper
```
 
## Collaborate
 
### New Feature
 
Open an issue with the `enhancement` label, then submit a pull request referencing it.
 
### Commit Convention
 
```
type: short description
 
types: feat, fix, chore, docs, refactor
```
 
### Workflow
 
- Branch from `main`
- Branch naming: `feat/short-description` or `fix/short-description`
- PR requires at least one review before merge

### Repository license

The repository is under the MIT license. 

