#!/usr/bin/env bash
# Орфей на чистом Omarchy: одна команда ставит всё окружение. Это Workstation (темы, щит, шрифты, заставки,
# русское меню, раскладки, автообновление), знак на экранах загрузки и входа, меню Limine, мессенджер
# для Linux, локальный ИИ и диктовка. Инструкция для людей — docs/setup.md.
#
#   curl -fsSL <адрес из docs/setup.md> | bash             вопросы в начале, дальше само
#   curl -fsSL <адрес> | bash -s -- --yes                   без вопросов, на всё «да»
#   bash setup.sh [--yes] [--skip=boot,limine,messenger,dictation,ai]
#
# Выпуск Workstation и пакет мессенджера ставятся только после проверки подписи ключами выпусков
# из профиля поставки. В свежем выпуске Workstation лежит свой setup.sh, и после проверки архива
# работа продолжается им. Поэтому файл в корне канала (workstation-setup.sh, меняется редко) ставит всё
# по правилам последнего выпуска.
set -euo pipefail

# >>> вписывает tools/bake-setup.sh
# Файл для выпуска собирается из tenant/<id>.vars: канал и ключи выпусков, префикс путей Workstation,
# вывески. В рабочей копии значения приходят из окружения, их же передаёт вторая ступень.
ORPHEUS_RELEASE_CHANNEL="github:metodex-tech/orpheus-releases"
ORPHEUS_RELEASE_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII9E5tqDvGsxG1lKNKw4dvmXP0LEH9RPWNIAvsMSw4Fe orpheus-release"
ORPHEUS_IDS_WORKSTATION="orpheus-omarchy"
ORPHEUS_TITLES_WORKSTATION="Orpheus Workstation"
ORPHEUS_TITLES_MESSENGER="Мессенджер Orpheus"
# <<< вписывает tools/bake-setup.sh

# >>> вписывает channel.sh
# shellcheck shell=bash
# Канал выпусков по договору workflow/release/README.md: список выпусков, манифест, подпись. Подключают
# install.sh (обновление) и setup.sh (установка на чистый Omarchy); в файл установки для выпуска
# tools/bake-setup.sh вписывает этот файл целиком. Здесь только функции, без побочных действий.
#
# Канал и ключи — из профиля поставки: ORPHEUS_RELEASE_CHANNEL (github:<владелец>/<репозиторий>, канал-каталог
# https://…/ или file://…/) и ORPHEUS_RELEASE_KEYS (ssh-ed25519 <base64> [имя] через запятую).

# Принципал и пространство имён подписи выпусков — по договору канала.
SIG_NS=orpheus-release
# Только для проверок: API GitHub подменяется каталогом file://.
GITHUB_API=${ORPHEUS_GITHUB_API:-https://api.github.com}

# Список выпусков: у github: — ответ API, у канала-каталога (в том числе флешка в закрытом контуре) —
# releases.json.
channel_index() {
  case $1 in
  github:?*/?*) curl -fsSL --max-time 30 "$GITHUB_API/repos/${1#github:}/releases?per_page=100" ;;
  https://?* | file://?*) curl -fsSL --max-time 30 "${1%/}/releases.json" ;;
  *) return 2 ;;
  esac
}

# Старшая стабильная версия по меткам <префикс><версия>: без черновиков и pre-release.
latest_version() {
  jq -r --arg p "$2" '(if type == "array" then map({tag: .tag_name, pre: (.prerelease or .draft)})
      else [.releases[] | {tag, pre: .prerelease}] end)
    | .[] | select(.pre | not) | .tag | select(startswith($p)) | ltrimstr($p)' <<<"$1" 2>/dev/null |
    grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -n1 || true
}

# Адрес файла выпуска: у GitHub — из того же ответа API, у каталога — <канал><метка>/<файл>.
release_url() {
  local channel=$1 index=$2 tag=$3 name=$4
  case $channel in
  github:*)
    jq -r --arg t "$tag" --arg n "$name" \
      'first(.[] | select(.tag_name == $t) | .assets[] | select(.name == $n) | .browser_download_url) // empty' <<<"$index"
    ;;
  *) printf '%s/%s/%s\n' "${channel%/}" "$tag" "$name" ;;
  esac
}

fetch() { curl -fsSL --retry 3 --max-time "${3:-600}" -o "$2" "$1"; }

# allowed_signers в файл $1 из ORPHEUS_RELEASE_KEYS; путь запоминается в SIGNERS.
make_signers() {
  local key
  SIGNERS=$1
  : >"$SIGNERS"
  while read -r key; do
    [[ $key == ssh-ed25519\ * ]] || continue
    printf '%s namespaces="%s" %s\n' "$SIG_NS" "$SIG_NS" "$(cut -d' ' -f1,2 <<<"$key")" >>"$SIGNERS"
  done < <(tr ',' '\n' <<<"${ORPHEUS_RELEASE_KEYS:-}")
  [[ -s $SIGNERS ]]
}

verify_sig() { ssh-keygen -Y verify -f "$SIGNERS" -I "$SIG_NS" -n "$SIG_NS" -s "$2" <"$1" >/dev/null 2>&1; }

# Выпуск по манифесту: подпись ключом профиля, продукт, канал stable и версия из метки; затем
# единственный файл с расширением $5, его размер и SHA-256 из манифеста. Путь — в FETCHED, причина
# отказа — в REASON.
manifest_fetch() {
  local channel=$1 index=$2 id=$3 ver=$4 ext=$5 dir=$6 tag url sig name size sha
  tag=$id-v$ver
  mkdir -p "$dir"
  url=$(release_url "$channel" "$index" "$tag" manifest.json)
  sig=$(release_url "$channel" "$index" "$tag" manifest.json.sig)
  if [[ -z $url || -z $sig ]]; then
    REASON="в выпуске $tag нет манифеста или подписи"
    return 1
  fi
  if ! fetch "$url" "$dir/manifest.json" 60 || ! fetch "$sig" "$dir/manifest.json.sig" 60; then
    REASON="манифест $tag не скачался"
    return 1
  fi
  if ! verify_sig "$dir/manifest.json" "$dir/manifest.json.sig"; then
    REASON="подпись манифеста $tag не сошлась, выпуск не поставлен"
    return 1
  fi
  if ! jq -e --arg id "$id" --arg v "$ver" '.schema == 1 and .product == $id and .version == $v and .channel == "stable"' \
    "$dir/manifest.json" >/dev/null 2>&1; then
    REASON="манифест $tag описывает другой выпуск"
    return 1
  fi
  read -r name size sha < <(jq -r --arg e "$ext" '[.files[] | select(.name | endswith($e))]
    | if length == 1 then .[0] | "\(.name) \(.size) \(.sha256)" else empty end' "$dir/manifest.json") || true
  # Имя файла из манифеста становится путём на диске: только простое имя.
  if [[ ! ${name:-} =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || ! ${size:-} =~ ^[0-9]+$ || ! ${sha:-} =~ ^[0-9a-f]{64}$ ]]; then
    REASON="в манифесте $tag нет единственного файла $ext"
    return 1
  fi
  url=$(release_url "$channel" "$index" "$tag" "$name")
  if [[ -z $url ]] || ! fetch "$url" "$dir/$name"; then
    REASON="$name не скачался"
    return 1
  fi
  if [[ $(stat -c %s "$dir/$name") != "$size" || $(sha256sum "$dir/$name" | cut -d' ' -f1) != "$sha" ]]; then
    REASON="$name не совпал с манифестом по размеру или SHA-256, не поставлен"
    return 1
  fi
  FETCHED=$dir/$name
}
# <<< вписывает channel.sh

# id продуктов в реестре канала (workflow/repos.toml) общие для всех поставок.
WS_ID=workstation
MSG_ID=messenger-linux
MSG_EXT=.pkg.tar.zst
# Только для проверок: системный корень — песочница.
MEMINFO=${ORPHEUS_SYSROOT:-}/proc/meminfo
STEPS=(workstation boot limine messenger dictation ai)

say() { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  exit 1
}

# ── выпуск Workstation ────────────────────────────────────────────────────────

# Распаковывает архив Workstation и проверяет, что внутри та версия и установщик.
ws_unpack() {
  local archive=$1 ver=$2
  rm -rf -- "$WORK/ws"
  mkdir -p "$WORK/ws"
  if ! tar -xzf "$archive" -C "$WORK/ws" --no-same-owner 2>/dev/null ||
    [[ $(cat "$WORK/ws/$ORPHEUS_IDS_WORKSTATION/VERSION" 2>/dev/null) != "$ver" ||
      ! -x $WORK/ws/$ORPHEUS_IDS_WORKSTATION/install.sh ]]; then
    REASON="архив $WS_TITLE $ver устроен не так, как ожидалось"
    return 1
  fi
  WS_DIR=$WORK/ws/$ORPHEUS_IDS_WORKSTATION
  WS_VERSION=$ver
}

# Последний выпуск Workstation в канале: метки workstation-v*, архив по манифесту.
ws_fetch() {
  local index ver
  if ! index=$(channel_index "$ORPHEUS_RELEASE_CHANNEL"); then
    REASON="канал $ORPHEUS_RELEASE_CHANNEL не ответил"
    return 1
  fi
  ver=$(latest_version "$index" "$WS_ID-v")
  if [[ -z $ver ]]; then
    REASON="в канале $ORPHEUS_RELEASE_CHANNEL нет выпусков $WS_TITLE"
    return 1
  fi
  manifest_fetch "$ORPHEUS_RELEASE_CHANNEL" "$index" "$WS_ID" "$ver" .tar.gz "$WORK/dl" || return 1
  ws_unpack "$FETCHED" "$ver"
}

# ── вопросы ───────────────────────────────────────────────────────────────────

# Вопрос с ответом «да» по умолчанию. Ответ читается с терминала: при curl | bash стандартный ввод
# занят самим скриптом.
ask() {
  local answer=""
  ((ASSUME_YES)) && return 0
  printf '%s [Д/н] ' "$1" >/dev/tty
  read -r answer </dev/tty || true
  [[ -z $answer || ${answer,,} == д* || ${answer,,} == y* ]]
}

# План шага: on — ставить, skip — нет, с причиной для отчёта.
plan() {
  PLAN[$1]=$2
  WHY[$1]=${3:-}
}

skipped_by_flag() { [[ ,$SKIP, == *",$1,"* ]]; }

# Решает, что ставить, и задаёт все вопросы сразу: потом установка идёт без человека.
make_plan() {
  local kib set line size name
  plan workstation on
  if skipped_by_flag boot; then plan boot skip "ключ --skip"; elif ask \
    "Знак на экранах расшифровки диска и входа? Нужен пароль, Omarchy пересоберёт initramfs"; then plan boot on; else plan boot skip "отказ"; fi
  if skipped_by_flag limine; then plan limine skip "ключ --skip"; elif ask \
    "Перекрасить меню загрузчика Limine? Копия прежнего файла сохранится"; then plan limine on; else plan limine skip "отказ"; fi

  MSG_INDEX=$(channel_index "$ORPHEUS_RELEASE_CHANNEL" 2>/dev/null) || MSG_INDEX=""
  MSG_VERSION=$(latest_version "$MSG_INDEX" "$MSG_ID-v")
  if skipped_by_flag messenger; then
    plan messenger skip "ключ --skip"
  elif [[ -z $MSG_INDEX ]]; then
    plan messenger skip "канал $ORPHEUS_RELEASE_CHANNEL не ответил"
  elif [[ -z $MSG_VERSION ]]; then
    plan messenger skip "в канале ещё нет выпуска для Linux"
  elif ask "Поставить $MSG_TITLE $MSG_VERSION (пакет Arch, пароль)?"; then
    plan messenger on
  else
    plan messenger skip "отказ"
  fi

  kib=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null || echo 0)
  set=$(python3 "$WS_DIR/ai/manifest.py" "$WS_DIR/ai/manifest.toml" pick "${kib:-0}" 2>/dev/null) || set=""
  if skipped_by_flag ai; then
    plan ai skip "ключ --skip"
  elif [[ ! -f $WS_DIR/ai/manifest.toml ]]; then
    plan ai skip "в этой версии $WS_TITLE нет локального ИИ"
  elif [[ -z $set ]]; then
    plan ai skip "мало памяти: локальной модели нужно 16 ГБ и больше, здесь $((${kib:-0} / 1048576)) ГБ"
  else
    line=$(python3 "$WS_DIR/ai/manifest.py" "$WS_DIR/ai/manifest.toml" model "$set" 2>/dev/null) || line=""
    IFS=$'\t' read -r _ _ _ size name <<<"$line" || true
    if ask "Локальный ИИ без сети: ${name:-модель} по объёму памяти, скачать около $(((${size:-0} + 500000000) / 1000000000)) ГБ?"; then
      plan ai on
    else
      plan ai skip "отказ"
    fi
  fi
  if skipped_by_flag dictation; then
    plan dictation skip "ключ --skip"
  elif [[ ${PLAN[ai]} != on ]]; then
    plan dictation skip "без локального ИИ"
  elif command -v voxtype >/dev/null; then
    plan dictation on "voxtype уже стоит"
  elif [[ -z $TTY ]]; then
    plan dictation skip "установщик voxtype Omarchy спрашивает в терминале; позже: меню Omarchy → Install → Dictation и install.sh ai on"
  elif ask "Русская диктовка голосом (voxtype)? Установщик Omarchy переспросит: Enter или подождать 15 секунд"; then
    plan dictation on
  else
    plan dictation skip "отказ"
  fi
}

# ── шаги ──────────────────────────────────────────────────────────────────────

# Итог шага: ok, skip или fail с причиной, для отчёта.
result() {
  DONE[$1]=$2
  [[ -z ${3:-} ]] || WHY[$1]=$3
}

step_workstation() {
  say "$WS_TITLE $WS_VERSION"
  # Вопросы про экран загрузки и Limine install.sh all задаёт сам и читает ответы со стандартного ввода:
  # он отвечает «нет», и эти шаги идут ниже отдельно, со своим итогом. Так понимают и прежние выпуски.
  if bash "$WS_DIR/install.sh" all < <(yes н) && [[ -x $RELEASES/current/install.sh ]]; then
    result workstation ok
  else
    result workstation fail "install.sh all не прошёл, журнал выше"
  fi
}

step_boot() {
  if "$RELEASES/current/install.sh" boot </dev/null; then result boot ok; else result boot fail "install.sh boot не прошёл"; fi
}

step_limine() {
  if "$RELEASES/current/install.sh" limine </dev/null; then
    result limine ok
  else
    result limine fail "install.sh limine не прошёл (загрузчик не Limine или раздел EFI смонтирован иначе)"
  fi
}

step_messenger() {
  local pkg name ver have
  say "$MSG_TITLE $MSG_VERSION"
  if ! manifest_fetch "$ORPHEUS_RELEASE_CHANNEL" "$MSG_INDEX" "$MSG_ID" "$MSG_VERSION" "$MSG_EXT" "$WORK/messenger"; then
    result messenger fail "$REASON"
    return
  fi
  pkg=$FETCHED
  read -r name ver < <(pacman -Qp "$pkg" 2>/dev/null) || true
  if [[ -z ${name:-} ]]; then
    result messenger fail "pacman не прочитал пакет $(basename "$pkg")"
    return
  fi
  have=$(pacman -Q "$name" 2>/dev/null | cut -d' ' -f2) || true
  if [[ -n $have ]] && (($(vercmp "$have" "$ver") >= 0)); then
    result messenger ok "уже стоит $name $have"
    return
  fi
  note "Пакет $name $ver проверен по подписи манифеста, ставлю: спросит пароль администратора."
  if sudo pacman -U --noconfirm --needed "$pkg" </dev/null; then
    result messenger ok "$name $ver"
  else
    result messenger fail "pacman -U не поставил $name $ver"
  fi
}

step_dictation() {
  if command -v voxtype >/dev/null; then
    result dictation ok "voxtype есть, локальную модель к нему подключит шаг ИИ"
    return
  fi
  say "Диктовка voxtype: установщик Omarchy"
  # Согласие уже получено в начале. Свой вопрос установщик Omarchy задаёт через gum, и тот через
  # 15 секунд сам отвечает «да», иначе установка без человека встала бы здесь.
  GUM_CONFIRM_TIMEOUT=15s omarchy-voxtype-install </dev/tty >/dev/tty 2>&1 || true
  if command -v voxtype >/dev/null; then
    result dictation ok "voxtype поставлен"
  else
    result dictation fail "voxtype не поставился; позже: меню Omarchy → Install → Dictation и install.sh ai on"
  fi
}

step_ai() {
  local out=/dev/stdout
  # Модель весит больше 10 ГБ: ход загрузки curl рисует только в терминале, а не в журнале.
  [[ -n $TTY ]] && out=$TTY
  if "$RELEASES/current/install.sh" ai on </dev/null >"$out" 2>&1; then result ai ok; else result ai fail "install.sh ai on не прошёл; повтор докачает с места обрыва"; fi
}

# ── отчёт ─────────────────────────────────────────────────────────────────────

report() {
  local step mark gpu
  {
    echo "$WS_TITLE: установка на чистый Omarchy, $(date '+%F %T')"
    echo "выпуск $WS_TITLE: ${WS_VERSION:-нет}; Omarchy $(omarchy-version 2>/dev/null || echo '?'); ядро $(uname -r)"
    echo "процессор: $(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -n1)"
    gpu=$(lspci 2>/dev/null | grep -E 'VGA|3D|Display' | cut -d: -f3- | sed 's/^ *//' | paste -sd ';' -)
    echo "видео: ${gpu:-?}; память: $(($(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null || echo 0) / 1048576)) ГБ"
    echo "экран: $(hyprctl monitors 2>/dev/null | sed -n 's/^\s*\([0-9]*x[0-9]*\)@.*/\1/p' | paste -sd ' ' -)"
    echo "свободно в домашнем каталоге: $(df -h --output=avail "$HOME" | tail -n1 | tr -d ' ')"
    echo
    for step in "${STEPS[@]}"; do
      case ${DONE[$step]:-${PLAN[$step]:-skip}} in
      ok) mark="готово" ;;
      fail) mark="НЕ ВСТАЛО" ;;
      on) mark="не дошло" ;;
      *) mark="пропущено" ;;
      esac
      printf '%-11s %-11s %s\n' "$step" "$mark" "${WHY[$step]:-}"
    done
    echo
    if [[ -x $RELEASES/current/install.sh ]]; then
      "$RELEASES/current/install.sh" status 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    fi
  } >"$REPORT"
}

cleanup() { rm -rf -- "${WORK:?}"; }

main() {
  local arg step
  ASSUME_YES=0
  SKIP=""
  for arg in "$@"; do
    case $arg in
    --yes | -y) ASSUME_YES=1 ;;
    --skip=*) SKIP=${arg#--skip=} ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//'
      return 0
      ;;
    *) die "Неизвестный ключ $arg. Ключи: --yes, --skip=boot,limine,messenger,dictation,ai" ;;
    esac
  done

  [[ $EUID -ne 0 ]] || die "Запускать от своего пользователя, без sudo: пароль спросят там, где он нужен."
  [[ -n $ORPHEUS_RELEASE_KEYS && -n $ORPHEUS_RELEASE_CHANNEL && -n $ORPHEUS_IDS_WORKSTATION ]] ||
    die "Нет канала или ключей выпусков: этот файл не из выпуска. Адрес — в docs/setup.md."
  WS_TITLE=${ORPHEUS_TITLES_WORKSTATION:-Workstation}
  MSG_TITLE=${ORPHEUS_TITLES_MESSENGER:-мессенджер}
  command -v omarchy-theme-set >/dev/null || die "Не найдена команда omarchy-theme-set: это не Omarchy."
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] ||
    die "Нужен рабочий стол Omarchy: запусти команду в его терминале (Super + Enter), а не по ssh."
  TTY=""
  if { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
  ((ASSUME_YES)) || [[ -n $TTY ]] || die "Нет терминала для вопросов. Без вопросов: ... | bash -s -- --yes"

  STATE=$HOME/.local/state/$ORPHEUS_IDS_WORKSTATION
  RELEASES=$HOME/.local/share/$ORPHEUS_IDS_WORKSTATION-releases
  REPORT=$STATE/setup-report.txt
  mkdir -p "$STATE"
  declare -gA PLAN=() WHY=() DONE=()

  if [[ -z ${ORPHEUS_SETUP_SOURCE:-} ]]; then
    # Журнал целиком, вторая ступень пишет в тот же поток.
    exec > >(tee -a "$STATE/setup.log") 2>&1
    say "Установка на чистый Omarchy: $WS_TITLE и всё, что к нему прилагается"
    local need=()
    command -v curl >/dev/null || need+=(curl)
    command -v jq >/dev/null || need+=(jq)
    command -v ssh-keygen >/dev/null || need+=(openssh)
    command -v python3 >/dev/null || need+=(python)
    if ((${#need[@]})); then
      note "Не хватает ${need[*]}, ставлю: спросит пароль администратора."
      omarchy-pkg-add "${need[@]}" || die "Не поставились ${need[*]}: нужен интернет."
    fi
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/orpheus-setup.XXXXXX")
    trap cleanup EXIT
    make_signers "$WORK/allowed_signers" || die "В профиле нет ключей ssh-ed25519 для проверки выпусков."
    note "Скачиваю последний выпуск и проверяю подпись"
    ws_fetch || die "$WS_TITLE не скачан: $REASON."
    note "$WS_TITLE $WS_VERSION: подпись верна"
    # Вторая ступень получает проверенный архив и значения первой через окружение. Это договор между
    # выпусками: файл в корне канала меняется редко и может быть старше архива.
    if [[ -f $WS_DIR/setup.sh ]]; then
      trap - EXIT
      export ORPHEUS_RELEASE_CHANNEL ORPHEUS_RELEASE_KEYS ORPHEUS_IDS_WORKSTATION ORPHEUS_TITLES_WORKSTATION \
        ORPHEUS_TITLES_MESSENGER ORPHEUS_GITHUB_API=$GITHUB_API
      ORPHEUS_SETUP_SOURCE=$WS_DIR ORPHEUS_SETUP_WORK=$WORK ORPHEUS_SETUP_VERSION=$WS_VERSION \
        exec bash "$WS_DIR/setup.sh" "$@"
    fi
  else
    # Вторая ступень: архив уже проверен первой.
    WS_DIR=$ORPHEUS_SETUP_SOURCE
    WORK=${ORPHEUS_SETUP_WORK:?}
    WS_VERSION=${ORPHEUS_SETUP_VERSION:?}
    trap cleanup EXIT
    make_signers "$WORK/allowed_signers" || die "В профиле нет ключей ssh-ed25519 для проверки выпусков."
  fi

  make_plan
  # Пароль спрашивается один раз в начале, пока человек у экрана: шрифты нужны всегда, а долгая
  # загрузка модели идёт последней и без пароля.
  if [[ -n $TTY ]]; then
    note "Пароль администратора нужен для шрифтов, экранов загрузки, Limine и пакетов."
    sudo -v <"$TTY" || true
  fi

  step_workstation
  for step in boot limine messenger dictation ai; do
    [[ ${PLAN[$step]} == on ]] || continue
    if [[ $step != messenger && ${DONE[workstation]} != ok ]]; then
      result "$step" fail "не поставлен $WS_TITLE"
      continue
    fi
    "step_$step"
  done

  report
  echo
  say "Итог"
  sed -n '/^$/,/^$/p' "$REPORT" | sed '/^$/d' | sed 's/^/  /'
  echo
  note "Отчёт: $REPORT, журнал: $STATE/setup.log."
  note "Повторный запуск той же команды безопасен: поставленное останется, не вставшее поставится."
  if [[ ${DONE[boot]:-} == ok ]]; then note "Знак на экране загрузки появится после перезагрузки."; fi
  for step in "${STEPS[@]}"; do
    [[ ${DONE[$step]:-} != fail ]] || return 1
  done
}

main "$@"
