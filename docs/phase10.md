# Phase 10: release

## Built
| Item | Detail |
|---|---|
| Managed packages | `scripts/build.ps1` runs the tests (113 passing), builds the plug-in package and packs EduCore, EduFlows and EduApps as managed and unmanaged zips into `out/` |
| Architecture | `docs/architecture.md`: solution layers, data model diagram, where each kind of logic lives |
| Demo script | `docs/demo-script.md`: a 12-minute walk through the personas |
| Settings files | `deploy/settings.test.json`, `.uat.json`, `.prod.json` (no values that identify an environment) |
| Export script fix | `scripts/export-solution.ps1` now unpacks unmanaged without deleting files and restores `<Managed>2</Managed>`; the old `--packagetype Both` step failed because no managed zip was exported |

Custom APIs `edu_GenerateInvoice` and `edu_GenerateReportCards` were created in DEV (unbound to a plug-in) by `scripts/New-CustomApis.ps1`; the re-export matched the repo source exactly.

Plug-in package `edu_EduCorePlugins` and 54 steps (with images) were registered in DEV by `scripts/Register-Plugins.ps1` and exported to `solutions/EduCore/src` (`pluginpackages`, `SdkMessageProcessingSteps`). The four Custom APIs are bound to their plug-in types. Smoke tests, all rejected as intended: invoice line on a non-draft invoice, deleting a payment, marks above the assessment maximum, editing a Published report card. This closes the "plug-in step registration" item in the Phase 1 to 7 notes: the rules are now enforced in DEV. The script builds with `--no-incremental` because a stale incremental package held only 14 plug-in types.

## Seed data and the API check
Running the APIs against the seed exposed three things:
- `pac data import` ignores the ids in `data.xml` for new rows and does not set lookups that point at records from another seed package, so the Phase 2 to 7 seed rows had blank year, term, grade and section references. The seed files now carry the ids of the DEV records, and `scripts/repair-seed-lookups.py` sets the lookups after the packages are loaded (1,661 records patched, no failures). On a new environment: load phase 1 to 7, read back the ids, rewrite `data.xml` the same way, reload, then run the script.
- `edu_RefreshAttendanceSummary` and `edu_GenerateInvoice` read an omitted optional date as 0001-01-01, which gave 0 teaching days. `ApiInput.OptionalDate` now treats that as missing (114 tests). Package re-registered in DEV.
- After the fix, `edu_GenerateInvoice` returned all 24 existing invoices unchanged and `edu_GenerateReportCards` reproduced every seeded line and overall percentage exactly. `edu_RefreshAttendanceSummary` now writes 88 teaching days (1 June to 30 September, less closures), about 44% for the sample students, because the attendance seed only covers 3 August to 25 September (40 days). The seed summaries in `deploy/seed/phase5` still say 40 days. Decide whether to extend the attendance seed back to 1 June or move Term 1 to start on 3 August.
- DEV also holds three leftover `ZZTEST_625971_*` students, a section and academic years from an earlier test run.

## Not done yet
- **Clean managed deploy to a second environment.** Needs an environment that is not Clinic Mgmt DEV01 (see `docs/phase0-runbook.md`); import `out\*_managed.zip` with the matching settings file and confirm the app opens and the seed loads.
- **Pipeline run to TEST.** Needs an Azure DevOps project, the `edu-vars` variable group, service connections and the three environments.
- **Build location.** Phases 1 to 9 were built in Clinic Mgmt DEV01, which the runbook says not to use for EduCore. Importing the managed packages into a clean environment is the way to prove nothing in DEV was left out of source (for example the quick-create settings and the teams).
- Cloud flows (nightly refresh, low-attendance alert, overdue, fee reminder, report card published notice), Enrol and Generate buttons, and the Phase 9 real-user persona tests, as listed in the phase notes.
