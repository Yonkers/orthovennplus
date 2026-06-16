#!/usr/bin/env python3
"""
Download UniProt Swiss-Prot and build DIAMOND reference database for annotation.

Outputs:
  data/refdb/uniprot_sprot_annotation.dmnd   (DIAMOND db)
  data/refdb/uniprot_sprot_annotation.tsv    (annotation table)
  data/refdb/go_terms.tsv                     (GO id/name/category table)

Requires:
  - curl or wget
  - diamond (in biobase conda env or PATH)
  - ~500 MB disk space
"""

import argparse
import csv
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent if SCRIPT_DIR.name == "tools" else SCRIPT_DIR
REFDB_DIR = PROJECT_ROOT / "data" / "refdb"

FASTA_URL = (
    "https://ftp.uniprot.org/pub/databases/uniprot/"
    "current_release/knowledgebase/complete/uniprot_sprot.fasta.gz"
)
# UniProt REST API: reviewed = Swiss-Prot
TSV_URL = (
    "https://rest.uniprot.org/uniprotkb/stream"
    "?query=reviewed:true"
    "&format=tsv"
    "&fields=accession,protein_name,gene_names,go_id"
)

FASTA_GZ = REFDB_DIR / "uniprot_sprot.fasta.gz"
FASTA_UNZIPPED = REFDB_DIR / "uniprot_sprot.fasta"
TSV_RAW = REFDB_DIR / "uniprot_sprot_raw.tsv"
TSV_FINAL = REFDB_DIR / "uniprot_sprot_annotation.tsv"
DMND_OUT = REFDB_DIR / "uniprot_sprot_annotation.dmnd"
GO_OBO_URL = "https://current.geneontology.org/ontology/go-basic.obo"
GO_OBO = REFDB_DIR / "go-basic.obo"
GO_TERMS = REFDB_DIR / "go_terms.tsv"

# Column mapping from UniProt API output to the annotation parser headers.
COLUMN_MAP = {
    "Entry": "Entry",
    "Protein names": "Protein names",
    "Gene Names": "Gene names",
    "Gene Ontology IDs": "Gene Ontology IDs",
}


def run(cmd: list, cwd: Path = None, check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command."""
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, cwd=cwd, check=check)


def has_tool(name: str) -> bool:
    return shutil.which(name) is not None


def diamond_cmd() -> list:
    """Return diamond command prefix (with conda if needed)."""
    if has_tool("diamond"):
        return ["diamond"]
    # Try conda biobase environment
    conda = shutil.which("conda") or shutil.which("mamba")
    if conda:
        return [conda, "run", "-n", "biobase", "diamond"]
    raise RuntimeError("diamond not found in PATH or conda biobase env")


def download(url: str, dest: Path, force: bool = False):
    """Download a file with curl or wget."""
    if dest.exists() and not force:
        print(f"  [skip] {dest.name} already exists (use --force to overwrite)")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)

    if has_tool("curl"):
        run(["curl", "-fSL", "-C", "-", "-o", str(dest), url])
    elif has_tool("wget"):
        run(["wget", "-c", "-O", str(dest), url])
    else:
        raise RuntimeError("Neither curl nor wget found")


def download_tsv_via_curl(url: str, dest: Path, force: bool = False):
    """Download TSV from REST API (curl handles large streams better)."""
    if dest.exists() and not force:
        print(f"  [skip] {dest.name} already exists (use --force to overwrite)")
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  Downloading annotation TSV from UniProt REST API ...")
    print(f"  (This may take a few minutes for ~500k Swiss-Prot entries)")

    cmd = [
        "curl",
        "-fSL",
        "-C",
        "-",
        "-H",
        "Accept: text/tsv",
        "-o",
        str(dest),
        url,
    ]
    run(cmd)


def fix_tsv_headers(raw_path: Path, out_path: Path):
    """Rename UniProt REST API column headers to match ov4_build_annotation.py expectations."""
    print(f"  Fixing TSV headers: {raw_path.name} -> {out_path.name}")

    with (
        open(raw_path, "r", newline="") as fin,
        open(out_path, "w", newline="") as fout,
    ):
        reader = csv.DictReader(fin, delimiter="\t")
        # Rename headers
        fieldnames = []
        for h in reader.fieldnames:
            fieldnames.append(COLUMN_MAP.get(h, h))

        writer = csv.DictWriter(fout, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()

        row_count = 0
        for row in reader:
            new_row = {}
            for old_key, val in row.items():
                new_key = COLUMN_MAP.get(old_key, old_key)
                new_row[new_key] = val
            writer.writerow(new_row)
            row_count += 1
            if row_count % 50000 == 0:
                print(f"    ... processed {row_count} rows")

    print(f"  Wrote {row_count} rows to {out_path.name}")


def parse_go_obo(obo_path: Path) -> list[dict[str, str]]:
    """Parse go-basic.obo into a compact GO term table."""
    rows: list[dict[str, str]] = []
    current: dict[str, str] = {}
    in_term = False

    def flush() -> None:
        if current.get("go_id") and not current.get("is_obsolete"):
            rows.append(
                {
                    "go_id": current.get("go_id", ""),
                    "go_name": current.get("go_name", ""),
                    "category": current.get("category", ""),
                }
            )

    for raw in obo_path.read_text().splitlines():
        line = raw.strip()
        if line == "[Term]":
            if in_term:
                flush()
            current = {}
            in_term = True
            continue
        if line.startswith("["):
            if in_term:
                flush()
            current = {}
            in_term = False
            continue
        if not in_term or not line:
            continue
        if line.startswith("id:"):
            current["go_id"] = line.split(":", 1)[1].strip()
        elif line.startswith("name:"):
            current["go_name"] = line.split(":", 1)[1].strip()
        elif line.startswith("namespace:"):
            current["category"] = line.split(":", 1)[1].strip()
        elif line.startswith("is_obsolete:") and line.split(":", 1)[1].strip() == "true":
            current["is_obsolete"] = "true"

    if in_term:
        flush()
    return rows


def build_go_terms_tsv(*, obo_path: Path, out_path: Path) -> dict[str, object]:
    """Write go_terms.tsv without importing project source modules."""
    rows = parse_go_obo(obo_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["go_id", "go_name", "category"], delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    return {"go_term_count": len(rows), "go_terms_tsv": str(out_path)}


def build_diamond_db(fasta_path: Path, db_path: Path, force: bool = False):
    """Build DIAMOND database from FASTA."""
    if db_path.exists() and not force:
        print(f"  [skip] {db_path.name} already exists (use --force to overwrite)")
        return

    cmd = diamond_cmd() + [
        "makedb",
        "--in",
        str(fasta_path),
        "--db",
        str(db_path.with_suffix("")),  # diamond adds .dmnd
    ]
    run(cmd)


def gunzip_file(gz_path: Path, out_path: Path):
    """Gunzip a file."""
    if out_path.exists():
        print(f"  [skip] {out_path.name} already exists")
        return
    run(["gunzip", "-k", str(gz_path)])


def verify(refdb_dir: Path) -> bool:
    """Check that all required files exist."""
    dmnd = refdb_dir / "uniprot_sprot_annotation.dmnd"
    tsv = refdb_dir / "uniprot_sprot_annotation.tsv"
    go_terms = refdb_dir / "go_terms.tsv"

    ok = True
    for f in (dmnd, tsv, go_terms):
        if f.exists():
            size_mb = f.stat().st_size / (1024 * 1024)
            print(f"  [OK] {f.name} ({size_mb:.1f} MB)")
        else:
            print(f"  [MISSING] {f.name}")
            ok = False
    return ok


def cleanup_intermediates():
    """Remove intermediate files to save space."""
    for f in (FASTA_GZ, FASTA_UNZIPPED, TSV_RAW, GO_OBO):
        if f.exists():
            print(f"  Removing {f.name}")
            f.unlink()


def main():
    parser = argparse.ArgumentParser(
        description="Download UniProt Swiss-Prot and build DIAMOND refdb"
    )
    parser.add_argument("--force", action="store_true", help="Overwrite existing files")
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="Remove intermediate FASTA/TSV raw files after build",
    )
    args = parser.parse_args()

    print("=" * 60)
    print("UniProt Swiss-Prot Reference Database Setup")
    print("=" * 60)
    print(f"Output directory: {REFDB_DIR}")

    REFDB_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Download FASTA
    print("\n[1/4] Downloading UniProt Swiss-Prot FASTA ...")
    download(FASTA_URL, FASTA_GZ, force=args.force)

    # 2. Gunzip FASTA
    print("\n[2/4] Unzipping FASTA ...")
    gunzip_file(FASTA_GZ, FASTA_UNZIPPED)
    fasta_to_use = FASTA_UNZIPPED if FASTA_UNZIPPED.exists() else FASTA_GZ

    # 3. Download annotation TSV
    print("\n[3/4] Downloading annotation TSV from UniProt REST API ...")
    download_tsv_via_curl(TSV_URL, TSV_RAW, force=args.force)

    # 4. Fix headers
    print("\n[4/5] Building reference files ...")
    fix_tsv_headers(TSV_RAW, TSV_FINAL)

    # 5. Download and parse GO ontology
    print("\n[5/5] Downloading GO ontology and building GO terms table ...")
    download(GO_OBO_URL, GO_OBO, force=args.force)
    if GO_TERMS.exists() and not args.force:
        print(f"  [skip] {GO_TERMS.name} already exists (use --force to overwrite)")
    else:
        summary = build_go_terms_tsv(obo_path=GO_OBO, out_path=GO_TERMS)
        print(f"  Wrote {summary['go_term_count']} GO terms to {GO_TERMS.name}")

    # 6. Build DIAMOND db
    build_diamond_db(fasta_to_use, DMND_OUT, force=args.force)

    # 7. Verify
    print("\n" + "=" * 60)
    print("Verification")
    print("=" * 60)
    ok = verify(REFDB_DIR)

    if args.cleanup:
        print("\nCleaning up intermediate files ...")
        cleanup_intermediates()

    if ok:
        print("\nDone! Reference database is ready.")
        sys.exit(0)
    else:
        print("\nSome files are missing. Please check errors above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
