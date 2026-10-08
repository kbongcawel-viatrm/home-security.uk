# HQ Security Stack

## System Status

<iframe src="https://status.home-security.uk/badge?theme=light" width="250" height="30" frameborder="0" scrolling="no"></iframe>

> Click the badge above to view detailed status information for all security stack services.

---

## Overview

The **HQ Security Stack** is a comprehensive home security solution that implements enterprise-grade security monitoring and response capabilities. This stack includes:

### Core Components

- **The Eyes** - Intrusion Detection & Prevention (IDS/IPS)
- **The Brain** - Log Aggregation & Analysis
- **The Hands** - Incident Response & Remediation
- **The Shield** - File Integrity Monitoring (FIM)
- **The Sword** - Threat Hunting & Forensics
- **The Ghost** - Anomaly Detection & Analysis

### Key Features

✅ File Integrity Monitoring (FIM)  
✅ Real-time Alerting & Notifications  
✅ Intrusion Prevention/Detection Systems (IPS/IDS)  
✅ Log Assessment & Forensics  
✅ Log Aggregation & Visualization  
✅ Automated Response & Mitigation  

---

## Quick Links

- 📖 [Service Categories](./service-categories.md)
- 🔧 [Service Integration Guide](./service-integration.md)
- 🛡️ [Network & DNS Setup](./networking-dns.md)
- 📊 [Uptime Dashboard](./uptime-dashboard.md)
- 🔐 [Secrets Management](./vault-secrets.md)
- 🐳 [Image Prewarm](./registry-cache.md)

### Advanced Documentation

- [Ghost Analysis](./ghost-analysis.md)
- [Suricata Rulesets](./suricata-rulesets.md)
- [Network Sensor Scope](./network-sensor-scope.md)
- [Windows Endpoint Detection](./windows-endpoint-detection.md)
- [GitHub Actions Setup](./github-actions.md)
- [Harbor Container Registry](./harbor.md)

---

## Getting Started

### Prerequisites

- Docker & Docker Compose
- Python 3.x
- 4+ GB RAM (recommended)
- Linux-based host OS

### Deployment

```bash
# Clone the repository
git clone https://github.com/kbongcawel-viatrm/hq-sec-stack.git
cd hq-sec-stack

# Configure environment
cp .env.example .env
# Edit .env with your settings

# Deploy the stack
docker-compose -f security-stack.compose.yml up -d
```

For detailed configuration instructions, see [Service Integration Guide](./service-integration.md).

---

## Status & Monitoring

- **Live Status**: Check the badge above for real-time system status
- **Dashboard**: Access your monitoring dashboards after deployment
- **Logs**: Review comprehensive logs for all services

---

## Documentation

Complete documentation is available in the [docs](./docs) directory:

- Architecture & design decisions
- Service configuration & integration
- Troubleshooting guides
- Security best practices
- Advanced configuration

---

## Support & Contribution

For issues, questions, or contributions:

- 📋 [GitHub Issues](https://github.com/kbongcawel-viatrm/hq-sec-stack/issues)
- 💬 [GitHub Discussions](https://github.com/kbongcawel-viatrm/hq-sec-stack/discussions)
- 📝 [Changelog](../changelog.md)

---

## License

This project is provided as-is for educational and security research purposes.

---

**Last Updated**: 2026-07-04  
**Latest Version**: See [changelog](../changelog.md) for version history
