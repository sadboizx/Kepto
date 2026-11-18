"""Sign one IPA with one certificate from the repository — no releases,
no site. PPQ Protection is ON (same formula as the pool flow): the app
is signed as <bundle id>.<suffix>, where suffix is the first 6 hex
chars of sha256("<app-id>:<display name>") — so the same certificate
always produces the same bundle id, and different apps sharing one
certificate never overwrite each other on install. The Share Extension
survives (plugins are kept when a PPQ suffix applies).

Run from the repository root:

    python3 -m signer.sign_one --ipa Kepto-unsigned.ipa --out signed

The certificate comes from signer/certificate/ in this repository (upload
it there first):

    signer/certificate/cert.p12
    signer/certificate/cert.mobileprovision
    signer/certificate/cert.txt          # the .p12 password (may be empty)

The app keeps its own bundle id plus the PPQ suffix
(com.sadboizx.kepto.<suffix>): the signer refuses to run when the
profile cannot produce that id (for example a profile that opts out
of PPQ), instead of silently re-ID-ing the app to the profile's id.
No signing-assets embed (that is Feather/Ksign only).
"""
from __future__ import annotations

import argparse
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

from . import certs, codesign
from .certs import CertError
from .util import CommandError, Fatal, HTTPFailure, error, http_get, log


def _display_name(cert, profile) -> str:
    """Display name for the PPQ suffix — the same string the pool flow
    uses for this certificate (company + profile name, e.g.
    'Jiangsu Simcere Pharmaceutical Co.,Ltd (workone)'), so an app
    signed here gets the same bundle id as the same app signed by the
    pool with the same certificate."""
    name = cert.common_name
    for prefix in ("iPhone Distribution: ", "iPhone Developer: "):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    return f"{name} ({profile.name})" if profile.name else name


def ppq_suffix(app_id: str, display_name: str) -> str:
    """Deterministic 6-character PPQ suffix for one (app, certificate)
    pair — identical to signer.sync.ppq_suffix and the old zsign
    pipeline's formula."""
    return hashlib.sha256(f"{app_id}:{display_name}".encode()).hexdigest()[:6]


def sign_one(root: Path, unsigned_ipa: Path, out_dir: Path, workdir: Path,
             cert_dir: Path | None = None, app_id: str = "kepto") -> Path:
    cert_dir = cert_dir or root / "signer" / "certificate"
    p12 = cert_dir / "cert.p12"
    profile_path = cert_dir / "cert.mobileprovision"
    missing = [p.name for p in (p12, profile_path) if not p.is_file()]
    if missing:
        raise Fatal(f"missing {', '.join(missing)} in {cert_dir} — upload "
                    "cert.p12, cert.mobileprovision and cert.txt there first")
    pw_file = cert_dir / "cert.txt"
    password = pw_file.read_text(encoding="utf-8", errors="replace").strip() \
        if pw_file.is_file() else ""
    cert = certs.read_p12(p12, password)
    profile = certs.read_profile(profile_path)
    suffix = ppq_suffix(app_id, _display_name(cert, profile))
    log(f"Signing with {cert.common_name} (expires {cert.not_after.date()}, "
        f"profile {profile.name}, fingerprint {cert.fingerprint[:8]}..., "
        f"PPQ suffix {suffix})")
    issuers: list[bytes] = []
    if cert.issuer_url:
        try:
            issuers.append(http_get(cert.issuer_url, timeout=20))
        except HTTPFailure as exc:
            log(f"Could not fetch issuer certificate: {exc}")
    job = codesign.Job("signed", p12, password, profile_path, profile,
                       cert.fingerprint, ppq_suffix=suffix, embed=False)
    out_dir.mkdir(parents=True, exist_ok=True)
    signdir = workdir / "sign"
    shutil.rmtree(signdir, ignore_errors=True)
    signdir.mkdir(parents=True)
    with codesign.Keychain(signdir) as keychain:
        usable = codesign.prepare_keychain(keychain, [job], issuers, signdir / "keychain")
        if job.fingerprint not in usable:
            raise Fatal("the certificate could not be loaded into the keychain")
        signer = codesign.Signer(unsigned_ipa, signdir, keychain)
        bundle_id = signer.target_bundle_id(job)
        expected = f"{signer.info['bundle_id']}.{suffix}"
        if bundle_id != expected:
            raise Fatal(f"the profile would sign as {bundle_id}, not "
                        f"{expected} — upload a provisioning profile for "
                        "Kepto (wildcard, or explicit for "
                        f"{signer.info['bundle_id']})")
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
    parser.add_argument("--out", type=Path, default=Path("signed"),
                        help="output directory (default: signed)")
    parser.add_argument("--cert-dir", type=Path, default=None,
                        help="folder with cert.p12, cert.mobileprovision, cert.txt "
                             "(default: <root>/signer/certificate)")
    parser.add_argument("--root", type=Path, default=Path.cwd(),
                        help="repository root (default: cwd)")
    parser.add_argument("--workdir", type=Path,
                        default=Path(tempfile.gettempdir()) / "signer-sign-one",
                        help="scratch space")
    parser.add_argument("--app-id", default="kepto",
                        help="prefix of the signed IPA name (default: kepto)")
    args = parser.parse_args(argv)
    try:
        out = sign_one(args.root, args.ipa, args.out, args.workdir, args.cert_dir, args.app_id)
    except (Fatal, CertError, HTTPFailure, CommandError) as exc:
        error(str(exc))
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
