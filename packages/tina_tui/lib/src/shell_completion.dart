/// Offline shell scripts: flag and filesystem completion never starts a session.
String shellCompletion(String shell) => switch (shell) {
      'bash' => r'''_tina_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
  case "$prev" in
    --cwd) COMPREPLY=(); while IFS= read -r item; do COMPREPLY+=("$item"); done < <(compgen -d -- "$cur"); return;;
    --config|--store|--import-sessions) COMPREPLY=(); while IFS= read -r item; do COMPREPLY+=("$item"); done < <(compgen -f -- "$cur"); return;;
    --completion) COMPREPLY=( $(compgen -W 'bash zsh fish' -- "$cur") ); return;;
    --backend) COMPREPLY=( $(compgen -W 'auto ansi notcurses' -- "$cur") ); return;;
    --resume) if [[ "$cur" != -* ]]; then return; fi;;
  esac
  COMPREPLY=( $(compgen -W '--model --models --prompt --goal --max-goal-turns --config --cwd --store --resume --continue -c --configure --version --help --completion --import-sessions --dry-run --backend --no-sandbox' -- "$cur") )
}
complete -F _tina_complete tina''',
      'zsh' => r'''#compdef tina
_tina() {
  _arguments '--config[Global config file]:file:_files' '--cwd[Workspace]:directory:_files -/' \
    '--store[Session store]:file:_files' '--resume[Select or resume session]::session ID:' \
    '--model[Model for this run]:model:' '--models[List models]:provider:' '--prompt[Headless prompt]:prompt:' \
    '--goal[Headless goal]:goal:' '--max-goal-turns[Bound goal turns]:count:' \
    '--continue[Continue latest session]' '-c[Continue latest session]' '--configure[Edit settings]' '--version[Print version]' \
    '--help[Usage]' '--completion[Shell completion]:shell:(bash zsh fish)' \
    '--backend[Terminal renderer]:backend:(auto ansi notcurses)' \
    '--no-sandbox[Disable OS confinement for this run; keep approval checks]' \
    '--import-sessions[Import legacy sessions]:source:_files' '--dry-run[Preview import without writing]'
}
compdef _tina tina''',
      'fish' => r'''complete -c tina -f
complete -c tina -l goal -r
complete -c tina -l max-goal-turns -r
complete -c tina -l model -r
complete -c tina -l models
complete -c tina -l prompt -r
complete -c tina -l config -r -F
complete -c tina -l cwd -r -a '(__fish_complete_directories)'
complete -c tina -l store -r -F
complete -c tina -l resume
complete -c tina -l import-sessions -r -F
complete -c tina -l dry-run
complete -c tina -l continue -s c
complete -c tina -l goal -r
complete -c tina -l max-goal-turns -r
complete -c tina -l model -r
complete -c tina -l models
complete -c tina -l prompt -r
complete -c tina -l configure
complete -c tina -l backend -r -a 'auto ansi notcurses'
complete -c tina -l no-sandbox -d 'Disable OS confinement; keep approval checks'
complete -c tina -l version
complete -c tina -l help
complete -c tina -l completion -r -a 'bash zsh fish' ''',
      _ => throw const FormatException(
          'completion shell must be bash, zsh or fish'),
    };
