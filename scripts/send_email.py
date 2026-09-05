#!/usr/bin/env python3
"""Send one alert by SMTP.  Body on stdin, subject as argv[1].

Uses only the standard library on purpose: no MTA to install on the host, no
package to keep working for ten years.  Any SMTP relay does -- Gmail with an
app password, or a transactional provider.

Configured entirely from the environment (loaded from .env by notify.sh):

    SMTP_HOST   e.g. smtp.gmail.com
    SMTP_PORT   587 for STARTTLS, 465 for implicit TLS  (default 587)
    SMTP_USER   login, and the From: address unless SMTP_FROM is set
    SMTP_PASS   password / app password
    SMTP_FROM   optional explicit From:
    ALERT_EMAIL recipient; comma-separated for several

Exits 0 on success, 1 on any failure.  The caller ignores the exit code: a
notifier that cannot deliver must never turn a good collection into a failed
one.  It says why on stderr so the reason is in the daily log.
"""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


def main():
    host = os.environ.get("SMTP_HOST", "").strip()
    user = os.environ.get("SMTP_USER", "").strip()
    password = os.environ.get("SMTP_PASS", "")
    to = [a.strip() for a in os.environ.get("ALERT_EMAIL", "").split(",") if a.strip()]
    if not (host and to):
        return 1  # not configured; notify.sh reports the absence of channels

    port = int(os.environ.get("SMTP_PORT", "587") or 587)
    sender = os.environ.get("SMTP_FROM", "").strip() or user or f"modelpass@{host}"
    subject = sys.argv[1] if len(sys.argv) > 1 else "ModelPass"
    body = sys.stdin.read()

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(to)
    msg["Subject"] = subject
    msg.set_content(body)

    try:
        ctx = ssl.create_default_context()
        if port == 465:
            with smtplib.SMTP_SSL(host, port, timeout=30, context=ctx) as s:
                if user:
                    s.login(user, password)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=30) as s:
                s.ehlo()
                if s.has_extn("starttls"):
                    s.starttls(context=ctx)
                    s.ehlo()
                elif user:
                    # A local or internal relay legitimately may not offer
                    # STARTTLS -- but never hand it a password in the clear.
                    print(
                        f"send_email.py: {host}:{port} offers no STARTTLS and "
                        "SMTP_USER is set; refusing to send credentials in "
                        "plaintext. Use port 465, a relay with STARTTLS, or "
                        "clear SMTP_USER for an unauthenticated local relay.",
                        file=sys.stderr,
                    )
                    return 1
                if user:
                    s.login(user, password)
                s.send_message(msg)
    except Exception as exc:
        # Never print the password, and never raise: this is the alert path.
        print(f"send_email.py: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
