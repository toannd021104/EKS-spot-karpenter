# Contributing

This is a personal learning and talk project, but issues and small pull requests are welcome.

1. Open an issue first for anything bigger than a typo.
2. Keep the change small and focused. Match the existing style (see `.editorconfig`).
3. Run the offline checks before you push: `make fmt lint test validate`
   (and `make deck deck-verify` if you touch `presentation/`).
4. Never run `terraform apply` or `destroy` in a pull request, and never commit credentials,
   state files or real account ids (see [SECURITY.md](SECURITY.md)).
5. Use conventional commit messages (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`).
6. Numbers in the deck come only from `results/summary.json`. Do not type measurements by hand.

By contributing you agree that your work is released under the [MIT License](LICENSE).
