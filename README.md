# Traceability Matrix

<div align="center">

![Traceability](https://img.shields.io/badge/Traceability-Matrix-0EA5E9?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0zIDNoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2Mkgzem0wIDRoMTh2MkgzeiIvPjwvc3ZnPg==)
![TypeScript](https://img.shields.io/badge/TypeScript-Full_Stack-3178C6?style=for-the-badge&logo=typescript&logoColor=white)
![Node](https://img.shields.io/badge/Node.js-API_Server-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)
![Health](https://img.shields.io/badge/Repo_Health-Automated_Audit-22C55E?style=for-the-badge)

**Automated traceability, repo health auditing, and multi-artifact documentation platform.**

</div>

---

## Overview

Traceability Matrix provides automated **requirements traceability** between code, tests, and documentation — with a full-stack API server, mockup sandbox, and GitHub Actions health audit workflow.

## Structure

```
traceability-matrix/
├── artifacts/
│   ├── api-server/           ← TypeScript/Express API
│   │   ├── src/routes/       ← Health, index endpoints
│   │   └── src/lib/          ← Logger, middleware
│   └── mockup-sandbox/       ← Visual mockup environment
├── .github/workflows/
│   └── repo-health-audit.yml ← Automated health checks
└── docs/                     ← Architecture documentation
```

## API Server

```bash
cd artifacts/api-server
npm install
npm run build
npm start
```

**Endpoints:**

| Route | Description |
|-------|-------------|
| `GET /health` | Service health check |
| `GET /` | API index |

## Repo Health Audit

The GitHub Actions workflow runs automated health checks on every push:
- Documentation coverage
- Test-to-code ratio
- Dependency freshness
- Security scan

---

<div align="center">
<sub>Built by <strong>Deonte Watts</strong> · GoodShyt Group</sub>
</div>
