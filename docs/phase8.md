# Phase 8: app

## Built
| Item | Detail |
|---|---|
| Model-driven app | `EDU School Admin` (`edu_SchoolAdmin`) in EduApps, site map `edu_SchoolAdminSiteMap`: areas Admissions, Students, Academics, Attendance, Finance, Staff and Setup listing the edu_ tables. Created by `scripts/New-AdminApp.ps1` |
| Main forms (EduCore) | Student (Summary, Guardians, Enrolment history, Attendance, Marks and reports, Fees subgrids), Applicant (Summary), Invoice (Lines and Payments subgrids), Report Card (Lines subgrid). Existing main forms were updated in place and renamed "EduCore Main". `scripts/New-AppForms.ps1` |
| Quick create | Payment and Attendance. Quick create is not confirmed enabled on those tables |
| Views | Applicants by Status, Students Below Attendance Threshold (under 90%), Overdue Invoices, Draft Report Cards, Unpaid Invoices, Today's Absences; the existing Active Students view was overwritten (`statecode = 0`). `scripts/New-AppViews.ps1` |
| Dashboards and charts | Admin, Teacher and Front Office dashboards built from 6 system charts and lists |

Created in DEV (unmanaged) and exported with `--packagetype Unmanaged`; set `<Managed>2</Managed>` in each `Solution.xml` afterwards so the managed pack works.

Quick create is enabled on Payment and Attendance and the three dashboards are added to the app by `scripts/Fix-AppSetup.ps1`.

## Not done yet
- Forms, views and dashboards were not opened in the UI; check each persona's scenario before Phase 9.
- Enrol button on the Applicant form (calls `edu_EnrolApplicant`) and a Generate button for invoices and report cards.
- The Teacher dashboard's "my sections today" and "registers due" tiles need the personal view `My sections` and the Canvas register (stretch).
