#!/bin/bash
# Pixel Open Space : prépare le projet Xcode sur ton Mac (docs/PROPOSITION.md, section 8).
# Vérifie Xcode, installe XcodeGen si besoin, crée Config/Local.xcconfig (équipe de signature), génère
# PixelOpenSpace.xcodeproj depuis project.yml et l'ouvre. Relançable sans risque : rien n'est écrasé.
# Usage : Tools/bootstrap.sh [--yes] [--team IDENTIFIANT] [--no-open]
# Compatible avec le bash 3.2 de macOS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_XCCONFIG="$REPO_ROOT/Config/Local.xcconfig"
PROJECT="PixelOpenSpace.xcodeproj"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'Attention : %s\n' "$*" >&2; }
die() {
  printf 'Erreur : %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage : Tools/bootstrap.sh [--yes] [--team IDENTIFIANT] [--no-open]

  --yes            répond oui aux questions (installation de XcodeGen, équipe détectée)
  --team ID        identifiant d'équipe Apple (10 caractères) à écrire dans Config/Local.xcconfig
  --no-open        ne pas ouvrir le projet dans Xcode à la fin
EOF
}

assume_yes=0
team=""
open_project=1
while [ $# -gt 0 ]; do
  case "$1" in
    -y | --yes) assume_yes=1 ;;
    --team)
      [ $# -ge 2 ] || die "--team attend un identifiant."
      team="$2"
      shift
      ;;
    --team=*) team="${1#--team=}" ;;
    --no-open) open_project=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "option inconnue : $1"
      ;;
  esac
  shift
done

# confirm QUESTION DEFAULT(o|n): 0 for yes. Without a terminal, the default applies (--yes forces yes).
confirm() {
  local question="$1" default="$2" answer=""
  if [ "$assume_yes" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    [ "$default" = "o" ]
    return
  fi
  if [ "$default" = "o" ]; then
    printf '%s [O/n] ' "$question"
  else
    printf '%s [o/N] ' "$question"
  fi
  read -r answer || answer=""
  case "$answer" in
    o | O | oui | Oui | OUI | y | Y | yes | Yes) return 0 ;;
    "") [ "$default" = "o" ] ;;
    *) return 1 ;;
  esac
}

valid_team() {
  printf '%s' "$1" | grep -Eq '^[A-Z0-9]{10}$'
}

# Sets detected_identity and detected_team from the first "Apple Development" signing identity.
# The team id is the certificate's OU field: the id in parentheses in the identity name is not always the team.
detect_team() {
  detected_identity=""
  detected_team=""
  command -v security >/dev/null 2>&1 || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  detected_identity="$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1 || true)"
  [ -n "$detected_identity" ] || return 1
  detected_team="$(security find-certificate -c "$detected_identity" -p 2>/dev/null |
    openssl x509 -noout -subject 2>/dev/null |
    sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1 || true)"
  [ -n "$detected_team" ]
}

find_tool() {
  local name="$1" candidate
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for candidate in "/opt/homebrew/bin/$name" "/usr/local/bin/$name"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

[ "$(uname -s)" = "Darwin" ] || die "ce script prépare le projet Xcode : il ne tourne que sur macOS."
cd "$REPO_ROOT"

step "Xcode"
command -v xcodebuild >/dev/null 2>&1 ||
  die "xcodebuild introuvable. Installe Xcode depuis l'App Store, ouvre-le une fois, puis relance ce script."
if ! xcode_version="$(xcodebuild -version 2>&1)"; then
  say "$xcode_version" >&2
  die "xcodebuild ne répond pas (seuls les outils de ligne de commande sont sélectionnés ?). Lance :
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
fi
say "$(printf '%s' "$xcode_version" | tr '\n' ' ' | sed 's/ *$//') ($(xcode-select -p 2>/dev/null || echo '?'))"
xcode_major="$(printf '%s' "$xcode_version" | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$xcode_major" ] && [ "$xcode_major" -lt 26 ]; then
  warn "Xcode 26 ou plus récent est requis (SwiftTerm demande swift-tools 6.2)."
fi

step "XcodeGen"
if xcodegen="$(find_tool xcodegen)"; then
  say "$xcodegen ($("$xcodegen" --version 2>/dev/null | head -n 1 || echo 'version inconnue'))"
else
  if brew="$(find_tool brew)"; then
    say "XcodeGen génère PixelOpenSpace.xcodeproj à partir de project.yml."
    if confirm "Installer XcodeGen avec Homebrew (brew install xcodegen) ?" n; then
      "$brew" install xcodegen
      xcodegen="$(find_tool xcodegen)" || die "XcodeGen reste introuvable après l'installation."
    else
      die "XcodeGen est nécessaire. Installe-le (brew install xcodegen), puis relance ce script."
    fi
  else
    die "XcodeGen et Homebrew sont introuvables. Installe Homebrew (https://brew.sh), puis lance
  brew install xcodegen
ou installe XcodeGen autrement (https://github.com/yonaskolb/XcodeGen), puis relance ce script."
  fi
fi

step "Signature (Config/Local.xcconfig)"
if [ -f "$LOCAL_XCCONFIG" ]; then
  current="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$LOCAL_XCCONFIG" | head -n 1)"
  say "Config/Local.xcconfig existe déjà (DEVELOPMENT_TEAM = ${current:-non défini}) : conservé."
else
  if [ -n "$team" ]; then
    team="$(printf '%s' "$team" | tr '[:lower:]' '[:upper:]')"
    valid_team "$team" || die "identifiant d'équipe invalide : « $team » (10 lettres majuscules ou chiffres)."
  else
    cat <<'EOF'
L'app doit être signée avec une identité stable (« Apple Development ») : macOS attache les autorisations
(notifications, dossiers) à la signature. Il faut pour cela l'identifiant de ton équipe Apple (Team ID,
10 caractères), écrit dans Config/Local.xcconfig, fichier propre à ce Mac et non versionné.

Où le trouver :
  - Xcode › Réglages… › Comptes : ajoute ton Apple ID si besoin (un compte gratuit donne une « Personal Team ») ;
  - https://developer.apple.com/account › Membership details › Team ID ;
  - Trousseau d'accès › ton certificat « Apple Development: … » › Unité d'organisation ;
  - `security find-identity -v -p codesigning` liste tes identités « Apple Development: … (XXXXXXXXXX) ».
    Attention : l'identifiant entre parenthèses n'est pas toujours celui de l'équipe ; la détection
    automatique ci-dessous lit l'unité d'organisation (OU) du certificat, qui est bien le Team ID.
EOF
    echo
    if detect_team; then
      say "Identité trouvée : « $detected_identity », équipe $detected_team."
      if confirm "Utiliser l'équipe $detected_team ?" o; then
        team="$detected_team"
      fi
    else
      say "Aucune identité « Apple Development » trouvée dans le trousseau."
    fi
    if [ -z "$team" ] && [ -t 0 ] && [ "$assume_yes" -ne 1 ]; then
      printf 'Identifiant d'"'"'équipe (Entrée pour passer) : '
      read -r team || team=""
      team="$(printf '%s' "$team" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
      if [ -n "$team" ] && ! valid_team "$team"; then
        die "identifiant d'équipe invalide : « $team » (10 lettres majuscules ou chiffres)."
      fi
    fi
  fi
  if [ -n "$team" ]; then
    mkdir -p "$(dirname "$LOCAL_XCCONFIG")"
    cat >"$LOCAL_XCCONFIG" <<EOF
// Réglages propres à ce Mac, créés par Tools/bootstrap.sh. Non versionné (.gitignore).
// Inclus par Config/Base.xcconfig (#include? "Local.xcconfig").
DEVELOPMENT_TEAM = $team
EOF
    say "Config/Local.xcconfig créé (DEVELOPMENT_TEAM = $team)."
  else
    warn "pas d'équipe : Config/Local.xcconfig n'est pas créé. Xcode ne pourra pas signer l'app avec une
identité stable ; relance ce script quand tu auras ton Team ID (ou passe --team)."
  fi
fi
[ -f "$REPO_ROOT/Config/Base.xcconfig" ] ||
  warn "Config/Base.xcconfig est absent : Local.xcconfig ne sera pas pris en compte."

step "Génération du projet"
[ -f "$REPO_ROOT/project.yml" ] || die "project.yml introuvable dans $REPO_ROOT."
"$xcodegen" generate --spec "$REPO_ROOT/project.yml"
[ -d "$REPO_ROOT/$PROJECT" ] || die "$PROJECT n'a pas été généré."
say "$PROJECT généré."

if [ "$open_project" -eq 1 ]; then
  step "Ouverture dans Xcode"
  open "$REPO_ROOT/$PROJECT"
fi

cat <<'EOF'

Prêt. Dans Xcode : schéma PixelOpenSpace, puis ⌘R pour lancer l'app.
Tests du cœur, sans Xcode : cd Core && swift test
Après un changement de project.yml (git pull), relance ce script ou « xcodegen generate ».
EOF
