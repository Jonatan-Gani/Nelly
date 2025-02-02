# Nelly: Automated Python Script Deployment System

## Overview

Nelly is a robust, containerized system designed to automate the deployment and execution of scheduled Python scripts. It dynamically fetches applications from GitHub, manages environment configurations, and allows modular library installation. With its configuration-driven architecture, Nelly ensures flexibility, scalability, and minimal manual intervention.

## Why Use Nelly?

- **Zero Hassle Deployment**: Automatically fetches and updates applications from GitHub.
- **Fully Configurable**: Environment settings, networking, and application parameters are managed via `config.json`.
- **Multi-App Support**: Runs multiple applications seamlessly within Docker containers.
- **Automated Execution**: Scheduled Python script execution through Cron jobs.
- **Modular & Scalable**: Define necessary dependencies, environment variables, and networking for each application.
- **Self-Maintaining**: Log management and update mechanisms keep the system clean and optimized.

---

## Project Structure

```
Nelly
├── containers
│   └── template
│       ├── apps                 # Applications fetched from GitHub
│       ├── def
│       │   ├── config.json       # Per-application container settings
│       │   ├── cron              # Cron job definitions for scheduled tasks
│       │   └── Dockerfile        # Defines the containerized environment
│       ├── logs                  # Stores execution logs
│       ├── update_scripts        # Container management scripts
│       │   ├── build_docker.sh   # Builds the Docker container
│       │   ├── config_mng.sh     # Manages configuration settings
│       │   ├── log_cleanup.sh    # Cleans up log files
│       │   ├── manage_docker.sh  # Manages running containers
│       │   └── update_app.sh     # Updates applications inside containers
│       └── update.sh             # Master update script
└── Nelly_config.json              # Global system configuration
```

---

## Configuration: The Core of Nelly

### \*\*Global System Configuration (`Nelly_config.json`)

This file stores system-wide settings, such as the local network IP address:

```json
{
  "LOCAL_IP": "192.168.10.251"
}
```

### \*\*Per-Application Configuration (`config.json`)

Each application has its own `config.json`, defining:

- **Container settings**: `container_name`, `image_name`
- **Application details**: `git_url` (GitHub repo), `branch`
- **Environment variables**: Custom settings per application
- **Networking**: Static IP, network name, and Docker options
- **Dependencies**: List of required system packages

Example `config.json`:

```json
{
  "nelly_config": {
    "LOCAL_IP": "192.168.10.251"
  },
  "container_name": "tamar_template",
  "image_name": "test_image",
  "apps": [
    {
      "app_name": "tamar_template",
      "git_url": "git@github.com:Jonatan-Gani/tamar_template.git",
      "branch": "master",
      "env": {
        "DB_HOST": "ENV_DB_HOST_tamar_template",
        "DB_PASS": "ENV_DB_PASS_tamar_template"
      }
    }
  ],
  "network": {
    "network_name": "Nelly_Network",
    "static_ip": "192.168.20.100",
    "docker_run_options": "-p 8080:80"
  },
  "packages": [
    "cron",
    "python3-pip",
    "git",
    "libpq-dev",
    "gcc",
    "nano",
    "bash",
    "iputils-ping"
  ]
}
```

---

## Installation & Setup

### **Prerequisites**

- Debian-based Linux system (e.g., Ubuntu, Raspberry Pi OS)
- Installed: Docker & Docker Compose

### **Installation Steps**

1. **Clone the Repository**

   ```sh
   git clone <your-repo-url>
   cd Nelly
   ```

2. **Set Up an Application**

   - Copy `containers/template/` and rename it to your application name.
   - Modify `config.json` to set container details, Git repository, environment variables, and dependencies.

3. **Build the Docker Container**

   ```sh
   ./containers/<your-app-folder>/update_scripts/build_docker.sh
   ```

4. **Start and Manage Containers**

   ```sh
   ./containers/<your-app-folder>/update_scripts/manage_docker.sh
   ```

5. **Schedule Cron Jobs** (Ensures periodic script execution)

   ```sh
   crontab containers/<your-app-folder>/def/cron
   ```

6. **Update Applications**

   ```sh
   ./containers/<your-app-folder>/update.sh
   ```

---

## Logging & Maintenance

Logs are stored in `containers/<your-app-folder>/logs/` and track execution details:

- `build_docker.log`
- `log_cleanup.log`
- `manage_docker.log`
- `mng_config.log`
- `update_app.log`
- `update_logs.log`

To clean logs:

```sh
./containers/<your-app-folder>/update_scripts/log_cleanup.sh
```

---

## Updating the System

To fetch the latest application updates and dependencies:

```sh
./containers/<your-app-folder>/update.sh
```

---

## Frequently Asked Questions

### **1. How do I deploy multiple applications?**

- Simply copy the `template` folder, rename it, and modify `config.json` to suit your application.

### **2. How does Nelly retrieve applications?**

- Applications are cloned from the GitHub repository specified in `config.json`. Updates are managed via `update.sh`.

### **3. Can I modify environment variables per application?**

- Yes! Define them under the `env` section in `config.json`. They will be automatically inherited during deployment.

### **4. How do I install additional dependencies inside a container?**

- List required packages in the `packages` section of `config.json`. They will be installed when the container is built.

### **5. How do I manually update an application?**

- Run `update.sh` inside the application’s container directory.

---

## Contributing

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature-branch`).
3. Commit and push your changes (`git push origin feature-branch`).
4. Open a Pull Request.

---

## License

This project is open-source under the MIT License.

## Contact

For issues or inquiries, contact:

- **Maintainer**: Jonatan Gani
- **GitHub**: [Jonatan-Gani](https://github.com/Jonatan-Gani)

