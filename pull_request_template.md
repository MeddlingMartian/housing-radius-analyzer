## Pull Request — Housing Radius Analyzer

### Type of change
<!-- Check all that apply -->
- [ ] 🐛 Bug fix
- [ ] ✨ New feature / function
- [ ] 📡 Data source addition or update
- [ ] 🔧 Config / pipeline change
- [ ] 📄 Documentation update
- [ ] 🔀 Data pull merge  (feature/data/* → data/housing-pulls)
- [ ] 🚀 Release          (release/* → main)

---

### Description
<!-- What does this PR do? Why is it needed? -->

---

### Location(s) affected
<!-- Which geographic search targets does this data pull cover? -->
| Field        | Value |
|-------------|-------|
| City / State | |
| ZIP code     | |
| Metro / Micro area | |
| Area type    | developed / rural / suburban |
| Radius (miles) | 35 |
| Data window  | 2.5 years (30 months) |

---

### Data sources modified or added
- [ ] Census ACS 5-Year (`api.census.gov`)
- [ ] BEA Regional GDP (`apps.bea.gov`)
- [ ] HUD USPS Crosswalk (`huduser.gov`)
- [ ] FHFA / CFPB HMDA (`consumerfinance.gov`)
- [ ] Census FTP PUMS (`ftp2.census.gov`)
- [ ] Other: _______________

---

### Testing
- [ ] `runtests('tests/')` passes locally with zero failures
- [ ] `analyzer.run()` completes without error for the affected location
- [ ] Exported CSV / JSON / XML validated (row counts match expectations)
- [ ] No API keys or secrets appear anywhere in the diff (`git diff` reviewed)
- [ ] `git check-ignore -v config.json` confirms it is gitignored

---

### Pipeline checks (Azure)
- [ ] Azure Pipeline lint stage passed
- [ ] Data pull stage completed (check pipeline run log)
- [ ] Outputs uploaded to Azure Blob Storage container `hra-outputs`
- [ ] Nightly schedule not disrupted

---

### Branch tree path
```
main
 └── feature/YOUR_BRANCH_NAME     ← this PR
      └── (merges into) → main    ← or data/housing-pulls for data-only PRs
```

---

### Screenshots / output samples
<!-- Paste the analyzer.report() output or attach exported CSV snippet -->
```
╔══════════════════════════════════════════════════════╗
║         HOUSING RADIUS ANALYSIS REPORT              ║
╠══════════════════════════════════════════════════════╣
║ Origin   :                                           ║
║ Radius   :  35 miles                                 ║
║ Records  :                                           ║
╠══════════════════════════════════════════════════════╣
║ Median List Price :                                  ║
║ Avg Price/SqFt    :                                  ║
║ Price YoY Change  :                                  ║
║ Regional GDP      :                                  ║
╚══════════════════════════════════════════════════════╝
```

---

### Reviewer checklist
- [ ] Diff contains no secrets, API keys, or tokens
- [ ] `config.template.json` updated if new config fields were added
- [ ] `API_KEY_VAULT.md` updated if new external services were added
- [ ] README.md reflects any new functions or parameters
- [ ] CHANGELOG entry added
