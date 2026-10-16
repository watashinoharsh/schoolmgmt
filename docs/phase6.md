# Phase 6: fees

## Built
| Item | Detail |
|---|---|
| Tables | `edu_feestructure` (grade, term, fee type choice, amount; `FeeStructurePlugin` fills `edu_uniquekey`), `edu_invoice`, `edu_invoiceline`, `edu_payment`; student carries `edu_feeconcessionpercent` |
| Line and totals rules (`FeeRules`, `InvoiceTotalsPlugin`) | Line total = quantity x amount, rounded to 2 places. Invoice total is the sum of lines, paid is the sum of completed payments, due = total - paid. Status follows from these (Paid, Partially Paid, Sent) |
| Concession | `ValidateConcession` checks the percent; `BuildLines` reduces each fee by the student's concession |
| Draft-only line edits (`InvoiceLineGuardPlugin`) | Lines can be added, changed or deleted only while the invoice is Draft |
| Payments (`PaymentGuardPlugin`) | Payments are validated against the invoice due amount and are reversed, never deleted |
| Overdue | Not set on save. The daily flow marks Sent or Partially Paid invoices past due with an amount due (`ShouldMarkOverdue`) |
| Custom API `edu_GenerateInvoice` | Contract in `solutions/EduCore/src/customapis` (StudentId, TermId, optional DueDate; returns InvoiceId, Created). Logic in `GenerateInvoicePlugin`: Draft invoice with lines from the student's grade and term; idempotent on `student|term` |
| Tests | `FeeRules` tests; whole suite 103 passing |
| Seed data | `deploy/seed/phase6`: 36 fee rows (12 grades x Tuition, Transport, Activity, Term 1), 24 invoices with 72 lines and 12 payments in a mix of Paid, Partially Paid, Overdue and Sent. Totals match the plug-in maths |
| Deviations from the LLD | Fee type is a local choice (Tuition, Transport, Activity), not a table. Amounts are Decimal(2), not Currency (the plug-ins use decimals). `edu_dueamount` is a stored column the totals plug-in maintains, because formula columns cannot be created through the API |

Tables imported into DEV (unmanaged), with the seed data.

## Not done yet
- **Cloud flows**: daily overdue marking (`FeeRules.ShouldMarkOverdue`) and fee reminder (`FeeRules.ReminderDue`). Need connection references and a maker to bind them.
- Plug-in step registration for `InvoiceLineGuardPlugin`, `PaymentGuardPlugin`, `InvoiceTotalsPlugin`, and binding `edu_GenerateInvoice` to `GenerateInvoicePlugin` (see `docs/phase1.md`).
- DEV clean-up: the first run of `scripts/New-FeesSchema.ps1` left a stray `edu_feetype` table (3 seed rows) and an unused `edu_payment.edu_date` column in DEV. Delete both; the script no longer creates them.
- `export-solution.ps1` fails at `--packagetype Both` (no managed zip). Unpack with `--packagetype Unmanaged` and set `<Managed>2</Managed>` in `Solution.xml` so the managed pack works.
