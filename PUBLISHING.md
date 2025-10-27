# Publishing Claudio to Hex.pm

This guide walks you through publishing the Claudio package to Hex.pm.

## Prerequisites

1. **Hex Account**: Create an account at https://hex.pm/signup
2. **Hex CLI**: Ensure Hex is installed (comes with Elixir)
3. **Git**: All changes committed and pushed

## Pre-Publication Checklist

- [x] All tests passing (`mix test --include integration`)
- [x] Code formatted (`mix format --check-formatted`)
- [x] Documentation complete (README, module docs, CHANGELOG)
- [x] LICENSE file added (MIT)
- [x] Package metadata in mix.exs
- [x] Version number set in mix.exs (0.1.0)

## Step-by-Step Publishing Process

### 1. Authenticate with Hex

First time only - authenticate your local Hex client:

```bash
mix hex.user auth
```

This will open your browser to authorize the CLI.

### 2. Verify Package Build

Build the package locally to check for issues:

```bash
mix hex.build
```

This creates `claudio-0.1.0.tar` and shows you what will be published.

Review the output carefully:
- Verify all expected files are included
- Check that dependencies are correct
- Ensure description and links are accurate

### 3. Publish to Hex

Publish the package:

```bash
mix hex.publish
```

You'll be prompted to review the package details. Type `Y` to confirm.

**What gets published:**
- All files in `lib/`
- `mix.exs`
- `README.md`
- `LICENSE`
- `CHANGELOG.md`
- `.formatter.exs`

**What does NOT get published:**
- `test/` directory
- `config/` directory
- `.git/` directory
- `doc/` directory
- Any files in `.gitignore`

### 4. Create Git Tag

After successful publication, tag the release:

```bash
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

### 5. Create GitHub Release

Go to https://github.com/thetonymaster/claudio/releases/new and:

1. Choose tag: `v0.1.0`
2. Release title: `v0.1.0 - Initial Release`
3. Copy relevant sections from CHANGELOG.md
4. Publish release

## Post-Publication

### Verify Publication

1. Visit https://hex.pm/packages/claudio
2. Check that documentation is generated (may take a few minutes)
3. Verify package metadata and links

### Update README Badges (Optional)

Add badges to README.md:

```markdown
[![Hex.pm](https://img.shields.io/hexpm/v/claudio.svg)](https://hex.pm/packages/claudio)
[![Documentation](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/claudio)
[![License](https://img.shields.io/hexpm/l/claudio.svg)](https://github.com/alexandremcosta/claudio/blob/main/LICENSE)
```

### Announce

Consider announcing on:
- Elixir Forum: https://elixirforum.com/
- ElixirWeekly: https://elixirweekly.net/
- Twitter/X with #elixirlang
- Reddit: r/elixir

## Usage After Publication

Users can now install your package:

```elixir
# mix.exs
def deps do
  [
    {:claudio, "~> 0.1.0"}
  ]
end
```

## Updating the Package

For future releases:

1. Update version in `mix.exs`
2. Update `CHANGELOG.md` with changes
3. Run tests: `mix test --include integration`
4. Commit changes
5. Run `mix hex.publish`
6. Create git tag: `git tag -a v0.x.x -m "Release v0.x.x"`
7. Push tag: `git push origin v0.x.x`
8. Create GitHub release

## Retiring a Release

If you need to retire a release:

```bash
mix hex.retire claudio 0.1.0 --reason deprecated --message "Use version 0.2.0 instead"
```

## Troubleshooting

### "Package name already taken"

If the name "claudio" is taken, you'll need to choose a different name.
Update the `:name` field in `package/0` in mix.exs.

### "Missing required fields"

Ensure mix.exs has:
- `description/0`
- `package/0` with licenses and links
- Valid version number

### "Authentication failed"

Run `mix hex.user auth` again to re-authenticate.

### Documentation not showing

- Documentation generation can take 5-10 minutes
- Check https://hexdocs.pm/claudio/
- If still missing, try republishing: `mix hex.publish --replace`

## Resources

- Hex Documentation: https://hex.pm/docs/publish
- Hex Package Guidelines: https://hex.pm/policies/codeofconduct
- ExDoc Documentation: https://hexdocs.pm/ex_doc/
- Semantic Versioning: https://semver.org/

## Quick Reference Commands

```bash
# Authenticate
mix hex.user auth

# Build package locally
mix hex.build

# Publish package
mix hex.publish

# Publish docs only
mix hex.publish docs

# Replace existing version (use with caution!)
mix hex.publish --replace

# Retire a release
mix hex.retire PACKAGE VERSION

# Unretire a release
mix hex.retire PACKAGE VERSION --unretire
```
