# Phase 7: report cards

## Built
| Item | Detail |
|---|---|
| Tables (User-owned) | `edu_reportcard` (student, term, overall %, overall grade, attendance %, status Draft or Published, generated on, published on, key `student\|term`) and `edu_reportcardline` (report card, subject assignment, final %, letter, teacher comment, key `reportcard\|assignment`). Created in DEV by `scripts/New-ReportCardSchema.ps1` and exported to source |
| Maths (`ReportCardRules`) | Subject % = sum(mark % x weightage) / sum(weightage of graded assessments), two places. Overall % = plain average of the subjects that have a percent. Letters come from `edu_gradeband` through `AcademicsRules.GradeLetter` |
| Custom API `edu_GenerateReportCards` | Contract in `solutions/EduCore/src/customapis` (TermId, SectionId; returns Generated, Skipped). Logic in `GenerateReportCardsPlugin`: one Draft card per actively enrolled student, one line per subject assignment of the section and term, attendance % from the attendance summary. Re-running rebuilds Draft cards; Published cards are skipped |
| Immutability (`ReportCardGuardPlugin`, `ReportCardLineGuardPlugin`) | A Published card cannot be updated or deleted and its lines cannot be created, changed or deleted. Publishing needs a generated card and stamps Published On |
| Seed data | `deploy/seed/phase7`: 24 Term 1 cards (first 6 Published, rest Draft) and 96 lines, calculated from the Phase 4 marks with the same maths and the Phase 5 attendance summaries. Imported into DEV |
| Tests | `ReportCardRulesTests`; whole suite 113 passing (hand-calculated weighted and overall maths, renormalised weights, immutability) |

## Not done yet
- DEV clean-up still pending from Phase 6: the stray `edu_feetype` table and `edu_payment.edu_date` column.
- Plug-in step registration for the two guards and binding `edu_GenerateReportCards` (see `docs/phase1.md`).
- **Publish flow** (notice to the guardian on status change) needs connection references and a maker; the publish rule itself is the guard plug-in.
