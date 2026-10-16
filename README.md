# EduCore: School Management System on Power Platform

A portfolio-grade school management system on **Dataverse** with a **model-driven app**, built and delivered as source-controlled managed solutions.

## Scope
Admissions and enrolment, student information, academics (timetable, assessments, report cards), attendance, fees and billing, lightweight staff records, communication, and role-based dashboards. Parent portal (Power Pages) and a teacher register (Canvas) are designed for and built last.

## Repository layout
| Path | Contents |
|---|---|
| `docs/` | LLD v2, conventions, Phase 0 runbook |
| `solutions/EduCore` | Tables, roles, plug-in package, environment variables (unpacked source) |
| `solutions/EduFlows` | Cloud flows and connection references |
| `solutions/EduApps` | Model-driven app, site map, dashboards |
| `src/EduCore.Plugins` | Plug-in package project (net462) |
| `tests/EduCore.Plugins.Tests` | Unit tests (xUnit); rule logic is pure and tested without Dataverse |
| `pipelines/` | Azure DevOps pipeline: build, test, pack, checker, TEST, UAT, PROD |
| `deploy/` | Per-environment deployment settings |
| `scripts/` | `build.ps1` (test and pack), `export-solution.ps1` (DEV to source) |

## Legacy content
`legacy/` holds the earlier ClinicMgmt solution (1.1.0.1) and the School Management System pack (2.2.1.0), kept with their history. Phase 3 tables from the CE solutions are merged into EduCore: see `docs/phase3-merge.md`.

## Quick start
```
.\scripts\build.ps1          # tests + plug-in build + pack all solutions into .\out
```
DEV environment setup, first import and test users: `docs/phase0-runbook.md`.

## Status
| Phase | State |
|---|---|
| 0 Foundations | Repo, solutions, env vars, tests, pipeline skeleton done. DEV environment and test users pending (see runbook) |
| 1 Reference data and calendar | Built and imported to DEV with seed data. Open items: course to grade N:N, plug-in step registration (`docs/phase1.md`) |
| 2 People | Built and imported to DEV with seed data. Open: plug-in step registration (`docs/phase2.md`) |
| 3 Admissions | Built and imported to DEV with seed data. Open: plug-in step registration and binding the Custom API (`docs/phase3.md`) |
| 4 Academics | Built and imported to DEV with seed data. Open: plug-in step registration (`docs/phase4.md`) |
| 5 Attendance | Built and imported to DEV with seed data. Open: flows, plug-in registration (`docs/phase5.md`) |
| 6 Fees | Built (source and tests); tables imported to DEV, see docs/phase6.md |
| 7 Report cards | Built and tables in DEV. Open: seed data, plug-in step registration, publish flow (`docs/phase7.md`) |
| 8 to 10 | Not started. Plan and design: `docs/LLD_v2_EduCore.md` |

## Requirements
Power Platform CLI (`pac`), .NET SDK, PowerShell. A Dataverse environment for DEV.
