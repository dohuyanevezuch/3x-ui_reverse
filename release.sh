#!/usr/bin/env bash
# Выпуск новой версии 3x-ui_reverse.
#   ./release.sh v8.0.1 "Короткое описание изменений"
# Делает: VERSION= в скрипте -> проверки -> коммит -> аннотированный тег -> push
# ветки и тега -> GitHub Release (если установлен и авторизован gh). Тег всегда
# указывает на коммит, где VERSION совпадает с именем тега: на этом построена
# проверка обновлений в самом скрипте.
set -euo pipefail

SCRIPT=3x-ui_reverse_install.sh
BRANCH=main
TAG=${1:-}
NOTES=${2:-}

die(){ printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "версия в формате v1.2.3, например: ./release.sh v8.0.1 \"исправления\""
[[ -f "$SCRIPT" ]] || die "запускай из корня репозитория (не найден $SCRIPT)"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || die "переключись на ветку $BRANCH"
if ! git diff --quiet -- . ":!$SCRIPT" || ! git diff --cached --quiet; then
  die "есть незакоммиченные изменения кроме $SCRIPT — закоммить их отдельно"
fi
git fetch --quiet --tags origin
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "тег $TAG уже существует — теги не переиспользуются, возьми следующий номер"
fi

current=$(sed -n 's/^VERSION=//p' "$SCRIPT")
[[ -n "$current" ]] || die "в $SCRIPT нет строки VERSION="
latest=$(git tag -l 'v[0-9]*' | sort -V | tail -n1)
if [[ -n "$latest" && "$(printf '%s\n%s\n' "$latest" "$TAG" | sort -V | tail -n1)" != "$TAG" ]]; then
  die "$TAG должен быть больше последнего тега $latest"
fi

sed -i "s/^VERSION=.*/VERSION=$TAG/" "$SCRIPT"
grep -qx "VERSION=$TAG" "$SCRIPT" || die "не удалось записать VERSION"
bash -n "$SCRIPT" || die "синтаксическая ошибка в $SCRIPT"
if command -v shellcheck >/dev/null; then
  shellcheck -S error "$SCRIPT" || die "shellcheck нашёл ошибки"
fi

git add "$SCRIPT"
# VERSION may already equal the tag (first release): then tag the current commit.
if ! git diff --cached --quiet; then
  git commit -m "$TAG${NOTES:+: $NOTES}"
fi
git tag -a "$TAG" -m "$TAG${NOTES:+: $NOTES}"
git push origin "$BRANCH"
git push origin "$TAG"

if command -v gh >/dev/null && gh release create "$TAG" --title "$TAG" --notes "${NOTES:-$TAG}" --latest; then
  :
else
  printf 'Release не создан автоматически: тег уже опубликован, Release можно оформить на GitHub (Releases → Draft a new release → %s).\n' "$TAG"
fi
printf '✓ Выпущена %s (было VERSION=%s)\n' "$TAG" "$current"
