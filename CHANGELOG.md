# Changelog

All notable changes to gent will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-11

### Added
- Initial release of gent — an extensible coding agent built as a lisp machine
- Janet-powered agent loop with TUI rendering
- Built-in tools: read_file, edit_file, list_files, bash, eval_janet, parinfer, prompt_user
- Emacs-style hook system (before/after tool calls, responses, errors)
- Slash commands (/help, /compact, /profile, /session, etc.)
- Skill discovery from `.gent/skills/` and `.agents/skills/`
- Session persistence with append-only s-expression logs
- User config via `~/.gent/init.janet` and project config via `.gent/init.janet`
- Embedded build mode (`--features embedded`) for single-binary distribution
- Nix flake with dev shell, packages, and parinfer check
- Span-based profiling system with Chrome Trace Event export
