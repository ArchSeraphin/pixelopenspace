#!/bin/bash
# Pixel Open Space : spikes de l'étape 2 (docs/PROPOSITION.md, section 5.11).
# Lance ton vrai `claude` dans des dossiers jetables et enregistre ce qu'il fait (voir README.md à côté).
# Usage : Tools/spikes/run-spikes.sh [--yes] [--only S1,S4] [--with-perturbation] [--help]
# Compatible avec le bash 3.2 de macOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'Erreur : %s\n' "$1" >&2
  exit 1
}

if [ "$(id -u)" -eq 0 ]; then
  die "ne lance pas ce script en root (sudo) : il utilise ta propre installation de claude."
fi

command -v python3 >/dev/null 2>&1 ||
  die "python3 introuvable. Installe les outils de ligne de commande d'Xcode : xcode-select --install"
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
  die "Python 3.9 ou plus récent est requis ($(python3 --version 2>&1))."
fi

assume_yes=0
claude_path=""
previous=""
for arg in ${1+"$@"}; do
  if [ "$previous" = "--claude" ]; then
    claude_path="$arg"
  fi
  case "$arg" in
    -h | --help | --list) exec python3 "$SCRIPT_DIR/spikes.py" "$arg" ;;
    -y | --yes) assume_yes=1 ;;
    --claude=*) claude_path="${arg#--claude=}" ;;
  esac
  previous="$arg"
done

if [ -z "$claude_path" ]; then
  claude_path="$(command -v claude || true)"
fi
[ -n "$claude_path" ] ||
  die "claude introuvable dans le PATH. Installe Claude Code, ou passe --claude /chemin/vers/claude."
[ -x "$claude_path" ] || die "$claude_path n'est pas exécutable."
claude_version="$("$claude_path" --version 2>/dev/null | head -n 1 || true)"
printf 'claude  : %s (%s)\n' "$claude_path" "${claude_version:-version inconnue}"
printf 'python3 : %s (%s)\n' "$(command -v python3)" "$(python3 --version 2>&1)"
echo

cat <<'EOF'
Ce script va :
  - créer des dossiers jetables dans $TMPDIR/pos-spikes-<date>/ (un dépôt git avec a.txt et b.txt par
    scénario), puis les supprimer à la fin ;
  - y lancer ton vrai claude dans un terminal simulé, sans fenêtre, avec le modèle haiku et le mode de
    permission « default » : une trentaine de tours très courts, 5 à 10 minutes en tout (plus 1 à 3 minutes
    pour compiler pixel-hook si swift est installé) ;
  - brancher les hooks de test par --settings (fichier temporaire, avec une règle « ask » pour `touch`) :
    rien n'est écrit dans ~/.claude ni dans tes dépôts (S1 place des hooks dans le
    .claude/settings.local.json d'un dossier jetable, S4 y crée un worktree) ;
  - accepter la confiance des seuls dossiers jetables, fermer par Échap les dialogues de démarrage (par
    exemple l'offre du nouveau rendu plein écran : rien n'est enregistré), répondre « 1 » à une demande de
    permission et en refuser une autre par Échap (des commandes `touch` dans le dossier jetable) ; rien en
    bypassPermissions ;
  - écrire les résultats anonymisés (chemins, nom, e-mail et nom de machine remplacés) dans
    Tools/spikes/results/<date>/.

Comme pour toute session, Claude Code garde lui-même ces conversations jetables dans son historique
(~/.claude/projects) et note la confiance accordée aux dossiers jetables.
EOF
echo

if [ "$assume_yes" -ne 1 ]; then
  if [ ! -t 0 ]; then
    die "pas de terminal pour confirmer : relance avec --yes."
  fi
  printf 'Continuer ? [o/N] '
  answer=""
  read -r answer || answer=""
  case "$answer" in
    o | O | oui | Oui | OUI | y | Y | yes | Yes) ;;
    *)
      echo "Annulé."
      exit 1
      ;;
  esac
fi

exec python3 "$SCRIPT_DIR/spikes.py" --yes --claude "$claude_path" ${1+"$@"}
