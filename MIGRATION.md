# Repository split provenance

- Source monorepo main: `9658697c429a0f9690d9068bcc9e8432aef21a06`
- Disposable WIP snapshot: `339359e729b347ef1e922a78e294e095d90ac6b3`
- Filtered iOS main: `98de034afbfc80aaaff95ddc87f9da228ab90509` before standalone-root fixes
- Source subtree: `apps/ios/`, moved to repository root
- Root workflow retained: `ios-shared-export-check.yml`
- Tool: `git-filter-repo 2.47.0` (`git_filter_repo.py` SHA-256 `67447413e273fc76809289111748870b6f6072f08b17efe94863a92d810b7d94`)

The disposable snapshot exactly reproduced the original working tree: 30 modified tracked files, 1534 tracked deletions and 66 untracked product files. The filtered tree was compared object-for-object with that snapshot.

`archive/legacy-ios` is a disconnected, filtered local recovery branch derived from source tag `legacy/ios-pr13-2026-08-23` (`1fbe173fe420fab51ab3a321c1d803de8f4bbada`). Publishing that branch is a separate decision and is not required by the iOS build.
