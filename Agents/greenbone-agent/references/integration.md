# Greenbone Integration Reference

Greenbone supplies vulnerability context. The community stack uses feed data helpers, `pg-gvm`, `redis-server`, `gvmd`, `gsad`, `gsa`, `greenbone-nginx`, `openvasd`, and `ospd-openvas`.

Preferred flow: authorized scan -> finding triage in GSA -> critical finding attached to TheHive -> remediation tracked through Ansible or manual tasks -> Graylog dashboarding only for summary risk trends.
