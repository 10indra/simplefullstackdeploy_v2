# Full Stack Multi-App Docker Deployment

Production-ready automated deployment script untuk menjalankan multiple Laravel applications dengan arsitektur:

User → HTTPS → Reverse Proxy → Nginx → PHP-FPM → Laravel → MySQL

---

## 🚀 Features

- Multi domain app stack
- HTTPS reverse proxy gateway
- Isolated docker network per app
- Automated Laravel installation
- Self provisioning server
- Production bash safety mode
- Logging system
- Retry mechanism
- Security hardening (UFW + Fail2ban)

---

## 📦 Architecture

Each app runs its own stack:

- Nginx container
- PHP container
- MySQL container
- Volume persistence
- Dedicated network

Gateway container:
- TLS termination
- Domain routing
- Service discovery via Docker DNS

---

## 🛠 Requirements

Server minimal:

- Ubuntu 22.04+
- Root access
- Internet connection
- Ports open:
  - 443
  - 22

---

## ▶️ Usage

```bash
chmod +x deploy_full_stackv2.sh
sudo ./deploy_full_stackv2.sh
