# Architecture

## Solutions and layers
```mermaid
flowchart LR
  subgraph EduApps
    app[EDU School Admin app<br/>site map, dashboards]
  end
  subgraph EduFlows
    flows[Cloud flows<br/>nightly refresh, alerts, reminders]
  end
  subgraph EduCore
    tables[(26 tables<br/>Dataverse)]
    plugins[Plug-in package<br/>rules + Custom APIs]
    roles[5 security roles<br/>2 column profiles]
  end
  app --> tables
  flows -->|Custom APIs| plugins
  plugins --> tables
  roles -.guards.-> tables
```

## Data model (core relationships)
```mermaid
erDiagram
  ACADEMICYEAR ||--o{ TERM : has
  GRADE ||--o{ SECTION : has
  SECTION ||--o{ ENROLMENT : holds
  STUDENT ||--o{ ENROLMENT : has
  STUDENT ||--o{ STUDENTGUARDIAN : has
  CONTACT ||--o{ STUDENTGUARDIAN : is
  APPLICANT ||--o| STUDENT : "converts to"
  SECTION ||--o{ SUBJECTASSIGNMENT : teaches
  SUBJECTASSIGNMENT ||--o{ ASSESSMENT : sets
  ASSESSMENT ||--o{ STUDENTMARK : scores
  STUDENT ||--o{ STUDENTMARK : earns
  STUDENT ||--o{ ATTENDANCE : has
  STUDENT ||--o{ ATTENDANCESUMMARY : "summarised in"
  STUDENT ||--o{ REPORTCARD : receives
  REPORTCARD ||--o{ REPORTCARDLINE : lists
  STUDENT ||--o{ INVOICE : billed
  INVOICE ||--o{ INVOICELINE : has
  INVOICE ||--o{ PAYMENT : settled_by
  GRADE ||--o{ FEESTRUCTURE : prices
```

## Business logic placement
| Concern | Where | Why |
|---|---|---|
| Rules that must block a save (clashes, marks, status machine, money totals, immutability) | Synchronous plug-ins; the rule is a pure class with unit tests | Transactional and testable without Dataverse |
| Multi-record atomic operations | Custom APIs `edu_EnrolApplicant`, `edu_GenerateInvoice`, `edu_GenerateReportCards`, `edu_RefreshAttendanceSummary` | One transaction, callable from flows and buttons |
| Time-based and notification work | Cloud flows (overdue, reminders, low-attendance alert) | Needs connectors and a schedule |
| Access | Roles, teams, column profiles, auditing | See `docs/phase9.md` |

## Delivery
Source-controlled unpacked solutions, built and tested by `scripts/build.ps1` and the Azure DevOps pipeline (build, test, pack, solution checker, then TEST, UAT, PROD with managed solutions and per-environment settings files). See `docs/conventions.md`.
