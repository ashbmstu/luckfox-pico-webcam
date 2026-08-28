# Security

luckfox-pico-webcam is firmware for a USB webcam on a personal desk. It is not
a networked service. The realistic threat model is limited to what someone with
physical USB access to the device could do, or flaws in how the board is
configured out of the box.

## Hardening context

The stock Luckfox vendor image ships with telnet and Samba enabled and a
well-known root password. **This project does not currently remove them.** The
daemon and the USB descriptors are what this repository changes; the rest of the
vendor image is as Luckfox shipped it.

Stripping those services is planned rather than done — see
[WP4 and WP6 in the roadmap](docs/roadmap.md). Until that work lands, treat a
board built from this project as carrying the vendor image's defaults, and do
not attach it to a network you do not control.

## Reporting a vulnerability

Report security issues through [GitHub's private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository. Do not open a public issue for security-sensitive
findings.

## What to expect

There is no support commitment and no CVE process. Reports are reviewed in good
faith; fixes depend on maintainer availability and severity.
