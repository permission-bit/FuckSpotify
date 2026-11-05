# Contributing

Thanks for taking an interest in OfflineMusic.

## Before opening a pull request

- Read the English documentation in `README.md` and the relevant technical
  guide.
- Do not commit music files, API keys, certificates, tokens, Keychain exports,
  Xcode user data or personal playlists.
- Keep the iOS app offline-first and preserve the local HTTPS security model.
- Add or update tests for behavior changes.
- Run `git diff --check` and the relevant Python/Swift test scripts.

## Pull requests

Describe the user-visible change, test coverage and any device testing that
could not be performed. Keep unrelated formatting or generated files out of a
pull request. Changes to pairing, TLS, file validation or authorization should
include a short security rationale.

## Licensing

The project does not have an open-source license yet. Until a `LICENSE` file is
added, contributions are accepted for review but redistribution rights are not
granted by this repository.
