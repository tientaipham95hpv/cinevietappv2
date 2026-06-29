# CineViet v2 QA Checklist

Use this checklist for `staging` and `release` artifacts.

## Build Identity

- [ ] Confirm `BUILD_INFO.txt` exists.
- [ ] Confirm channel is correct: `internal`, `staging`, or `release`.
- [ ] Confirm version/build number matches artifact filename.
- [ ] Confirm commit matches the expected GitHub branch.

## Android Mobile / Tablet

- [ ] App opens without crash on first launch.
- [ ] Login and logout work.
- [ ] Home loads hero, rows, posters, and continue watching.
- [ ] Search opens a movie detail page.
- [ ] Movie detail shows description, cast/director avatars, servers, and episodes.
- [ ] Player starts a normal source.
- [ ] Player can pause, seek, change fit mode, and resume.
- [ ] Source selector opens and switches Auto/source/quality.
- [ ] Runtime source fallback keeps the last watch position.
- [ ] Background/resume keeps player state.
- [ ] Volume and brightness gestures work on supported devices.
- [ ] Playback events appear in `/admin/playback-events`.

## Android TV

- [ ] App opens on TV/box.
- [ ] Remote D-pad focus is visible and predictable.
- [ ] Enter/Select opens detail and starts playback.
- [ ] Player controls are usable with remote.
- [ ] Source selector is usable with remote.
- [ ] Previous/next episode controls work.
- [ ] Back exits player safely.
- [ ] Playback events show `android_tv` platform in admin.

## iOS / iPadOS

- [ ] App opens without crash.
- [ ] Login works.
- [ ] Home/detail/player layout fits iPhone and iPad.
- [ ] Player starts, pauses, seeks, and resumes.
- [ ] Source selector switches source/quality.
- [ ] Background/resume behaves correctly.
- [ ] Playback events show `ios` platform in admin.

## Windows

- [ ] ZIP extracts and app starts.
- [ ] Google login protocol helper script is present.
- [ ] Window resizing does not break layout.
- [ ] Home/detail/player work with mouse and keyboard.
- [ ] Player source selector works.
- [ ] Playback events show `windows` platform in admin.

## Failure UX

- [ ] Dead source shows recovery notice before final error.
- [ ] Error panel shows retry, change source, and report buttons.
- [ ] Report button writes telemetry or user report.
- [ ] No raw technical stack trace is shown to users.

## Release Decision

- [ ] No blocker found.
- [ ] Known issues documented in release notes.
- [ ] Smoke tested on at least one real Android phone.
- [ ] Smoke tested on at least one Android TV/box before public release.
