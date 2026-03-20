Housing Radius Analyzer — Complete Setup & PR Walkthrough
Copyright (C) 2026 Tyler Blankenship · Rae · Lucas · Daloze Benoit (Eregon)
DIAGNOSIS: What Broke and Why
The Error
ENOENT: no such file or directory, chdir
  '/home/runner/work/housing-radius-analyzer/housing-radius-analyzer' -> 'docs/'
Root Cause
The GitHub Actions workflow file (.github/workflows/jekyll-gh-pages.yml) told
setup-ruby to change into the docs/ directory before doing anything — but
that directory did not exist in the repository. The runner tried to cd docs/
and immediately crashed.
What Was Missing
File
Why Needed
docs/ directory
The workflow's working-directory: docs requires this to exist
docs/Gemfile
setup-ruby reads this to know which gems to install
docs/_config.yml
Jekyll refuses to build without a config file
docs/index.md
Jekyll needs at least one page to build
docs/.gitignore
Keeps _site/ and .jekyll-cache/ out of git
docs/.ruby-version
Pins the Ruby version for local development parity
.gitattributes
Controls language detection and line endings
File Structure After This Fix
housing-radius-analyzer/
├── .github/
│   └── workflows/
│       └── jekyll-gh-pages.yml   ← FIXED workflow
├── docs/                         ← NEW — was missing entirely
│   ├── .gitignore
│   ├── .ruby-version
│   ├── Gemfile
│   ├── _config.yml
│   ├── _posts/
│   │   └── 2026-03-19-launch.md
│   └── index.md
├── .gitattributes                ← NEW — linguist overrides
├── CONTRIBUTING.md               ← NEW — contributor guide
└── (your existing source files)
Step-by-Step: Applying the Fix
Step 1 — Copy the generated files into your repo
# From your local clone of housing-radius-analyzer
cp -r /path/to/generated/docs ./docs
cp /path/to/generated/.gitattributes .
cp /path/to/generated/.github/workflows/jekyll-gh-pages.yml \
     .github/workflows/jekyll-gh-pages.yml
cp /path/to/generated/CONTRIBUTING.md .
Step 2 — Test Jekyll locally before pushing
cd docs
gem install bundler          # if not already installed
bundle install               # installs gems from Gemfile
bundle exec jekyll serve     # starts dev server at http://localhost:4000
Open http://localhost:4000 — you should see the Housing Radius Analyzer homepage.
If you see an error about webrick, run:
bundle add webrick
Step 3 — Commit everything
cd ..   # back to repo root
git checkout -b fix/add-docs-directory
git add docs/ .gitattributes CONTRIBUTING.md \
        .github/workflows/jekyll-gh-pages.yml
git commit -m "fix: add docs/ directory and Jekyll config to resolve CI ENOENT error

The setup-ruby action was crashing because docs/ did not exist.
Added Gemfile, _config.yml, index.md, and supporting files.
Updated workflow to validate docs/ presence before setup-ruby runs.

Fixes ENOENT: no such file or directory, chdir -> 'docs/'"
Step 4 — Push and open the Pull Request
git push origin fix/add-docs-directory
Then go to:
https://github.com/MeddlingMartian/housing-radius-analyzer/pull/new/fix/add-docs-directory
PR Title:
fix: add docs/ directory with Jekyll scaffold to resolve CI ENOENT error
PR Body:
## Problem
The Jekyll GitHub Pages workflow was failing with:
  ENOENT: no such file or directory, chdir ... -> 'docs/'

The `working-directory: docs` in the workflow expected a docs/ folder
that did not exist in the repository.

## Solution
- Created `docs/` with Gemfile, _config.yml, index.md, and supporting files
- Added early validation step in workflow to fail fast with a clear message
- Added .gitattributes for Linguist language detection and line endings
- Added CONTRIBUTING.md

## Testing
- [ ] `bundle exec jekyll build` passes locally from docs/
- [ ] GitHub Actions workflow passes on this branch
- [ ] GitHub Pages URL loads correctly after merge

Closes #<issue number if any>
Step 5 — Enable GitHub Pages
After the PR merges:
Go to https://github.com/MeddlingMartian/housing-radius-analyzer/settings/pages
Under Source select GitHub Actions
Save — the workflow will deploy automatically on the next push to main
Your site will be live at:
https://meddlingmartian.github.io/housing-radius-analyzer/
Understanding the Workflow Fix
The key change in jekyll-gh-pages.yml is the guard step:
- name: Ensure docs/ directory exists
  working-directory: ${{ github.workspace }}
  run: |
    if [ ! -d "docs" ]; then
      echo "::error::docs/ directory is missing."
      exit 1
    fi
This runs before setup-ruby and produces a clear, human-readable error
if docs/ is ever accidentally deleted, rather than a cryptic Node.js stack trace.
Understanding .gitattributes
The .gitattributes file does three things:
1. Linguist overrides — tells GitHub what to count as "source code" in the
language bar on your repo homepage. Without it, docs/_site/ HTML would show
your repo as mostly HTML instead of JavaScript.
2. Generated file suppression — files marked linguist-generated are
collapsed by default in pull request diffs, keeping reviews clean.
3. Line ending normalization — text=auto ensures consistent \n line
endings across Windows, macOS, and Linux contributors.
ruby-builder.js Reference (from ruby/setup-ruby)
The ruby-builder.js file handles RubyGems version management. Relevant to
this project: it uses semver to compare your installed gem version against
the target. For Ruby 3.3 (which this project uses), it maps to:
floatVersion >= 3.2 → gem update --system   (latest, no cap)
This means RubyGems will always be updated to the newest compatible version
when rubygems: latest is set in the workflow. No manual pinning needed.
Copyright Attribution
All files in this scaffold carry the following notice:
Copyright (C) 2026 Daloze Benoit - Eregon
Copyright (C) 2026 Tyler Blankenship
Copyright (C) 2026 Rae
Copyright (C) 2026 Lucas
Eregon (Benoit Daloze) is the primary maintainer of ruby/setup-ruby and
ruby/ruby. The toolchain files (windows-toolchain-versions.json,
ruby-builder.js) originate from that project and are used here under their
original MIT license.
