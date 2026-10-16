# Phase 9: security

## Built
| Item | Detail |
|---|---|
| Roles | `EDU - Front Office`, `EDU - Teacher`, `EDU - Academic Coordinator`, `EDU - Finance Officer`, `EDU - Principal`, built from the Basic User base plus the LLD section 6 matrix (table groups and scopes are data at the top of `scripts/New-Security.ps1`). Roles are in the EduCore solution source (`solutions/EduCore/src/Roles`) |
| Scopes | Organisation (Global) or owner only (Basic). Teachers hold Create and Write at owner scope on attendance and Create, Read, Write and Delete at owner scope on assessments and marks; Finance cannot delete; Append and Append To are derived from the write scope, with Append To at organisation scope for lookups |
| Teams | `EDU Front Office`, `EDU Teachers`, `EDU Coordinators`, `EDU Finance Officers`, `EDU Principals`, each holding its role (users are added to teams, not to roles) |
| Column security | Profile `EDU Identity` on `edu_student.edu_nationalid` (Front Office, Coordinators) and `EDU Finance` on `edu_student.edu_feeconcessionpercent` (Finance Officers). The columns are marked secured in the table metadata |
| Auditing | Enabled on student, student guardian, applicant, enrolment, attendance, marks, report card, invoice and payment |
| Check | `New-Security.ps1 -Verify` compares every role's privileges with the matrix, both missing and extra, and reported all five roles matching |

## Not done yet
- **Test each persona with a real user** (the Phase 9 exit criterion). Four test users, one per persona, are still pending from Phase 0. Add each to its team, then walk the app scenarios and the denials (for example Finance cannot delete a payment, a Teacher cannot open an invoice, only Front Office and Coordinators see National ID).
- The two field security profiles are in the EduCore solution (they appear in its `Customizations.xml`). Teams are not solution components, so other environments get them by running the script, then adding users.
- `edu_notificationlog` is not a table yet, so the Notification log row of the matrix is skipped.
- The organisation-wide audit setting must also be on for table auditing to record anything.
- The Parent role is Power Pages table permissions, not a Dataverse role (stretch).
- Cover teachers cannot write another teacher's attendance under owner scope; a Coordinator reassigns ownership (known limitation in the LLD).
