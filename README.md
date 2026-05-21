# NAGIOS

## Description

This project is designed to .... and the main features are ...

## Getting Started

### Prerequisites

List all dependencies and their version needed to run the project as :

|Role|Tool|Version|
|:--|:--|:--|
|VCS|Git SCM|[2.54 or higher](https://git-scm.com/install/)|
|IaC|Terraform|[1.15 or higher](https://developer.hashicorp.com/terraform/install)|
|IDE|VS Code|[1.118 or higher](https://code.visualstudio.com/thank-you?dv=linux64_deb)|
|Virtualization|Docker Engine|[v29 or higher](https://docs.docker.com/engine/install/)|

### Configuration

* Cloud Provider Credentials

You will need acces to the cloud provider including this following permissions:

```
         "ec2:DescribeInstances", 
         "ec2:DescribeImages",
         "ec2:DescribeTags", 
         "ec2:DescribeSnapshots"
```

* Licence

A licence need to be requested to info@myproduct.com.


## Deployment

### On dev environment

* Set the environments variables

```
cp sample.env dev.env
```

Update all variable according to your setup.


### On stage environment

* Set the environments variables

```
cp sample.env stage.env
```

Update all variable according to your setup.

## Directory structure

Here you are a sample of project structure. It's must be adapted to your stack.

```shell
project-root/
├── README.md
├── .env.example              # environment variables template

├── config/                   # configuration (per environment)
│   ├── dev.env
│   ├── staging.env
│   └── prod.env

├── bin/                      # entrypoints (what you actually run)
│   ├── deploy.sh
│   ├── destroy.sh
│   └── status.sh

├── lib/                      # shared logic (like "modules")
│   ├── log.sh
│   ├── utils.sh
│   ├── checks.sh             # preflight checks
│   └── state.sh              # poor man's state management

├── services/                 # components of your stack
│   ├── network/
│   │   ├── create.sh
│   │   └── destroy.sh
│   │
│   ├── compute/
│   │   ├── create.sh
│   │   └── destroy.sh
│   │
│   ├── monitoring/
│   │   ├── prometheus.sh
│   │   ├── grafana.sh
│   │   └── alertmanager.sh
│   │
│   └── security/
│       ├── iam.sh
│       └── secrets.sh

├── state/                    # local state tracking
│   └── deployed.json

├── scripts/                  # helpers (optional)
│   ├── install_deps.sh
│   └── lint.sh

└── logs/
    └── deploy.log
```

## Collaborate

* How to propose a new feature (issue, pull request)
* [How to commit](https://www.conventionalcommits.org/en/v1.0.0/)
* [How to use your workflow](https://nvie.com/posts/a-successful-git-branching-model/)

## License

* [Choose the license adapted to your project](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

## Contact

* How to get in contact with you? Discord, Trello, Issue?
