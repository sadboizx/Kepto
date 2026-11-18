"""Sign one IPA with one pool certificate — no releases, no site.

Run from the repository root (where cert-url.txt lives):

    python3 -m signer.sign_one --ipa Kepto-unsigned.ipa \
        --cert Chengdu-Railway-Bureau --out signed

The certificate is fetched from the NexCerts pool (cert-url.txt) exactly
like the SideInstaller signer does. The signed IPA is written to
<out>/kepto-<slug>.ipa. PPQ Protection uses the same suffix formula as
signer.sync.ppq_suffix ("kepto:<display name>"), so the app keeps its own
bundle id plus a per-pair suffix. No signing-assets embed (that is
Feather/Ksign only).
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

from . import certs, codesign, pool
from .util import CommandError, Fatal, HTTPFailure, error, http_get, log, safe_name


def ppq_suffix(app_id: str, display_name: str) -> str:
    """Same formula as signer.sync.ppq_suffix."""
    return hashlib.sha256(f"{app_id}:{display_name}".encode()).hexdigest()[:6]


def sign_one(root: Path, unsigned_ipa: Path, cert_slug: str, out_dir: Path,
             workdir: Path, app_id: str = "kepto") -> Path:
    name = safe_name(cert_slug)
    fetched = pool.fetch(root, workdir / "pool")
    entry = fetched.entries.get(name)
    if entry is None:
        raise Fatal(f"certificate {cert_slug!r} is not in the pool "
                    f"({len(fetched.entries)} entries)")
    if entry.problem:
        raise Fatal(f"certificate {entry.display_name}: {entry.problem}")
    if entry.profile is None:
        raise Fatal(f"certificate {entry.display_name} has no provisioning profile")
    cert = certs.read_p12(entry.p12, entry.password)
    profile = certs.read_profile(entry.profile)
    log(f"Signing with {entry.display_name} (expires {cert.not_after.date()}, "
        f"fingerprint {cert.fingerprint[:8]}...)")
    issuers: list[bytes] = []
    if cert.issuer_url:
        try:
            issuers.append(http_get(cert.issuer_url, timeout=20))
        except HTTPFailure as exc:
            log(f"Could not fetch issuer certificate: {exc}")
    job = codesign.Job(name, entry.p12, entry.password, entry.profile, profile,
                       cert.fingerprint,
                       ppq_suffix=ppq_suffix(app_id, entry.display_name),
                       embed=False)
    out_dir.mkdir(parents=True, exist_ok=True)
    signdir = workdir / "sign"
    shutil.rmtree(signdir, ignore_errors=True)
    signdir.mkdir(parents=True)
    with codesign.Keychain(signdir) as keychain:
        usable = codesign.prepare_keychain(keychain, [job], issuers, signdir / "keychain")
        if job.fingerprint not in usable:
            raise Fatal(f"certificate {entry.display_name} could not be loaded "
                        "into the keychain")
        signer = codesign.Signer(unsigned_ipa, signdir, keychain)
        result = signer.sign(job, out_dir, app_id)
    if not result.ok:
        raise Fatal(f"signing failed: {result.error}")
    if result.ipa is None:
        raise Fatal("signing reported success but produced no IPA")
    log(f"Signed: {result.ipa} ({result.size} bytes, bundle id {result.bundle_id}, "
        f"{result.seconds:.1f}s)")
    return result.ipa


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m signer.sign_one",
                                     description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True, help="unsigned .ipa")
    parser.add_argument("--cert", required=True, help="certificate slug from pool.json")
    parser.add_argument("--out", type=Path, default=Path("signed"),
                        help="output directory (default: signed)")
    parser.add_argument("--root", type=Path, default=Path.cwd(),
                        help="repository root holding cert-url.txt (default: cwd)")
    parser.add_argument("--workdir", type=Path,
                        default=Path(tempfile.gettempdir()) / "signer-sign-one",
                        help="scratch space")
    parser.add_argument("--app-id", default="kepto",
                        help="app id for the PPQ suffix (default: kepto)")
    args = parser.parse_args(argv)
    try:
        out = sign_one(args.root, args.ipa, args.cert, args.out, args.workdir, args.app_id)
    except (Fatal, HTTPFailure, CommandError) as exc:
        error(str(exc))
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
