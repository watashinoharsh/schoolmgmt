# Demo script (about 12 minutes)

Use the DEV or TEST environment with the seed data from `deploy/seed` loaded. Sign in as the user named for each step; each user belongs to the matching EDU team.

1. **Front Office, admissions (2 min).** Open Applicants by Status. Open an applicant with an offer. Show the status path (Applied, Under Review, Offer Made). Run Enrol (`edu_EnrolApplicant`): a student, guardian link and enrolment appear together; run it again to show it is idempotent.
2. **Front Office, attendance (2 min).** Quick create an attendance record. Show Today's Absences and Students Below Attendance Threshold. Run the summary refresh and show the percentage matches the records (excused days leave the denominator).
3. **Teacher, marks (2 min).** Open a subject assignment's assessment. Enter marks above the maximum and show the rejection; enter valid marks and show percentage and grade letter. Show the Teacher cannot open an invoice.
4. **Coordinator, report cards (2 min).** Run `edu_GenerateReportCards` for a section and term. Open a Draft card: weighted subject percentages, letters, overall grade, attendance. Publish it; then try to edit it and its lines and show both are blocked.
5. **Finance, fees (2 min).** Run `edu_GenerateInvoice` for a student: a Draft invoice with lines from the fee structure, reduced by any concession. Send it, record a part payment (status Partially Paid), reverse it (status returns), try to pay more than is due, try to delete a payment (blocked).
6. **Security and audit (2 min).** As Front Office show National ID; as Finance show it hidden and fee concession visible. Open the audit history of a student.

Closing: show `scripts/build.ps1` (113 tests, three managed packages) and the pipeline stages.
