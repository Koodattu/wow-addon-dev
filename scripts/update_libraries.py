"""Verify or update explicitly managed, vendored libraries from stable GitHub tags."""

import argparse
import fnmatch
import hashlib
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(".github/vendor-libraries.json")
VERSION = re.compile(r"v?(\d+)\.(\d+)\.(\d+)$")


def git(*args):
    return subprocess.check_output(["git", *args])


def normalized(data):
    return data.replace(b"\r\n", b"\n")


def digest(data):
    return hashlib.sha256(normalized(data)).hexdigest()


def safe_path(root, relative):
    path = PurePosixPath(relative)
    if not relative or "\\" in relative or ":" in relative or path.is_absolute() or ".." in path.parts or relative == ".":
        raise ValueError(f"Invalid managed path: {relative}")
    result = root.joinpath(*path.parts)
    if not result.resolve().is_relative_to(root.resolve()) or result.is_symlink():
        raise ValueError(f"Managed path escapes its directory: {relative}")
    return result


def verify_local(root, library):
    destination = safe_path(root, library["destination"])
    files = {}
    for name, expected in library["files"].items():
        path = safe_path(destination, name)
        if not path.is_file() or digest(path.read_bytes()) != expected:
            raise ValueError(f"{library['name']}: local modification or missing file: {name}")
        files[name] = path.read_bytes()
    return files


def validate_files(files, luac=None):
    if not files or "LICENSE.txt" not in files:
        raise ValueError("Library snapshot must include files and LICENSE.txt")
    for name, data in files.items():
        references = []
        if name.endswith(".xml"):
            document = ET.fromstring(data)
            references = [node.attrib["file"] for node in document.iter()
                          if node.tag.rsplit("}", 1)[-1] in {"Script", "Include"} and "file" in node.attrib]
        elif name.endswith(".toc"):
            references = [line.strip() for line in data.decode("utf-8-sig").splitlines()
                          if line.strip() and not line.lstrip().startswith("#")]
        for reference in references:
            target = PurePosixPath(name).parent / reference.replace("\\", "/")
            if target.as_posix() not in files:
                raise ValueError(f"{name}: missing or unmanaged load reference: {reference}")
    if luac:
        with tempfile.TemporaryDirectory(prefix="wow-library-syntax-") as directory:
            for name, data in files.items():
                if name.endswith(".lua"):
                    path = safe_path(Path(directory), name)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    subprocess.run([luac, "-p", str(path)], check=True)


def latest_tag(refs):
    tags = {}
    for line in refs.splitlines():
        sha, ref = line.split()
        tag = ref.removeprefix("refs/tags/").removesuffix("^{}")
        match = VERSION.fullmatch(tag)
        if match:
            version = tuple(map(int, match.groups()))
            if tag not in tags or ref.endswith("^{}"):
                tags[tag] = (version, sha)
    if not tags:
        raise ValueError("Upstream has no stable semantic-version tags")
    tag = max(tags, key=lambda name: tags[name][0])
    return tag, tags[tag][1]


def fetch_upstream(library):
    repository = library["repository"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError(f"Invalid GitHub repository: {repository}")
    url = f"https://github.com/{repository}.git"
    tag, commit = latest_tag(git("ls-remote", "--tags", url).decode())
    if tag == library["tag"]:
        if commit != library["commit"]:
            raise ValueError(f"{library['name']}: pinned tag {tag} moved upstream; review required")
        return tag, commit, None
    current_version = tuple(map(int, VERSION.fullmatch(library["tag"]).groups()))
    if tuple(map(int, VERSION.fullmatch(tag).groups())) <= current_version:
        raise ValueError(f"{library['name']}: refusing an upstream downgrade")
    with tempfile.TemporaryDirectory(prefix="wow-library-fetch-") as directory:
        git("init", "--quiet", directory)
        git("-C", directory, "fetch", "--quiet", "--depth=1", url, commit)
        names = git("-C", directory, "ls-tree", "-r", "--name-only", commit).decode().splitlines()
        files = {name: git("-C", directory, "show", f"{commit}:{name}") for name in names
                 if any(fnmatch.fnmatchcase(name, pattern) for pattern in library["include"])}
    return tag, commit, files


def run(root, update=False, luac=None, fetch=fetch_upstream):
    manifest_path = root / MANIFEST
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest["schemaVersion"] != 1:
        raise ValueError("Unsupported library manifest version")
    plans = []
    summary = []
    # Validate every library before changing any files.
    for library in manifest["libraries"]:
        local_files = verify_local(root, library)
        validate_files(local_files, luac)
        if not update:
            continue
        tag, commit, files = fetch(library)
        if files is None:
            continue
        destination = safe_path(root, library["destination"])
        for name in files:
            path = safe_path(destination, name)
            if name not in local_files and path.exists():
                raise ValueError(f"{library['name']}: update would overwrite unmanaged file: {name}")
        validate_files(files, luac)
        summary.append(f"- **{library['name']}**: {library['tag']} -> {tag} "
                       f"([upstream changes](https://github.com/{library['repository']}/compare/{library['commit']}...{commit}))")
        plans.append((library, destination, files, tag, commit))
    for library, destination, files, tag, commit in plans:
        for name in library["files"].keys() - files.keys():
            safe_path(destination, name).unlink()
        for name, data in files.items():
            path = safe_path(destination, name)
            if not path.exists() or normalized(path.read_bytes()) != normalized(data):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(normalized(data))
        library.update(tag=tag, commit=commit, files={name: digest(data) for name, data in sorted(files.items())})
    if plans:
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="Fetch newer stable tags and update managed files")
    parser.add_argument("--luac", help="Lua 5.1 compiler executable for syntax checks")
    parser.add_argument("--summary", type=Path, help="Write the update PR body to this file")
    args = parser.parse_args()
    summary = run(ROOT, args.update, args.luac)
    if args.summary:
        args.summary.write_text("Automated update of vendored addon libraries.\n\n" + "\n".join(summary) +
                               "\n\nFile hashes and XML/TOC references were checked. " +
                               ("Lua syntax was checked. " if args.luac else "Lua syntax was not checked. ") +
                               "Review the upstream changes and test the addon in WoW before merging.\n", encoding="utf-8")
    print("\n".join(summary) if summary else "Managed libraries verified; no changes.")
    if not args.luac:
        print("Lua syntax was not checked; use --luac luac5.1 to include it.")


if __name__ == "__main__":
    main()
