# Launch Kit

This file is the practical growth plan for getting `Irit` in front of users fast.

## Goal

Turn the repo into something that:

- looks credible on first visit
- is easy to star, clone, and try
- gives people a reason to share it
- converts curiosity into actual usage

## Before publishing

1. Push the current branch to `main`.
2. Enable GitHub Pages from the `docs/` folder.
3. Set the repository social preview image to `assets/social-card.svg`.
4. Pin `Irit` on your GitHub profile.
5. Add GitHub topics:
   - `xray`
   - `vless`
   - `reality`
   - `vpn`
   - `bash`
   - `ssh`
   - `server-bootstrap`
   - `devops`
   - `ubuntu`
   - `debian`
6. Turn on Discussions if you want organic community Q&A.

## High-conversion launch sequence

### Day 1

- Publish the repo.
- Push a first tagged release.
- Share the GitHub URL and GitHub Pages URL.
- Post one short technical teaser plus one visual post with the social card.

### Day 2

- Post a thread with:
  - the pain point
  - what Irit automates
  - what files it exports
  - why rollback matters
- Share a setup screenshot or short terminal clip.

### Day 3

- Post a “before vs after” comparison:
  - manual Xray setup
  - Irit flow
- Ask for edge cases, feature requests, and test feedback.

## Best channels for fast early users

- GitHub profile and pinned repositories
- Telegram communities around VPS/Xray/self-hosting
- Reddit communities related to Linux, self-hosting, privacy, and VPS
- Habr / Dev.to technical write-up
- X / Twitter short launch thread
- Discord communities around DevOps or self-hosted networking

## Ready post: English

```text
Built a small tool called Irit.

It bootstraps Xray + VLESS + REALITY over SSH, creates a checkpoint before changes, can roll back on failure, and exports a ready client bundle with the final VLESS URI.

It also has doctor/report/access modes, QR export, and local artifact download.

Repo: https://github.com/anonymmized/Irit
Pages: https://anonymmized.github.io/Irit/
```

## Ready post: Russian

```text
Сделал Irit.

Это bash-инструмент для быстрого поднятия Xray + VLESS + REALITY по SSH. Перед изменениями делает checkpoint, умеет rollback, а на выходе отдаёт готовую VLESS-ссылку и клиентский bundle.

Есть doctor/report/access режимы, QR-экспорт и локальная выгрузка артефактов.

GitHub: https://github.com/anonymmized/Irit
Pages: https://anonymmized.github.io/Irit/
```

## Conversion checklist

- README must answer “why should I care?” in the first screen.
- The repo must show CI status and license.
- The landing page must have one install path and one CTA.
- The first release should include screenshots and a changelog.
- Every visible post should include:
  - the pain point
  - the outcome
  - the GitHub URL

## Metrics to watch

- GitHub stars
- unique visitors
- clones
- release downloads
- opened issues
- access/report/setup usage feedback
