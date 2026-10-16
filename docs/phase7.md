# Phase 7: report cards

## Built
| Item | Detail |
|---|---|
| Tables (User-owned) | `edu_reportcard` (student, term, overall %, overall grade, attendance %, status Draft or Published, generated on, published on, key `student\|term`) and `edu_reportcardline` (report card, subject assignment, final %, letter, teacher comment, key `reportcard\|assignment`). Created by `scripts/New-ReportCardSchema.ps1` |
| Maths (`ReportCardRules`) | Subject % = sum(mark % x weightage) / sum(weightage of graded assessments), two places. Overall % = plain average of the subjects that have a percent. Letters come from `edu_gradeband` through `AcademicsRules.GradeLetter` |
| Custom API `edu_GenerateReportCards` | Contract in `solutions/EduCore/src/customapis` (TermId, SectionId; returns Generated, Skipped). Logic in `GenerateReportCardsPlugin`: one Draft card per actively enrolled student, one line per subject assignment of the section and term, attendance % from the attendance summary. Re-running rebuilds Draft cards; Published cards are skipped |
| Immutability (`ReportCardGuardPlugin`, `ReportCardLineGuardPlugin`) | A Published card cannot be updated or deleted and its lines cannot be created, changed or deleted. Publishing needs a generated card and stamps Published On |
| Tests | `ReportCardRulesTests`; whole suite 113 passing (hand-calculated weighted and overall maths, renormalised weights, immutability) |

## Not done yet
- Tables are not created in DEV yet (needs a Dataverse token, see `scripts/Get-DvToken.ps1`); run `New-ReportCardSchema.ps1`, then export.
- Plug-in step registration for the two guards and binding `edu_GenerateReportCards` (see `docs/phase1.md`).
- **Publish flow** (notice to the guardian on status change) needs connection references and a maker; the publish rule itself is the guard plug-in.
- Seed data.
