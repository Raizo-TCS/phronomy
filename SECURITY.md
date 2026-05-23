# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release (main branch) | ✅ |
| Older versions | ❌ — please upgrade |

Only the latest released version of `phronomy` receives security patches. If you
are running an older version, please upgrade before filing a report.

---

## Reporting a Vulnerability

**Please do NOT open a public GitHub Issue for security vulnerabilities.**

Use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
instead:

1. Navigate to the [Security tab](https://github.com/Raizo-TCS/phronomy/security)
   of this repository.
2. Click **"Report a vulnerability"**.
3. Fill in the advisory form with as much detail as possible.

This creates a private draft advisory visible only to maintainers, keeping the
details confidential until a fix is prepared and released.

---

## Response Timeline

| Milestone | Target |
|-----------|--------|
| Acknowledgement of report | Within **7 days** |
| Triage and initial assessment | Within **14 days** |
| Patch release (critical / high severity) | Within **30 days** |
| Patch release (medium / low severity) | Best effort; typically within **60 days** |

If you do not receive an acknowledgement within 7 days, please follow up by
opening a **public** Issue with the subject "Security report follow-up (no
response)" — do **not** include vulnerability details in the public Issue.

---

## Scope

**In scope:**

- Vulnerabilities in the `phronomy` gem source code (`lib/`, `spec/`).
- Dependency vulnerabilities that affect gem consumers when `phronomy` is used as intended.
- Information disclosure via tracing/logging APIs (e.g. `trace_pii: false` bypass).
- Approval gate bypasses (tool execution without the registered approval handler).

**Out of scope:**

- Security of consumer applications built on top of `phronomy`.
- Vulnerabilities in the LLM provider (OpenAI, Anthropic, etc.) or in `ruby_llm`.
- Attacks that require an attacker to already have write access to the host system.
- Prompt injection via LLM output — the gem forwards LLM output faithfully; prompt
  injection resistance is the responsibility of the LLM provider and the application.

---

## Disclosure Policy

- Maintainers will coordinate with you on the release date and credit you in the
  `CHANGELOG.md` entry and GitHub release notes.
- If you wish to remain anonymous, let us know in the advisory.
- We follow a **coordinated disclosure** model: the advisory will be made public
  after a patch is released (or after 90 days, whichever comes first).

---

## Credit

Security reporters are credited in the `CHANGELOG.md` entry for the patch release,
in the GitHub Security Advisory, and in the release notes — unless they request
anonymity.
